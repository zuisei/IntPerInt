import Foundation
import Combine
import os
import AppKit

// インストール済みモデルの情報
public struct InstalledModel: Identifiable, Hashable {
    public let id = UUID()
    public let name: String      // 表示名
    public let fileName: String  // 実ファイル名
    public let url: URL
}

@MainActor
public class ModelManager: ObservableObject {
    // 会話管理
    @Published var conversations: [Conversation] = [Conversation()]
    @Published var selectedConversationID: Conversation.ID? = nil
    // 画面反映用メッセージ（現在選択中の会話と同期）
    @Published var messages: [ChatMessage] = []
    // 推奨カタログ名（ダウンロード候補）
    @Published var availableModels: [String] = []
    // インストール済み（ローカルに存在）モデルのみ（Picker はこれだけを表示）
    @Published private(set) var installedModels: [InstalledModel] = []
    // 有効性検証済み（llama.cpp で最小実行が成功）モデルのみ（Picker はこれだけを選択可能にする）
    @Published private(set) var validInstalledModels: [InstalledModel] = []
    @Published var downloadingModels: Set<String> = []
    @Published var downloadProgress: [String: Double] = [:]
    // MB/s per model (average since start)
    @Published var downloadSpeed: [String: Double] = [:]
    // Expected total bytes per model (if server provides Content-Length)
    @Published var downloadExpectedBytes: [String: Int64] = [:]
    // Received bytes so far per model
    @Published var downloadReceivedBytes: [String: Int64] = [:]
    @Published var isLoading: Bool = false
    @Published var isGenerating: Bool = false
    // システム通知（チャットに混ぜないUIバナー用）
    @Published var systemNotifications: [SystemNotification] = []
    // エンジン状態（送信直前のプリロードの可視化）
    @Published var engineStatus: EngineStatus = .idle

    // Engine and task management
    private var engine: LLMEngine = {
        // UDS ソケットが存在するなら helper 経由エンジンを優先
        let sock = "/tmp/intperint.sock"
        if FileManager.default.fileExists(atPath: sock) {
            return UDSLLMEngine(sockPath: sock)
        } else {
            return LlamaCppLibEngine()
        }
    }()
    private var currentModelPath: URL? = nil
    private var currentGenerationTask: Task<Void, Never>? = nil
    private let logger = Logger(subsystem: "com.example.IntPerInt", category: "ModelManager")

    private let modelsDirectory: URL
    // Expose models dir read-only for views (e.g., opening in Finder)
    var modelsDir: URL { modelsDirectory }
    // Total size of installed models (bytes)
    @Published private(set) var installedTotalBytes: Int64 = 0

    // Track in-flight downloads and delegates for progress/cancel
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var saveDebounceWorkItem: Task<Void, Never>? = nil
    // 通知の重複抑止
    private var lastNotificationTimestamps: [String: Date] = [:]
    
    // ファイルシステム監視用
    private var fileSystemMonitor: DispatchSourceFileSystemObject? = nil

    init() {
        // ユーザーのDocumentsディレクトリ内にModelsフォルダを作成
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        modelsDirectory = documentsPath.appendingPathComponent("IntPerInt/Models")
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

    // CLIの自動検出は廃止（libエンジンを優先使用）

        // load persisted conversations if any
        Task { await loadPersistedConversations() }

        // default selection
        selectedConversationID = conversations.first?.id
        messages = conversations.first?.messages ?? []
        
        // ファイルシステム監視を開始（モデル追加時の自動再読み込み用）
        startFileSystemMonitoring()
        
        // 初期化時にローカルモデルを読み込む
        loadAvailableModels()
    }
    
    // デイニシャライザーでリソース解放
    deinit {
        fileSystemMonitor?.cancel()
    }

    // 旧CLI検出系は撤去
    
