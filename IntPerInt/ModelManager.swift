import Foundation
import Combine

@MainActor
class ModelManager: ObservableObject {
    // 会話管理
    @Published var conversations: [Conversation] = [Conversation()]
    @Published var selectedConversationID: Conversation.ID? = nil
    // 画面反映用メッセージ（現在選択中の会話と同期）
    @Published var messages: [ChatMessage] = []
    @Published var availableModels: [String] = []
    @Published var downloadingModels: Set<String> = []
    @Published var downloadProgress: [String: Double] = [:]
    @Published var isLoading: Bool = false
    @Published var isGenerating: Bool = false

    // Engine and task management
    private var engine: LLMEngine = LlamaCppEngine()
    private var currentModelPath: URL? = nil
    private var currentGenerationTask: Task<Void, Never>? = nil

    private let modelsDirectory: URL
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
        var models: [String] = []
        
        // Add downloadable models
        models.append(contentsOf: ModelInfo.availableModels.map { $0.name })
        
        // Add already downloaded models
        if let contents = try? FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil) {
            let ggufFiles = contents.filter { $0.pathExtension == "gguf" }
                .map { $0.lastPathComponent }
            models.append(contentsOf: ggufFiles)
        }
        
        availableModels = Array(Set(models)).sorted()
    }
    
    func downloadModel(_ modelName: String) {
        guard let modelInfo = ModelInfo.availableModels.first(where: { $0.name == modelName }),
              !downloadingModels.contains(modelName) else { return }
        
        downloadingModels.insert(modelName)
        downloadProgress[modelName] = 0.0
        
        Task {
            await downloadModelFile(modelInfo)
        }
    }
    
    private func downloadModelFile(_ modelInfo: ModelInfo) async {
        let url = URL(string: "https://huggingface.co/\(modelInfo.huggingFaceRepo)/resolve/main/\(modelInfo.fileName)")!
        let destination = modelsDirectory.appendingPathComponent(modelInfo.fileName)
        
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            
            // Check if file already exists
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            
            try FileManager.default.moveItem(at: tempURL, to: destination)
            
            await MainActor.run {
                downloadingModels.remove(modelInfo.name)
                downloadProgress.removeValue(forKey: modelInfo.name)
                loadAvailableModels()
            }
        } catch {
            print("Download failed: \(error)")
            await MainActor.run {
                downloadingModels.remove(modelInfo.name)
                downloadProgress.removeValue(forKey: modelInfo.name)
            }
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
        // ensure engine is prepared for the selected conversation's model
        Task { await prepareEngineIfNeeded() }
    }

    func sendMessage(_ content: String, using modelName: String, provider: AIProvider) {
        let userMessage = ChatMessage(content: content, isUser: true)
        messages.append(userMessage)
        syncMessagesIntoSelectedConversation()

        // cancel any existing generation
        currentGenerationTask?.cancel()

        currentGenerationTask = Task {
            await MainActor.run { self.isGenerating = true }

            // prepare engine for model
            await prepareEngineIfNeeded()

            let params = GenerationParams()
            let isCancelled: @Sendable () -> Bool = {
                return Task.isCancelled
            }

            do {
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
            }
        }
    }

    func cancelGeneration() {
        currentGenerationTask?.cancel()
        currentGenerationTask = nil
        Task { @MainActor in self.isGenerating = false }
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
    private func prepareEngineIfNeeded() async {
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
                } catch {
                    print("Engine load failed: \(error)")
                }
            }
        } else {
            // no local model; keep mock engine
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
