import Foundation

public struct GenerationParams: Sendable {
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

public protocol LLMEngine {
    mutating func load(modelPath: URL) throws
    func generate(
        prompt: String, systemPrompt: String?,
        params: GenerationParams,
        onToken: @escaping @Sendable (String) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> String
}