    func loadAvailableModels() {
        // 推奨カタログ名（ダウンロード候補用）は即座に設定
        availableModels = ModelInfo.availableModels.map { $0.name }
        
        // ローカル（インストール済み）スキャンはバックグラウンドで実行
        Task.detached(priority: .userInitiated) { @MainActor in
            self.refreshInstalledModels()
        }
    }

    var hasAnyLocalModel: Bool { !installedModels.isEmpty }
    
    func deleteInstalledModel(_ fileName: String) {
        let target = modelsDirectory.appendingPathComponent(fileName)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            // このモデルを参照している会話を解除
            for i in conversations.indices {
                if conversations[i].model == fileName { conversations[i].model = nil }
            }
            // 現在ロード中モデルに一致するならエンジン状態をリセット
            if currentModelPath?.path == target.path {
                currentModelPath = nil
            }
            // 再スキャン（有効性検証も内部で実施）
            refreshInstalledModels()
        } catch {
            print("Model delete failed: \(error)")
        }
    }
    
    func newConversation() {
        let conv = Conversation(title: "New Chat", messages: [], updatedAt: Date())
        conversations.insert(conv, at: 0)
        selectedConversationID = conv.id
        messages = []
        scheduleSave()
    }

    func renameSelectedConversation(title: String) {
        guard let id = selectedConversationID, let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].title = title
        scheduleSave()
    }

    func deleteConversation(at offsets: IndexSet) {
        conversations.remove(atOffsets: offsets)
        if conversations.isEmpty {
            conversations = [Conversation()]
        }
        selectedConversationID = conversations.first?.id
        messages = conversations.first?.messages ?? []
        scheduleSave()
    }

    func selectConversation(_ id: Conversation.ID) {
        selectedConversationID = id
        if let conv = conversations.first(where: { $0.id == id }) {
            messages = conv.messages
        }
    // モデルのロードは初回生成時に遅延実行（ここでは行わない）
    }

    func sendMessage(_ content: String, using modelName: String, provider: AIProvider, params: GenerationParams? = nil) {
        // 1. 即座にユーザーメッセージをUIに追加（UI応答性向上）
        let userMessage = ChatMessage(content: content, isUser: true)
        messages.append(userMessage)
        syncMessagesIntoSelectedConversation()
        
        // 2. 即座に生成状態をアクティブに（UIフィードバック）
        isGenerating = true
        
        // 3. 既存生成をキャンセル
        currentGenerationTask?.cancel()

        // 4. バックグラウンドで生成処理を開始（UIをブロックしない）
        currentGenerationTask = Task {
            let generationParams = params ?? GenerationParams()
            let isCancelled: @Sendable () -> Bool = {
                return Task.isCancelled
            }

            do {
                // エンジン準備
                try await self.prepareEngineIfNeeded()

                _ = try await self.engine.generate(prompt: content, systemPrompt: nil, params: generationParams, onToken: { token in
                    Task { @MainActor in
                        // ストリーミングでトークンを即座にUIに反映
                        if let last = self.messages.last, !last.isUser {
                            // 既存のアシスタントメッセージを更新
                            var updated = last
                            updated = ChatMessage(id: updated.id, content: updated.content + token, isUser: false, timestamp: updated.timestamp)
                            self.messages.removeLast()
                            self.messages.append(updated)
                        } else {
                            // 新しいアシスタントメッセージを作成
                            let ai = ChatMessage(content: token, isUser: false)
                            self.messages.append(ai)
                        }
                        self.syncMessagesIntoSelectedConversation()
                    }
                }, isCancelled: isCancelled)

                // 生成完了
                await MainActor.run {
                    self.isGenerating = false
                    self.currentGenerationTask = nil
                    self.logger.info("generation finished successfully")
                }
            } catch {
                await MainActor.run {
                    // エラー処理：生成失敗時
                    self.isGenerating = false
                    self.currentGenerationTask = nil
                    
                    // 途中で挿入されたアシスタントメッセージがあれば削除
                    if let last = self.messages.last, !last.isUser {
                        self.messages.removeLast()
                        self.syncMessagesIntoSelectedConversation()
                    }
                    
                    // システム通知でエラー表示
                    let (key, msg, actions) = self.mapErrorToNotification(error)
                    self.postSystemNotification(key: key, message: msg, severity: .error, actions: actions, throttleSeconds: 30)
                    self.logger.error("Generation failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func cancelGeneration() {
    currentGenerationTask?.cancel()
    logger.info("generation cancelled by user")
        currentGenerationTask = nil
        Task { @MainActor in self.isGenerating = false }
    }


    func setCurrentModelForSelectedConversation(name: String) {
        guard let id = selectedConversationID,
              let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
    conversations[idx].model = name
    // ロードは sendMessage 内で遅延実行
    }

    private func syncMessagesIntoSelectedConversation() {
        guard let id = selectedConversationID, let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].messages = messages
        conversations[idx].updatedAt = Date()
        // タイトル自動生成（先頭ユーザ発話の先頭20文字）
        if conversations[idx].title == "New Chat", let firstUser = messages.first(where: { $0.isUser }) {
            let base = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = String(base.prefix(20))
            conversations[idx].title = title.isEmpty ? "New Chat" : title
        }
        // 更新順で並べ替え（最新を先頭）
        conversations.sort { $0.updatedAt > $1.updatedAt }
        scheduleSave()
    }
    
    // (legacy sync-style generator functions removed; runtime always uses engine.generate in normal runs)

    // Prepare engine if model file changed
    private func prepareEngineIfNeeded() async throws {
        guard let id = selectedConversationID,
              let conv = conversations.first(where: { $0.id == id }),
              let modelName = conv.model else { return }

        // resolve model file path
        let candidate = modelsDirectory.appendingPathComponent(modelName)
        
        // ファイル存在チェックを非同期で実行（UIスレッドをブロックしない）
        let fileExists = await Task.detached {
            FileManager.default.fileExists(atPath: candidate.path)
        }.value
        
        if fileExists {
            if currentModelPath?.path != candidate.path {
                await MainActor.run { self.engineStatus = .loading(modelName: modelName) }
                // libエンジンのロードを非同期バックグラウンドで実行（メインスレッドをブロックしない）
                do {
                    let loadedEngine = try await Task.detached(priority: .userInitiated) {
                        var lib = LlamaCppLibEngine()
                        try lib.load(modelPath: candidate)
                        return lib
                    }.value
                    
                    // メインアクターで状態更新
                    self.engine = loadedEngine
                    self.currentModelPath = candidate
                    logger.info("LIB ENGINE LOADED model path: \(candidate.path, privacy: .public)")
                    await MainActor.run {
                        self.engineStatus = .loaded(modelName: modelName)
                        self.postSystemNotification(key: "engine_loaded_\(modelName)", message: "モデルをロードしました: \(self.prettyName(for: modelName))", severity: .info, actions: [], throttleSeconds: 5, autoHideAfter: 5)
                    }
                } catch {
                    logger.error("Engine load failed: \(error.localizedDescription, privacy: .public)")
                    await MainActor.run {
                        self.engineStatus = .failed(message: error.localizedDescription)
                        let (key, msg, actions) = self.mapErrorToNotification(error)
                        self.postSystemNotification(key: key, message: msg, severity: .error, actions: actions, throttleSeconds: 30)
                    }
                    throw error
                }
            }
        } else {
            // no local model; 明示エラー
            logger.error("Model file not found at path: \(candidate.path, privacy: .public)")
            let err = NSError(domain: "ModelManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Model not found: \(candidate.lastPathComponent)"])
            await MainActor.run {
                self.engineStatus = .failed(message: err.localizedDescription)
                self.postSystemNotification(key: "model_not_found", message: "モデルが見つかりません: \(candidate.lastPathComponent)", severity: .error)
            }
            throw err
        }
    }

    // Persistence
    private func scheduleSave() {
        saveDebounceWorkItem?.cancel()
        // capture snapshot on main actor
        let snapshot = self.conversations
        saveDebounceWorkItem = Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            await ConversationStore.shared.save(snapshot)
        }
    }

    private func loadPersistedConversations() async {
        let loaded = await ConversationStore.shared.load()
        await MainActor.run {
            if !loaded.isEmpty {
                self.conversations = loaded
                self.selectedConversationID = self.conversations.first?.id
                self.messages = self.conversations.first?.messages ?? []
            }
        }
    }
}

