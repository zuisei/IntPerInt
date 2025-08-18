import SwiftUI
import Combine
import AppKit

struct ContentView: View {
    @StateObject private var modelManager = ModelManager()
    @State private var selectedProvider: AIProvider = .llamaCpp
    @State private var messageInput = ""
    @State private var selectedModel: String? = nil
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome: Bool = false
    @State private var showWelcome: Bool = false
    @State private var showModelDownload: Bool = false
    @State private var isDownloadMinimized: Bool = false
    @State private var showSettings: Bool = false
    @State private var showDiagnostics: Bool = false

    var body: some View {
        NavigationSplitView {
            // Sidebar: ChatGPT風 会話リスト
            VStack(spacing: 8) {
                HStack {
                    Button {
                        modelManager.newConversation()
                    } label: {
                        Label("New Chat", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)

                // Search placeholder
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("Search").foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06))
                )
                .padding(.horizontal, 10)

                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(modelManager.conversations) { conv in
                            ConversationRow(
                                conversation: conv,
                                isSelected: conv.id == modelManager.selectedConversationID
                            ) {
                                modelManager.selectConversation(conv.id)
                            }
                        }
                        .onDelete { indexSet in
                            modelManager.deleteConversation(at: indexSet)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                }

                Spacer()
            }
            .frame(minWidth: 260)
        } detail: {
            VStack(spacing: 0) {
                // 右上ヘッダー：会話ごとのProvider/Model選択
                HStack(spacing: 8) {
                    // ピッカーは「有効(valid)なモデルのみ」or「None」
                    let noneTag = "__none__"
                    Picker("Model", selection: Binding<String>(
                        get: {
                            // 現在の会話 or ローカル選択値を fileName に正規化
                            let current: String? = {
                                if let id = modelManager.selectedConversationID,
                                   let conv = modelManager.conversations.first(where: { $0.id == id }) {
                                    return conv.modelName ?? selectedModel
                                }
                                return selectedModel
                            }()
                            // 正規化しつつ、有効モデルに存在しない場合は先頭の有効モデル or noneTag
                            if let tag = normalizedTag(from: current),
                               (modelManager.validInstalledModels.contains(where: { $0.fileName == tag }) ||
                                modelManager.installedModels.contains(where: { $0.fileName == tag })) {
                                return tag
                            }
                            // prefer validated; fallback to installed
                            return modelManager.validInstalledModels.first?.fileName
                                   ?? modelManager.installedModels.first?.fileName
                                   ?? noneTag
                        },
                        set: { newVal in
                            if newVal == noneTag {
                                // None を選択 → 会話のモデルを解除
                                if let id = modelManager.selectedConversationID,
                                   let idx = modelManager.conversations.firstIndex(where: { $0.id == id }) {
                                    modelManager.conversations[idx].modelName = nil
                                }
                                selectedModel = nil
                            } else {
                                // 有効モデルのみ代入
                                if let id = modelManager.selectedConversationID,
                                   let idx = modelManager.conversations.firstIndex(where: { $0.id == id }) {
                                    modelManager.conversations[idx].modelName = newVal
                                }
                                selectedModel = newVal
                            }
                        }
                    )) {
                        if !modelManager.validInstalledModels.isEmpty {
                            ForEach(modelManager.validInstalledModels, id: \.fileName) { m in
                                Text(m.name).tag(m.fileName)
                            }
                        } else if !modelManager.installedModels.isEmpty {
                            // Fallback to installed models when validation is unavailable
                            ForEach(modelManager.installedModels, id: \.fileName) { m in
                                Text(m.name + " (未検証)").tag(m.fileName)
                            }
                        } else {
                            Text("None").tag(noneTag)
                        }
                    }
                    .frame(maxWidth: 320)

                    // モデル状態ラベル（簡潔表記）
                    Group {
                        if let tag = selectedModel,
                           let installed = modelManager.installedModels.first(where: { $0.fileName == tag }) {
                            let sizeMB = (try? FileManager.default.attributesOfItem(atPath: installed.url.path)[.size] as? NSNumber)?.int64Value ?? 0
                            Text("Installed (\(Double(sizeMB) / 1_000_000.0, specifier: "%.0f")MB)")
                                .font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.green.opacity(0.2)))
                        } else if selectedModel != nil {
                            Text("Remote")
                                .font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.orange.opacity(0.2)))
                        }
                    }

                    // Welcome 以外からもダウンロード画面を開けるボタン
                    Button {
                        showModelDownload = true; isDownloadMinimized = false
                    } label: {
                        Label("モデルをダウンロード", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .help("推奨 GGUF モデルをカタログから取得")

                    // 設定（LLAMACPP_CLI）
                    Button {
                        showSettings.toggle()
                    } label: {
                        Label("設定", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $showSettings) {
                        SettingsPopover()
                            .frame(width: 380)
                            .padding(16)
                    }

                    Button {
                        showDiagnostics.toggle()
                    } label: {
                        Label("診断", systemImage: "stethoscope")
                    }
                    .buttonStyle(.bordered)
                    .sheet(isPresented: $showDiagnostics) {
                        DiagnosticsView()
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial)

                // 通知バナー（チャットに混ぜない）
                if let notice = modelManager.systemNotifications.first {
                    SystemNotificationBanner(notice: notice) {
                        handleNotificationAction(notice)
                    } onClose: {
                        modelManager.dismissNotification(id: notice.id)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }

                // チャット本文
                ChatArea(
                    messages: modelManager.messages,
                    isGenerating: modelManager.isGenerating,
                    selectedModel: selectedModel,
                    messageInput: $messageInput,
                    onSend: sendMessage,
                    onCancel: { modelManager.cancelGeneration() }
                )
            }
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeView(modelManager: modelManager, hasSeenWelcome: $hasSeenWelcome) {
                showWelcome = false
            }
            .frame(minWidth: 960, minHeight: 600)
        }
    // Overlay for ModelDownload: floating island (top-right), 非ブロッキング + 最小化対応
    .overlay(alignment: .topTrailing) {
        if showModelDownload {
            VStack {
                HStack {
                    if isDownloadMinimized {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle")
                            Text("ダウンロード")
                            if !modelManager.downloadingModels.isEmpty {
                                Text("\(modelManager.downloadingModels.count)件進行中")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button { isDownloadMinimized = false } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                                .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.08)))
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                    } else {
                        ModelDownloadView(modelManager: modelManager) { fileName in
                            modelManager.setCurrentModelForSelectedConversation(name: fileName)
                            showModelDownload = false
                        } onClose: { showModelDownload = false } minimize: { isDownloadMinimized = true }
                        .frame(width: 560, height: 560)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08))
                        )
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
                    }
                }
                .padding(.top, 72)
                .padding(.trailing, 24)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .zIndex(1000)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showModelDownload)
        }
    }
    // Hidden global Command-Q handler (active in all states, including overlays)
    .overlay(alignment: .topLeading) {
        Button("") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q", modifiers: [.command])
        .labelsHidden()
        .frame(width: 0, height: 0)
        .opacity(0.001)
    }
        .onAppear {
            modelManager.loadAvailableModels()
            // Show welcome on first launch or when no local models
            showWelcome = !hasSeenWelcome || !modelManager.hasAnyLocalModel
        }
        .onChange(of: modelManager.validInstalledModels) { valid in
            // 初回ロード/更新時、会話やローカル未選択なら有効モデルの先頭に寄せる
            if let first = valid.first?.fileName {
                let current: String? = {
                    if let id = modelManager.selectedConversationID,
                       let conv = modelManager.conversations.first(where: { $0.id == id }) {
                        return conv.modelName ?? selectedModel
                    }
                    return selectedModel
                }()
                // 正規化しても一致しない場合は先頭に寄せる
                let normalized = normalizedTag(from: current)
                if normalized == nil || !valid.contains(where: { $0.fileName == normalized }) {
                    if let id = modelManager.selectedConversationID,
                       let idx = modelManager.conversations.firstIndex(where: { $0.id == id }) {
                        modelManager.conversations[idx].modelName = first
                    }
                    if selectedModel == nil { selectedModel = first }
                }
            } else if !modelManager.installedModels.isEmpty {
                // valid が空でも installed があればそちらで自動選択
                let installedFirst = modelManager.installedModels.first!.fileName
                if let id = modelManager.selectedConversationID,
                   let idx = modelManager.conversations.firstIndex(where: { $0.id == id }),
                   modelManager.conversations[idx].modelName == nil {
                    modelManager.conversations[idx].modelName = installedFirst
                }
                if selectedModel == nil { selectedModel = installedFirst }
            }
            // if no local models, keep welcome visible
            if !modelManager.hasAnyLocalModel { showWelcome = true }
        }
        .onChange(of: modelManager.selectedConversationID) { _ in
            // 会話切替時、モデル未設定なら自動で割り当て
            guard let id = modelManager.selectedConversationID else { return }
            if let first = modelManager.validInstalledModels.first?.fileName,
               let idx = modelManager.conversations.firstIndex(where: { $0.id == id }),
               modelManager.conversations[idx].modelName == nil {
                modelManager.conversations[idx].modelName = first
            }
        }
    }

    // 旧データ（モデル名）→ 現在のPickerタグ（fileName）に正規化
    private func normalizedTag(from value: String?) -> String? {
        guard let value = value else { return nil }
        // すでに fileName 形式で、installed に存在するならそのまま
        if value.hasSuffix(".gguf"), modelManager.validInstalledModels.contains(where: { $0.fileName == value }) {
            return value
        }
        // 旧: カタログ名から fileName に解決し、それが installed にあるなら採用
        if let info = ModelInfo.availableModels.first(where: { $0.name == value }) {
            let file = info.fileName
            if modelManager.validInstalledModels.contains(where: { $0.fileName == file }) {
                return file
            }
        }
        // 解決不可
        return nil
    }

    private func sendMessage() {
        let trimmed = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 会話ごとのModelを優先（Providerはグローバル設定を使用）
        let providerToUse = selectedProvider
        var modelToUse = selectedModel
        if let id = modelManager.selectedConversationID,
           let conv = modelManager.conversations.first(where: { $0.id == id }) {
            modelToUse = conv.modelName ?? modelToUse
        }
        // モデル未選択時は自動選択（有効モデルから）
        if modelToUse == nil {
            modelToUse = modelManager.validInstalledModels.first?.fileName
                ?? modelManager.installedModels.first?.fileName
            // 会話に反映
            if let id = modelManager.selectedConversationID,
               let idx = modelManager.conversations.firstIndex(where: { $0.id == id }) {
                modelManager.conversations[idx].modelName = modelToUse
            }
            selectedModel = modelToUse
        }
        guard let model = modelToUse else { return }

        messageInput = ""
        modelManager.sendMessage(trimmed, using: model, provider: providerToUse)
    }

    private func handleNotificationAction(_ notice: ModelManager.SystemNotification) {
        guard let action = notice.actions.first else { return }
        switch action {
        case .openSettings:
            showSettings = true
        case .openModelsFolder:
            NSWorkspace.shared.activateFileViewerSelecting([modelManager.modelsDir])
        case .openDocs:
            if let url = URL(string: "https://github.com/zuisei/IntPerInt#readme") { NSWorkspace.shared.open(url) }
        case .brewInstall:
            if let url = URL(string: "https://formulae.brew.sh/formula/llama.cpp") { NSWorkspace.shared.open(url) }
        }
    }
}

