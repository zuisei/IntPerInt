import Foundation
import Combine
import os

@MainActor
class ModelManager: ObservableObject {
    // 会話管理
    @Published var conversations: [Conversation] = [Conversation()]
    @Published var selectedConversationID: Conversation.ID? = nil
    // 画面反映用メッセージ（現在選択中の会話と同期）
    @Published var messages: [ChatMessage] = []
    // 推奨カタログ名（ダウンロード候補）
    @Published var availableModels: [String] = []
    // インストール済み（ローカルに存在）モデルのみ（Picker はこれだけを表示）
    @Published private(set) var installedModels: [InstalledModel] = []
    @Published var downloadingModels: Set<String> = []
    @Published var downloadProgress: [String: Double] = [:]
    @Published var isLoading: Bool = false
    @Published var isGenerating: Bool = false

    // Engine and task management
    private var engine: LLMEngine = LlamaCppEngine()
    private var currentModelPath: URL? = nil
    private var currentGenerationTask: Task<Void, Never>? = nil
    private let logger = Logger(subsystem: "com.example.IntPerInt", category: "ModelManager")

    private let modelsDirectory: URL
    // Expose models dir read-only for views (e.g., opening in Finder)
    var modelsDir: URL { modelsDirectory }

    // Track in-flight downloads and delegates for progress/cancel
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var downloadDelegates: [String: DownloadDelegate] = [:]
    private var saveDebounceWorkItem: Task<Void, Never>? = nil

    init() {
        // Create models directory in user's Application Support folder
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        modelsDirectory = appSupport.appendingPathComponent("IntPerInt/Models")
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        // load persisted conversations if any
        Task { await loadPersistedConversations() }

        // default selection
        selectedConversationID = conversations.first?.id
        messages = conversations.first?.messages ?? []
    }
    
    func loadAvailableModels() {
        // 推奨カタログ名（ダウンロード候補用）
        availableModels = ModelInfo.availableModels.map { $0.name }
        // ローカル（インストール済み）スキャン
        refreshInstalledModels()
    }

    var hasAnyLocalModel: Bool { !installedModels.isEmpty }
    
    func downloadModel(_ modelName: String) {
        guard let modelInfo = ModelInfo.availableModels.first(where: { $0.name == modelName }),
              !downloadingModels.contains(modelName),
              downloadTasks[modelName] == nil else { return }

        let url = URL(string: "https://huggingface.co/\(modelInfo.huggingFaceRepo)/resolve/main/\(modelInfo.fileName)")!
        let destination = modelsDirectory.appendingPathComponent(modelInfo.fileName)

        downloadingModels.insert(modelName)
        downloadProgress[modelName] = 0.0

        let delegate = DownloadDelegate(modelName: modelName, destinationURL: destination,
                                        onProgress: { [weak self] name, progress in
                                            Task { @MainActor in
                                                self?.downloadProgress[name] = progress
                                            }
                                        },
                                        onComplete: { [weak self] name, result in
                                            Task { @MainActor in
                                                guard let self else { return }
                                                self.downloadingModels.remove(name)
                                                self.downloadTasks[name] = nil
                                                self.downloadDelegates[name] = nil
                                                switch result {
                                                case .success:
                                                    self.downloadProgress.removeValue(forKey: name)
                                                    self.loadAvailableModels()
                                                case .failure(let error):
                                                    print("Download failed: \(error)")
                                                    self.downloadProgress.removeValue(forKey: name)
                                                }
                                            }
                                        })

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        downloadDelegates[modelName] = delegate
        downloadTasks[modelName] = task
        task.resume()
    }

