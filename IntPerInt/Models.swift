import Foundation

// MARK: - Core Models
struct ChatMessage: Identifiable, Codable {
    let id: UUID
    var content: String
    let isUser: Bool
    let timestamp: Date

    init(id: UUID = UUID(), content: String, isUser: Bool, timestamp: Date = Date()) {
        self.id = id
        self.content = content
        self.isUser = isUser
        self.timestamp = timestamp
    }
}

struct Conversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var updatedAt: Date
    var modelName: String?

    init(id: UUID = UUID(), title: String = "New Chat", messages: [ChatMessage] = [], updatedAt: Date = Date(), modelName: String? = nil) {
        self.id = id
        self.title = title
        self.messages = messages
        self.updatedAt = updatedAt
        self.modelName = modelName
    }
}

extension Conversation: Equatable {
    static func == (lhs: Conversation, rhs: Conversation) -> Bool { lhs.id == rhs.id }
}

extension Conversation: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum AIProvider: String, CaseIterable {
    case llamaCpp = "llama_cpp"
    
    var displayName: String {
        switch self {
        case .llamaCpp:
            return "LLaMA.cpp"
        }
    }
}

struct ModelInfo {
    let name: String
    let huggingFaceRepo: String
    let fileName: String
    
    static let availableModels = [
        ModelInfo(name: "Llama-2-7b-Chat", huggingFaceRepo: "TheBloke/Llama-2-7B-Chat-GGML", fileName: "llama-2-7b-chat.q4_0.gguf"),
        ModelInfo(name: "CodeLlama-7b-Instruct", huggingFaceRepo: "TheBloke/CodeLlama-7B-Instruct-GGML", fileName: "codellama-7b-instruct.q4_0.gguf"),
        ModelInfo(name: "Mistral-7b-Instruct", huggingFaceRepo: "TheBloke/Mistral-7B-Instruct-v0.1-GGML", fileName: "mistral-7b-instruct-v0.1.q4_0.gguf")
    ]
}