// InstalledModel moved to Models/InstalledModel.swift

// MARK: - File System Monitoring
extension ModelManager {
    private func startFileSystemMonitoring() {
        // modelsDirectoryを監視してファイル追加・削除を検出
        let descriptor = open(self.modelsDirectory.path, O_EVTONLY)
        guard descriptor != -1 else {
            logger.error("Failed to open models directory for monitoring: \(self.modelsDirectory.path, privacy: .public)")
            return
        }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // ファイルシステムの変更を検出したらモデルリストを更新
                self.logger.info("Models directory changed, refreshing model list")
                self.refreshInstalledModels()
                
                // 通知を表示
                self.postSystemNotification(
                    key: "model_list_updated",
                    message: "モデルリストが更新されました",
                    severity: .info,
                    actions: [],
                    throttleSeconds: 5,
                    autoHideAfter: 3
                )
            }
        }
        
        source.setCancelHandler {
            close(descriptor)
        }
        
        source.resume()
        self.fileSystemMonitor = source
        
        logger.info("File system monitoring started for: \(self.modelsDirectory.path, privacy: .public)")
    }
}

// MARK: - Helpers
extension ModelManager {
    // ローカルへモデルファイルを取り込み（ドラッグ&ドロップ等）
    func importLocalModel(from sourceURL: URL) throws {
        let file = sourceURL.lastPathComponent
        guard file.lowercased().hasSuffix(".gguf") else { throw NSError(domain: "ModelManager", code: 400, userInfo: [NSLocalizedDescriptionKey: "GGUFのみ対応です"]) }
        let dest = modelsDirectory.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: dest.path) {
            // 既存ならリネーム
            let base = dest.deletingPathExtension().lastPathComponent
            let ext = dest.pathExtension
            var i = 2
            var cand = modelsDirectory.appendingPathComponent("\(base) (\(i)).\(ext)")
            while FileManager.default.fileExists(atPath: cand.path) { i += 1; cand = modelsDirectory.appendingPathComponent("\(base) (\(i)).\(ext)") }
            try FileManager.default.copyItem(at: sourceURL, to: cand)
        } else {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        }
        refreshInstalledModels()
    }

    func refreshInstalledModels() {
        print("🔍 Scanning for models in: \(modelsDirectory.path)")
        
        guard let contents = try? FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles) else { 
            print("❌ Failed to read directory: \(modelsDirectory.path)")
            return 
        }
        
        print("📁 Found \(contents.count) files in directory")
        for item in contents {
            print("  - \(item.lastPathComponent)")
        }
        
        let ggufs = contents.filter { $0.pathExtension.lowercased() == "gguf" }
        print("🔍 Found \(ggufs.count) GGUF files")
        
        // 分割ファイルパターン: -00001-of-00002.gguf形式を検出
        let splitFilePattern = #"-\d{5}-of-\d{5}\.gguf$"#
        let regex = try? NSRegularExpression(pattern: splitFilePattern, options: [])
        
        var modelGroups: [String: [URL]] = [:]
        var singleFiles: [URL] = []
        
        for url in ggufs {
            let fileName = url.lastPathComponent
            if let match = regex?.firstMatch(in: fileName, options: [], range: NSRange(location: 0, length: fileName.count)) {
                // 分割ファイル: ベース名でグループ化
                let baseName = String(fileName.prefix(match.range.location))
                modelGroups[baseName, default: []].append(url)
            } else {
                // 単一ファイル
                singleFiles.append(url)
            }
        }
        
        var built: [InstalledModel] = []
        
        // 単一ファイルを追加
        for url in singleFiles {
            let file = url.lastPathComponent
            built.append(InstalledModel(name: prettyName(for: file), fileName: file, url: url))
        }
        
        // 分割ファイルグループを追加（最初のファイルをメインにする）
        for (baseName, urls) in modelGroups {
            let sortedUrls = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let firstUrl = sortedUrls.first {
                let displayName = prettyName(for: baseName + ".gguf")
                built.append(InstalledModel(name: displayName, fileName: firstUrl.lastPathComponent, url: firstUrl))
            }
        }
        
        installedModels = built.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        
        print("✅ Final installed models count: \(installedModels.count)")
        for model in installedModels {
            print("  📦 \(model.name) (\(model.fileName))")
        }

        // compute total size
        var total: Int64 = 0
        for url in ggufs {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let bytes = values.fileSize {
                total += Int64(bytes)
            } else if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let bytes = attrs[.size] as? NSNumber {
                total += bytes.int64Value
            }
        }
        installedTotalBytes = total

        // インストール済みから有効モデルを検証・抽出
        validateInstalledModels()
    }

    private func prettyName(for fileName: String) -> String {
        // 例: "mistral-7b-instruct-v0.1.q4_0.gguf" -> "Mistral 7B Instruct (q4_0)"
    let base = fileName.replacingOccurrences(of: ".gguf", with: "")
        let parts = base.split(separator: ".")
        var main = parts.first.map(String.init) ?? base
        var quant = parts.dropFirst().joined(separator: ".")
        // 装飾
        main = main.replacingOccurrences(of: "-", with: " ").capitalized
        if !quant.isEmpty { quant = " (\(quant))" }
        return main + quant
    }
}