    func cancelDownload(_ modelName: String) {
        if let task = downloadTasks[modelName] {
            task.cancel()
        }
        downloadTasks[modelName] = nil
        downloadDelegates[modelName] = nil
        downloadingModels.remove(modelName)
        downloadProgress.removeValue(forKey: modelName)
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

    func sendMessage(_ content: String, using modelName: String, provider: AIProvider) {
        let userMessage = ChatMessage(content: content, isUser: true)
        messages.append(userMessage)
        syncMessagesIntoSelectedConversation()

        // cancel any existing generation
        currentGenerationTask?.cancel()

        currentGenerationTask = Task {
            await MainActor.run { self.isGenerating = true }

            let params = GenerationParams()
            let isCancelled: @Sendable () -> Bool = {
                return Task.isCancelled
            }

            do {
                // 初回送信直前にエンジン準備（実エンジンでロード）
                try await prepareEngineIfNeeded()

                _ = try await engine.generate(prompt: content, systemPrompt: nil, params: params, onToken: { token in
                    Task { @MainActor in
                        // append token to last assistant message (or create one)
                        if let last = self.messages.last, !last.isUser {
                            // modify in place: remove last and append updated
                            var updated = last
                            updated = ChatMessage(id: updated.id, content: updated.content + token, isUser: false, timestamp: updated.timestamp)
                            self.messages.removeLast()
                            self.messages.append(updated)
                        } else {
                            let ai = ChatMessage(content: token, isUser: false)
                            self.messages.append(ai)
                        }
                        self.syncMessagesIntoSelectedConversation()
                    }
                }, isCancelled: isCancelled)

                await MainActor.run {
                    self.isGenerating = false
                    self.currentGenerationTask = nil
                }
            } catch {
                await MainActor.run {
                    let errorMessage = ChatMessage(content: "Error: \(error.localizedDescription)", isUser: false)
                    self.messages.append(errorMessage)
                    self.syncMessagesIntoSelectedConversation()
                    self.isGenerating = false
                    self.currentGenerationTask = nil
                }
                logger.error("Generation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancelGeneration() {
        currentGenerationTask?.cancel()
        currentGenerationTask = nil
        Task { @MainActor in self.isGenerating = false }
    }

    func setCurrentModelForSelectedConversation(name: String) {
        guard let id = selectedConversationID,
              let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].modelName = name
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
    
    private func generateResponse(for prompt: String, using modelName: String, provider: AIProvider) async throws -> String {
        switch provider {
        case .llamaCpp:
            // legacy sync-style generator (kept for compatibility)
            return try await generateLlamaCppResponse(prompt: prompt, modelName: modelName)
        }
    }
    
    private func generateLlamaCppResponse(prompt: String, modelName: String) async throws -> String {
        // TODO: Implement actual LLaMA.cpp integration
        // For now, return a mock response to test the UI
        
        // Simulate processing time
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        
        return "Mock response to: \(prompt)\n\nThis is a placeholder response. The actual LLaMA.cpp integration will be implemented once the library is properly linked to the project."
    }

    // Prepare engine if model file changed
    private func prepareEngineIfNeeded() async throws {
        guard let id = selectedConversationID,
              let conv = conversations.first(where: { $0.id == id }),
              let modelName = conv.modelName else { return }

        // resolve model file path
        let candidate = modelsDirectory.appendingPathComponent(modelName)
        if FileManager.default.fileExists(atPath: candidate.path) {
            if currentModelPath?.path != candidate.path {
                do {
                    var mutableEngine = engine
                    try mutableEngine.load(modelPath: candidate)
                    self.engine = mutableEngine
                    self.currentModelPath = candidate
                    logger.info("REAL ENGINE LOADED (deferred) model path: \(candidate.path, privacy: .public)")
                } catch {
                    logger.error("Engine load failed: \(error.localizedDescription, privacy: .public)")
                    throw error
                }
            }
        } else {
            // no local model; 明示エラー
            logger.error("Model file not found at path: \(candidate.path, privacy: .public)")
            throw NSError(domain: "ModelManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Model not found: \(candidate.lastPathComponent)"])
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

// インストール済みモデルの情報
struct InstalledModel: Identifiable, Hashable {
    let id = UUID()
    let name: String      // 表示名
    let fileName: String  // 実ファイル名
    let url: URL
}

// MARK: - Helpers
extension ModelManager {
    func refreshInstalledModels() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)) ?? []
        let ggufs = contents.filter { $0.pathExtension == "gguf" }
        let built: [InstalledModel] = ggufs.map { url in
            let file = url.lastPathComponent
            return InstalledModel(name: prettyName(for: file), fileName: file, url: url)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        installedModels = built
    }

    private func prettyName(for fileName: String) -> String {
        // 例: "mistral-7b-instruct-v0.1.q4_0.gguf" -> "Mistral 7B Instruct (q4_0)"
        var base = fileName.replacingOccurrences(of: ".gguf", with: "")
        let parts = base.split(separator: ".")
        var main = parts.first.map(String.init) ?? base
        var quant = parts.dropFirst().joined(separator: ".")
        // 装飾
        main = main.replacingOccurrences(of: "-", with: " ").capitalized
        if !quant.isEmpty { quant = " (\(quant))" }
        return main + quant
    }
}

// MARK: - URLSessionDownloadDelegate helper for progress & completion
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let modelName: String
    let destinationURL: URL
    let onProgress: (String, Double) -> Void
    let onComplete: (String, Result<URL, Error>) -> Void

    init(modelName: String,
         destinationURL: URL,
         onProgress: @escaping (String, Double) -> Void,
         onComplete: @escaping (String, Result<URL, Error>) -> Void) {
        self.modelName = modelName
        self.destinationURL = destinationURL
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(modelName, progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            // Replace existing file if present
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            onComplete(modelName, .success(destinationURL))
        } catch {
            onComplete(modelName, .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onComplete(modelName, .failure(error))
        }
    }
}
