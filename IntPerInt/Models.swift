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

struct ModelInfo: Identifiable, Hashable {
    var id: String { fileName }
    let name: String
    let huggingFaceRepo: String
    let fileName: String
    
    // モデルカタログは無効化 - 手動でGGUFファイルを配置してください
    static let availableModels: [ModelInfo] = []
}