private struct ChatArea: View {
    let messages: [ChatMessage]
    let isGenerating: Bool
    let selectedModel: String?
    @Binding var messageInput: String
    let onSend: () -> Void
    let onCancel: () -> Void
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Messages (中央カラム)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .center, spacing: 8) {
                        ForEach(messages) { message in
                            HStack {
                                Spacer(minLength: 0)
                                ChatMessageRow(message: message)
                                    .frame(maxWidth: 900)
                                    .id(message.id)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .onChange(of: messages.count) { _ in
                    if let last = messages.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }

            // 入力バー（ChatGPT風フローティング）
            VStack(spacing: 6) {
                HStack {
                    Spacer(minLength: 0)

                    // 入力ピル本体
                    HStack(spacing: 10) {
                        // 左アイコン群
                        HStack(spacing: 8) {
                            Button(action: {}) { Image(systemName: "plus") }
                            Button(action: {}) { Image(systemName: "paperclip") }
                            Button(action: {}) { Image(systemName: "globe") }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        // エディタ＋プレースホルダ
                        ZStack(alignment: .leading) {
                            if messageInput.isEmpty {
                                Text("Ask anything")
                                    .foregroundStyle(.secondary)
                            }
                            TextEditor(text: $messageInput)
                                .font(.body)
                                .frame(height: 40)
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)
                                .focused($isInputFocused)
                        }

                        // 右アイコン群
                        HStack(spacing: 8) {
                            Button(action: {}) { Image(systemName: "bolt.fill") }
                            Button(action: {}) { Image(systemName: "mic.fill") }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    // 送信ボタンの重なり分だけ右側に余白を確保
                    .padding(.trailing, 36)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .shadow(color: .black.opacity(0.15), radius: 8, y: 1)
                    )
                    .frame(maxWidth: 900)
                    // 送信ボタンを重ねて右に半分はみ出す
                    .overlay(alignment: .trailing) {
                        if isGenerating {
                            Button(action: onCancel) {
                                Image(systemName: "stop.fill")
                                    .imageScale(.medium)
                                    .foregroundStyle(.white)
                                    .padding(12)
                                    .background(Color.red, in: Circle())
                            }
                            .offset(x: 12)
                        } else {
                            Button(action: onSend) {
                                Image(systemName: "paperplane.fill")
                                    .imageScale(.medium)
                                    .foregroundStyle(.white)
                                    .padding(12)
                                    .background((messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedModel == nil) ? Color.accentColor.opacity(0.5) : Color.accentColor, in: Circle())
                            }
                            .keyboardShortcut(.return, modifiers: [.command])
                            .disabled(messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .offset(x: 12)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 8)

                Text("⌘⏎ で送信 • Shift+Enterで改行")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 900)
            }
            .background(.ultraThinMaterial)
        }
    }
}

private struct ModelRow: View {
    let modelName: String
    let isSelected: Bool
    let isDownloading: Bool
    let downloadProgress: Double?
    let onSelect: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(modelName)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                if isDownloading, let progress = downloadProgress {
                    ProgressView(value: progress).progressViewStyle(.linear)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !modelName.hasSuffix(".gguf") {
                Button("Download") { onDownload() }
                    .disabled(isDownloading)
                    .font(.caption)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { if modelName.hasSuffix(".gguf") { onSelect() } }
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Avatar
            ZStack {
                Circle().fill(message.isUser ? Color.accentColor : Color.secondary.opacity(0.2))
                Image(systemName: message.isUser ? "person.fill" : "sparkles")
                    .foregroundStyle(message.isUser ? .white : .primary)
            }
            .frame(width: 24, height: 24)

            // Bubble
            VStack(alignment: .leading, spacing: 6) {
                Text(message.isUser ? "You" : "Assistant")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Group {
                    if let attributed = try? AttributedString(markdown: message.content) {
                        Text(attributed)
                    } else {
                        Text(message.content)
                    }
                }
                .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(message.isUser ? Color.accentColor.opacity(0.12) : Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.06))
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title)
                    .lineLimit(1)
                Text(conversation.updatedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

#Preview { ContentView() }

// MARK: - Settings Popover
private struct SettingsPopover: View {
    @State private var cliPath: String = UserDefaults.standard.string(forKey: "LLAMACPP_CLI") ?? ""
    @State private var testResult: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("設定").font(.headline)
            Text("llama.cpp CLI のフルパスを指定 (例: /opt/homebrew/bin/llama-cli)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("/path/to/llama-cli", text: $cliPath)
                    .textFieldStyle(.roundedBorder)
                Button("保存") {
                    UserDefaults.standard.set(cliPath, forKey: "LLAMACPP_CLI")
                }
                Button("参照…") { browseForCLI() }
                Button("アプリに取り込む") { installIntoAppBin() }
                    .disabled(!FileManager.default.isExecutableFile(atPath: cliPath.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            HStack {
                Button("検出/テスト") {
                    let trimmed = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    if FileManager.default.isExecutableFile(atPath: trimmed) {
                        if let ver = runVersion(bin: trimmed) {
                            testResult = "OK: " + ver
                        } else {
                            testResult = "OK: 実行可能 (version取得不可)"
                        }
                    } else {
                        // 未設定なら自動検出→テスト
                        if let found = autoDetectCLIReturnPath() {
                            cliPath = found
                            UserDefaults.standard.set(found, forKey: "LLAMACPP_CLI")
                            if let ver = runVersion(bin: found) {
                                testResult = "OK: " + ver
                            } else {
                                testResult = "OK: 実行可能 (version取得不可)"
                            }
                        } else {
                            testResult = "NG: 見つかりませんでした"
                        }
                    }
                }
                if !testResult.isEmpty { Text(testResult).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("自動検出") { autoDetectCLI() }
                    .help("よくあるパスから自動検出します")
            }
        }
    }

    private func browseForCLI() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.executable]
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            cliPath = url.path
            UserDefaults.standard.set(cliPath, forKey: "LLAMACPP_CLI")
            testResult = FileManager.default.isExecutableFile(atPath: cliPath) ? "OK: 実行可能" : "NG: 実行不可/未設定"
        }
    }

    private func autoDetectCLI() {
        if let found = autoDetectCLIReturnPath() {
            cliPath = found
            UserDefaults.standard.set(found, forKey: "LLAMACPP_CLI")
            testResult = "OK: 実行可能"
        } else {
            testResult = "NG: 見つかりませんでした"
        }
    }

    // LlamaCLIResolverの候補セットを利用して堅牢に検出。パス入力が実行可能ならそれも優先。
    private func autoDetectCLIReturnPath() -> String? {
        let fm = FileManager.default
        let trimmed = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []
        if fm.isExecutableFile(atPath: trimmed) { candidates.append(trimmed) }
        // 入力がディレクトリ（例: /opt/homebrew/Cellar/llama.cpp/<ver>/libexec や /bin）の場合も補完
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: trimmed, isDirectory: &isDir), isDir.boolValue {
            candidates.append(trimmed + "/llama-cli")
            candidates.append(trimmed + "/llama")
        }
        // ユーティリティの候補（Cellar/libexecやApp Support/bin含む）
        candidates += LlamaCLIResolver.candidates()
        // 追加フォールバック: Homebrew Cellar を動的に列挙
        for prefix in ["/opt/homebrew/Cellar/llama.cpp", "/usr/local/Cellar/llama.cpp"] {
            var isDir2: ObjCBool = false
            if fm.fileExists(atPath: prefix, isDirectory: &isDir2), isDir2.boolValue,
               let entries = try? fm.contentsOfDirectory(atPath: prefix) {
                let versions = entries.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                for v in versions.prefix(5) {
                    let base = prefix + "/" + v
                    candidates.append(base + "/bin/llama-cli")
                    candidates.append(base + "/bin/llama")
                    candidates.append(base + "/libexec/llama-cli")
                    candidates.append(base + "/libexec/llama")
                }
            }
        }
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) })
    }

    // --version を実行して最初の行を返す
    private func runVersion(bin: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["--version"]
        let out = Pipe(); proc.standardOutput = out
        let err = Pipe(); proc.standardError = err
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard var s = String(data: data, encoding: .utf8) else { return nil }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty {
            let e = err.fileHandleForReading.readDataToEndOfFile()
            if let se = String(data: e, encoding: .utf8), !se.isEmpty {
                return se.components(separatedBy: .newlines).first
            }
            return nil
        }
        return s.components(separatedBy: .newlines).first
    }

    // Application Support/IntPerInt/bin にCLIをコピーして固定化
    private func installIntoAppBin() {
        let fm = FileManager.default
        let src = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fm.isExecutableFile(atPath: src) else { testResult = "NG: 実行不可/未設定"; return }
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let binDir = base.appendingPathComponent("IntPerInt/bin", isDirectory: true)
        do { try fm.createDirectory(at: binDir, withIntermediateDirectories: true) } catch { testResult = "NG: コピー先作成失敗"; return }
        let dst = binDir.appendingPathComponent("llama-cli")
        do {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: URL(fileURLWithPath: src), to: dst)
            // 実行権付与
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
            cliPath = dst.path
            UserDefaults.standard.set(dst.path, forKey: "LLAMACPP_CLI")
            if let ver = runVersion(bin: dst.path) {
                testResult = "OK: アプリ内に取り込み済み (" + ver + ")"
            } else {
                testResult = "OK: アプリ内に取り込み済み"
            }
        } catch {
            testResult = "NG: コピー失敗 (" + (error as NSError).localizedDescription + ")"
        }
    }
}

// MARK: - System Notification Banner
private struct SystemNotificationBanner: View {
    let notice: ModelManager.SystemNotification
    let onPrimaryAction: () -> Void
    let onClose: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(color)
            Text(notice.message)
                .font(.subheadline)
                .lineLimit(2)
            Spacer()
            if !notice.actions.isEmpty {
                Button(actionTitle) { onPrimaryAction() }
                    .buttonStyle(.bordered)
            }
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08)))
    }
    private var color: Color {
        switch notice.severity { case .info: return .blue; case .warning: return .orange; case .error: return .red }
    }
    private var iconName: String {
        switch notice.severity { case .info: return "info.circle"; case .warning: return "exclamationmark.triangle"; case .error: return "xmark.octagon" }
    }
    private var actionTitle: String {
        switch notice.actions.first {
        case .openSettings: return "設定"
        case .openModelsFolder: return "フォルダ"
        case .openDocs: return "手順"
        case .brewInstall: return "Brew"
        case .none: return ""
        }
    }
}
