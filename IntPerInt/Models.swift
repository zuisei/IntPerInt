import Foundation

// MARK: - Core Models
struct ChatMessage: Identifiable {
    let id = UUID()
    let content: String
    let isUser: Bool
    let timestamp = Date()
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
