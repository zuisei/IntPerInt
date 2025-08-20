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
    
    static let availableModels = [
        // 広く使われている 7B 系 OSS モデル（GGUF, Q4_K_M 量子化例）
        ModelInfo(name: "Mistral-7B-Instruct v0.2", huggingFaceRepo: "TheBloke/Mistral-7B-Instruct-v0.2-GGUF", fileName: "mistral-7b-instruct-v0.2.Q4_K_M.gguf"),
        ModelInfo(name: "Zephyr-7B-Beta", huggingFaceRepo: "TheBloke/zephyr-7B-beta-GGUF", fileName: "zephyr-7b-beta.Q4_K_M.gguf"),
        ModelInfo(name: "OpenHermes-2.5-Mistral-7B", huggingFaceRepo: "TheBloke/OpenHermes-2.5-Mistral-7B-GGUF", fileName: "openhermes-2.5-mistral-7b.Q4_K_M.gguf"),
    ModelInfo(name: "Llama-2-7B-Chat", huggingFaceRepo: "TheBloke/Llama-2-7B-Chat-GGUF", fileName: "llama-2-7b-chat.Q4_K_M.gguf"),

    // 大型（より高品質、要メモリ）：
    ModelInfo(name: "Mixtral-8x7B-Instruct v0.1", huggingFaceRepo: "TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF", fileName: "mixtral-8x7b-instruct-v0.1.Q4_K_M.gguf"),
    ModelInfo(name: "Nous-Hermes-2 Mixtral 8x7B DPO", huggingFaceRepo: "TheBloke/Nous-Hermes-2-Mixtral-8x7B-DPO-GGUF", fileName: "nous-hermes-2-mixtral-8x7b-dpo.Q4_K_M.gguf"),
    ModelInfo(name: "Llama-2-13B-Chat", huggingFaceRepo: "TheBloke/Llama-2-13B-Chat-GGUF", fileName: "llama-2-13b-chat.Q4_K_M.gguf"),
    ModelInfo(name: "SOLAR-10.7B-Instruct v1.0", huggingFaceRepo: "TheBloke/solar-10.7b-instruct-v1.0-GGUF", fileName: "solar-10.7b-instruct-v1.0.Q4_K_M.gguf"),
    
    // GPT-OSS シリーズ（Unsloth提供）
    ModelInfo(name: "GPT-OSS-20B (Q4_K_M)", huggingFaceRepo: "unsloth/gpt-oss-20b-GGUF", fileName: "gpt-oss-20b-Q4_K_M.gguf"),
    ModelInfo(name: "GPT-OSS-20B (Q5_K_M)", huggingFaceRepo: "unsloth/gpt-oss-20b-GGUF", fileName: "gpt-oss-20b-Q5_K_M.gguf"),
    ModelInfo(name: "GPT-OSS-120B (Q4_K_M)", huggingFaceRepo: "unsloth/gpt-oss-120b-GGUF", fileName: "Q4_K_M/gpt-oss-120b-Q4_K_M-00001-of-00002.gguf"),
    ModelInfo(name: "GPT-OSS-120B (Q5_K_M)", huggingFaceRepo: "unsloth/gpt-oss-120b-GGUF", fileName: "Q5_K_M/gpt-oss-120b-Q5_K_M-00001-of-00002.gguf"),

    // 軽量（高速・省メモリ）
    ModelInfo(name: "TinyLlama-1.1B-Chat v1.0", huggingFaceRepo: "TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF", fileName: "tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"),
    ModelInfo(name: "Phi-2 (2.7B)", huggingFaceRepo: "TheBloke/phi-2-GGUF", fileName: "phi-2.Q4_K_M.gguf"),
    ModelInfo(name: "Gemma-2-2B-it", huggingFaceRepo: "TheBloke/gemma-2-2b-it-GGUF", fileName: "gemma-2-2b-it.Q4_K_M.gguf"),
    ModelInfo(name: "Qwen2.5-1.5B-Instruct", huggingFaceRepo: "TheBloke/Qwen2.5-1.5B-Instruct-GGUF", fileName: "qwen2.5-1.5b-instruct.Q4_K_M.gguf")
    ]
}