// MARK: - System Notifications
extension ModelManager {
    enum NotificationSeverity { case info, warning, error }
    struct SystemNotification: Identifiable, Equatable {
        enum Action: Equatable { case openSettings, openModelsFolder, openDocs, brewInstall }
        let id = UUID()
        let key: String
        let message: String
        let severity: NotificationSeverity
        let timestamp: Date
        let actions: [Action]
        let autoHideAfter: TimeInterval?
    }

    enum EngineStatus: Equatable { case idle, loading(modelName: String), loaded(modelName: String), failed(message: String) }

    func postSystemNotification(key: String, message: String, severity: NotificationSeverity, actions: [SystemNotification.Action] = [], throttleSeconds: TimeInterval = 10, autoHideAfter: TimeInterval? = nil) {
        let now = Date()
        if let last = lastNotificationTimestamps[key], now.timeIntervalSince(last) < throttleSeconds { return }
        lastNotificationTimestamps[key] = now
        let note = SystemNotification(key: key, message: message, severity: severity, timestamp: now, actions: actions, autoHideAfter: autoHideAfter)
        systemNotifications.insert(note, at: 0)
        // 自動消去
        if let hide = autoHideAfter {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(hide * 1_000_000_000))
                await MainActor.run { self?.dismissNotification(id: note.id) }
            }
        }
    }

    func dismissNotification(id: UUID) {
        systemNotifications.removeAll { $0.id == id }
    }

    private func mapErrorToNotification(_ error: Error) -> (String, String, [SystemNotification.Action]) {
        let msg = error.localizedDescription
    // 旧CLI特有のエラー分岐は削除
        return ("generic_error", msg, [])
    }
}

// MARK: - Model validation (llama.cpp quick check)
extension ModelManager {
    private func validateInstalledModels() {
        // Until lib validation path is implemented, treat all installed models as selectable.
        self.validInstalledModels = self.installedModels
    }
}
