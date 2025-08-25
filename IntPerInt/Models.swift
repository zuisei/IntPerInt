import Foundation

// MARK: - Core Models

public struct GenerationParams: Codable, Hashable, Sendable {
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int
    public var seed: Int?
    public var stop: [String]?
    public init(temperature: Double = 0.7, topP: Double = 1.0, maxTokens: Int = 512, seed: Int? = nil, stop: [String]? = nil) {
        self.temperature = temperature; self.topP = topP; self.maxTokens = maxTokens
        self.seed = seed; self.stop = stop
    }
}

public struct ChatMessage: Identifiable, Codable, Hashable {
    public let id: UUID
    public var content: String
    public let isUser: Bool
    public let timestamp: Date

    public init(id: UUID = UUID(), content: String, isUser: Bool, timestamp: Date = Date()) {
        self.id = id
        self.content = content
        self.isUser = isUser
        self.timestamp = timestamp
    }
}

public struct Conversation: Codable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var messages: [ChatMessage]
    public var createdAt: Date
    public var updatedAt: Date
    public var model: String?
    public var generationParams: GenerationParams

    public init(id: UUID = UUID(), title: String = "", messages: [ChatMessage] = [], createdAt: Date = Date(), updatedAt: Date? = nil, model: String? = nil, generationParams: GenerationParams = GenerationParams()) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.model = model
        self.generationParams = generationParams
    }
}

public enum AIProvider: String, CaseIterable {
    case llamaCpp = "llama_cpp"
    
    var displayName: String {
        switch self {
        case .llamaCpp:
            return "LLaMA.cpp"
        }
    }
}

public struct ModelInfo: Identifiable, Hashable {
    public var id: String { fileName }
    let name: String
    let huggingFaceRepo: String
    let fileName: String
    let quantization: String
    let recommendedMemoryGB: Int

    static let availableModels: [ModelInfo] = [
        ModelInfo(
            name: "GPT-OSS 20B",
            huggingFaceRepo: "gpt-oss/gpt-oss-20b-gguf",
            fileName: "gpt-oss-20b-q4_0.gguf",
            quantization: "q4_0",
            recommendedMemoryGB: 24
        ),
        ModelInfo(
            name: "DeepSeek LLM 67B",
            huggingFaceRepo: "deepseek-ai/deepseek-llm-67b-gguf",
            fileName: "deepseek-llm-67b-q4_k_m.gguf",
            quantization: "q4_k_m",
            recommendedMemoryGB: 64
        ),
        ModelInfo(
            name: "GPT-OSS 120B (Experimental)",
            huggingFaceRepo: "gpt-oss/gpt-oss-120b-gguf",
            fileName: "gpt-oss-120b-q4_k_s.gguf",
            quantization: "q4_k_s",
            recommendedMemoryGB: 128
        )
    ]
}
// ※ 下部に重複/未完了だった ChatMessage 宣言を削除済み
// (EOF)


