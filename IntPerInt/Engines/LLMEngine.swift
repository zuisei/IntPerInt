import Foundation

public protocol LLMEngine {
    mutating func load(modelPath: URL) throws
    func generate(
        prompt: String, systemPrompt: String?,
        params: GenerationParams,
        onToken: @escaping @Sendable (String) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> String
}
