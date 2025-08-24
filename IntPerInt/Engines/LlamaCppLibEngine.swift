import Foundation
import os
// Ensure protocol/types are visible
// The file LLMEngine.swift is in the same target; no explicit import needed, but add a dummy reference to avoid dead stripping


@objc class LLamaCppWrapperBridge: NSObject {
    // Expose Objective-C wrapper to Swift in a tiny helper to keep call-sites tidy
    private let impl = LLamaCppWrapper()

    func load(modelPath: URL) async throws {
        return try await withCheckedThrowingContinuation { cont in
            impl.loadModel(modelPath.path) { success, error in
                if success { cont.resume() } else {
                    cont.resume(throwing: error ?? NSError(domain: "LLamaCppWrapper", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to load model"]))
                }
            }
        }
    }

    func generate(prompt: String, params: GenerationParams) async throws -> String {
        return try await withCheckedThrowingContinuation { cont in
            impl.generateText(prompt,
                             temperature: params.temperature,
                             maxTokens: NSNumber(value: max(1, params.maxTokens)).intValue,
                             seed: params.seed.map { NSNumber(value: $0) },
                             stop: params.stop as NSArray? as? [String],
                             completion: { response, error in
                if let err = error { cont.resume(throwing: err) }
                else { cont.resume(returning: response ?? "") }
            })
        }
    }

    func unload() {
        impl.unloadModel()
    }
}

public struct LlamaCppLibEngine: LLMEngine {
    private var modelURL: URL?
    private let log = Logger(subsystem: "com.example.IntPerInt", category: "LlamaCppLibEngine")
    private var wrapper: LLamaCppWrapperBridge? = nil

    public init() {}

    public mutating func load(modelPath: URL) throws {
        self.modelURL = modelPath
        let w = LLamaCppWrapperBridge()
        let sem = DispatchSemaphore(value: 0)
        var thrown: Error? = nil
        
        Task.detached(priority: .userInitiated) {
            do { 
                try await w.load(modelPath: modelPath) 
            } catch { 
                thrown = error 
            }
            sem.signal()
        }
        
        _ = sem.wait(timeout: .now() + 60) // 60秒のタイムアウト
        if let err = thrown { throw err }
        
        self.wrapper = w
        log.info("lib engine loaded: \(modelPath.path, privacy: .public)")
    }

    public func generate(
        prompt: String, systemPrompt: String?,
        params: GenerationParams,
        onToken: @escaping @Sendable (String) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> String {
        guard let wrapper = wrapper else { throw NSError(domain: "LlamaCppLibEngine", code: 10, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"]) }

        // Combine system + user prompt for now; streaming granularity is synthesized
        let combined = ([systemPrompt, prompt].compactMap { $0 }).joined(separator: "\n")
    let text = try await wrapper.generate(prompt: combined, params: params)

        // naive tokenization to stream out result quickly
        if !text.isEmpty {
            let chunks = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
            var emitted = 0
            for c in chunks {
                if isCancelled() { break }
                let s = String(c)
                onToken((emitted == 0 ? "" : " ") + s)
                emitted += 1
            }
            if emitted == 0 { onToken(text) }
        }
        return text
    }
}
