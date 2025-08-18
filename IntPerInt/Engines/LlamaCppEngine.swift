import Foundation
import os

// LlamaCppEngine: runtime chooses between real LLaMA.cpp bridge (if available) and a mock streaming engine.
public struct LlamaCppEngine: LLMEngine {
    private var modelURL: URL?
    private var useMock: Bool = false // normal runs use real engine
    private let log = Logger(subsystem: "com.example.IntPerInt", category: "LlamaCppEngine")

    public init() { }

    public mutating func load(modelPath: URL) throws {
        // 保存しておく
        self.modelURL = modelPath

    // Unit Test のみモック許可
    let isUnitTests = RuntimeEnv.isRunningTests
    self.useMock = isUnitTests

        // For real runs, perform a lightweight CLI invocation to ensure the model can be loaded by llama.cpp.
        // This triggers the actual library load/check at first send (initial load), and surfaces errors early.
        if !isUnitTests {
            do {
                let cliURL = try resolveLlamaCLI()
                log.info("Preloading model via llama.cpp CLI: \(cliURL.path, privacy: .public)")

                let proc = Process()
                proc.executableURL = cliURL
                // Minimal generation to trigger model load
                proc.arguments = ["-m", modelPath.path, "-p", "test", "-n", "1"]
                let errPipe = Pipe(); proc.standardError = errPipe
                let outPipe = Pipe(); proc.standardOutput = outPipe

                try proc.run()
                proc.waitUntilExit()

                if proc.terminationStatus != 0 {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8) ?? ""
                    let outStr = String(data: outData, encoding: .utf8) ?? ""
                    let msg = [errStr, outStr].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    log.error("Model preload failed: \(msg, privacy: .public)")
                    throw NSError(domain: "LlamaCppEngine", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "Unknown error" : msg])
                }

                log.info("REAL ENGINE LOADED, model path: \(modelPath.path, privacy: .public)")
                log.info("system info: \(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public)")
            } catch {
                log.error("Engine preload error: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        } else {
            log.info("REAL ENGINE LOADED (mock allowed for tests), model path: \(modelPath.path, privacy: .public)")
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
            if let seed = params.seed { args += ["--seed", String(seed)] }
            if let stop = params.stop, !stop.isEmpty {
                // llama.cpp uses -r / --reverse-prompt to stop when seq is encountered in input; some builds use -e/--stop for stop tokens
                for s in stop { args += ["-r", s] }
            }

            log.info("REAL ENGINE LOADED, model path: \(modelURL.path, privacy: .public)")
            log.info("system info: \(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public)")

            let proc = Process()
            proc.executableURL = cliURL
            proc.arguments = args
            let outPipe = Pipe(); proc.standardOutput = outPipe
            let errPipe = Pipe(); proc.standardError = errPipe

            // Accumulator actor to avoid concurrent mutation warnings
            actor Accumulator { var text = ""; func append(_ s: String) { text += s }; func snapshot() -> String { text } }
            let acc = Accumulator()

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
            Task { await acc.append(chunk) }
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
            return await acc.snapshot()
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
            // Preferred brew locations first, then /tmp builds
            paths.append(contentsOf: [
                // Homebrew / system
                "/opt/homebrew/bin/llama",
                "/usr/local/bin/llama",
                "/opt/homebrew/bin/llama-cli",
                "/usr/local/bin/llama-cli",
                // Local builds
                "/tmp/llama.cpp/build/bin/llama",
                "/tmp/llama.cpp/build/bin/llama-cli", // cmake build (current)
                "/tmp/llama.cpp/bin/llama",
                "/tmp/llama.cpp/bin/llama-cli",      // cmake build (older)
                "/tmp/llama.cpp/main"                // make build (legacy)
            ])
            return paths
        }()
        for p in candidates {
            if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        throw NSError(domain: "LlamaCppEngine", code: 404, userInfo: [NSLocalizedDescriptionKey: "llama.cpp CLI not found. Set LLAMACPP_CLI or build to /tmp/llama.cpp."])
    }
}
