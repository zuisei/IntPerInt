import Foundation

// LlamaCppEngine: runtime chooses between real LLaMA.cpp bridge (if available) and a mock streaming engine.
public struct LlamaCppEngine: LLMEngine {
    // modelPath is stored for potential reloads
    private var modelURL: URL?
    private var useMock: Bool = true

    public init() {
        // runtime detection could be added here; default to mock to ensure buildability
        self.useMock = true
    }

    public mutating func load(modelPath: URL) throws {
        self.modelURL = modelPath
        // If a real wrapper is available, attempt to initialize it here and flip useMock = false
        // For now we keep mock mode to avoid build-time native deps.
    }

    public func generate(
        prompt: String, systemPrompt: String?,
        params: GenerationParams,
        onToken: @escaping @Sendable (String) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> String {
        if useMock {
            // Simple token-like streaming: split words and emit with small delay
            let combined = ([systemPrompt, prompt].compactMap { $0 }).joined(separator: "\n")
            let words = combined.split{ $0.isWhitespace }.map(String.init)
            var result = ""
            for word in words {
                if isCancelled() { return result }
                // simulate token emission
                try? await Task.sleep(nanoseconds: 60_000_000) // 60ms
                result += (result.isEmpty ? "" : " ") + word
                onToken(word + " ")
            }
            return result
        } else {
            // Real implementation using ObjC++ bridge would go here.
            return ""
        }
    }
}
