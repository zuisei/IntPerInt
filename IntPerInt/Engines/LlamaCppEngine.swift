import Foundation
import os

// LlamaCppEngine: runtime chooses between real LLaMA.cpp bridge (if available) and a mock streaming engine.
public struct LlamaCppEngine: LLMEngine {
    private var modelURL: URL?
    private var useMock: Bool = false // normal runs use real engine
    private let log = Logger(subsystem: "com.example.IntPerInt", category: "LlamaCppEngine")

    public init() { }

    public mutating func load(modelPath: URL) throws {
        // ここでは重いロードはしない（初回送信直前に実行）。パスだけ保持。
        self.modelURL = modelPath
        // Unit Test のみモック許可
        let isUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.useMock = isUnitTests
        if !isUnitTests {
            log.info("REAL ENGINE LOADED (deferred), model path: \(modelPath.path, privacy: .public)")
        }
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
                try? await Task.sleep(nanoseconds: 60_000_000) // 60ms
                result += (result.isEmpty ? "" : " ") + word
                onToken(word + " ")
            }
            return result
        } else {
            // 実エンジン（llama.cpp CLI）を起動してSTDOUTをストリーム読み取り
            guard let modelURL else { throw NSError(domain: "LlamaCppEngine", code: 10, userInfo: [NSLocalizedDescriptionKey: "Model not set"]) }
            let cliURL = try resolveLlamaCLI()
            let combined = ([systemPrompt, prompt].compactMap { $0 }).joined(separator: "\n")

            // Build args (llama.cpp cli オプションはバージョンにより異なるため代表的なものを使用)
            var args: [String] = ["-m", modelURL.path, "-p", combined, "-n", String(max(1, params.maxTokens)), "--temp", String(params.temperature)]
            if let seed = params.seed { args += ["-r", String(seed)] }
            if let stop = params.stop, !stop.isEmpty { for s in stop { args += ["-e", s] } }

            log.info("REAL ENGINE LOADED, model path: \(modelURL.path, privacy: .public)")
            log.info("system info: \(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public)")

            let proc = Process()
            proc.executableURL = cliURL
            proc.arguments = args
            let outPipe = Pipe(); proc.standardOutput = outPipe
            let errPipe = Pipe(); proc.standardError = errPipe

            var accumulated = ""

            try proc.run()

            // 非同期で読み取り（ラインや塊ごとにトークン扱い）
            let handle = outPipe.fileHandleForReading
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty { return }
                if isCancelled() {
                    proc.terminate()
                    handle.readabilityHandler = nil
                    return
                }
                if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                    accumulated += chunk
                    onToken(chunk)
                }
            }

            // 待機（キャンセル監視）
            while proc.isRunning {
                if isCancelled() {
                    proc.terminate()
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            handle.readabilityHandler = nil

            let status = proc.terminationStatus
            if status != 0 && !isCancelled() {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
                throw NSError(domain: "LlamaCppEngine", code: Int(status), userInfo: [NSLocalizedDescriptionKey: errStr])
            }
            return accumulated
        }
    }
}

// MARK: - Helpers
private extension LlamaCppEngine {
    func resolveLlamaCLI() throws -> URL {
        // 検索パス: 環境変数, よくあるビルド先（/tmp/llama.cpp）、Homebrew
        let fm = FileManager.default
        let candidates: [String] = {
            var paths: [String] = []
            if let env = ProcessInfo.processInfo.environment["LLAMACPP_CLI"], !env.isEmpty { paths.append(env) }
            paths.append(contentsOf: [
                "/tmp/llama.cpp/bin/llama-cli", // cmake build
                "/tmp/llama.cpp/main",          // make build (legacy)
                "/usr/local/bin/llama-cli",
                "/opt/homebrew/bin/llama-cli"
            ])
            return paths
        }()
        for p in candidates {
            if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        throw NSError(domain: "LlamaCppEngine", code: 404, userInfo: [NSLocalizedDescriptionKey: "llama.cpp CLI not found. Set LLAMACPP_CLI or build to /tmp/llama.cpp."])
    }
}
