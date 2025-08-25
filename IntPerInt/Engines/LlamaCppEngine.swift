import Foundation

#if false // Placeholder to satisfy tooling if build system misses LLMEngine in target membership
import Foundation

public class LlamaCppEngine: LLMEngine {
    private var llamaContext: OpaquePointer?
    private var model: OpaquePointer?
    private var batch: llama_batch?
    private var maxContext: Int32 = 2048

    public init() {}

    deinit {
        if let batch {
            llama_batch_free(batch)
        }
        if let llamaContext {
            llama_free(llamaContext)
        }
        if let model {
            llama_free_model(model)
        }
        llama_backend_free()
    }

    public func load(modelPath: URL) throws {
        var mparams = llama_model_default_params()
        var cparams = llama_context_default_params()
        
        model = llama_load_model_from_file(modelPath.path, mparams)
        guard let model else { throw LlamaCppError.modelLoadFailed }
        
        cparams.n_ctx = maxContext
        llamaContext = llama_new_context_with_model(model, cparams)
        guard let llamaContext else { throw LlamaCppError.contextInitFailed }
    }

    public func generate(
        prompt: String, systemPrompt: String?,
        params: GenerationParams,
        onToken: @escaping @Sendable (String) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> String {
        guard let llamaContext else { throw LlamaCppError.contextNotInitialized }

        let tokens = tokenize(text: prompt, addBos: true)
        let n_len = Int32(tokens.count)
        
        try await Task.sleep(nanoseconds: 100)
        if isCancelled() { return "" }

        llama_kv_cache_clear(llamaContext)
        
        var batch = llama_batch_init(n_len, 0, 1)
        defer { llama_batch_free(batch) }

        for i in 0..<Int(n_len) {
            llama_batch_add(batch, tokens[i], Int32(i), [0], true)
        }
        batch.logits[Int(n_len) - 1] = 1
        
        if llama_decode(llamaContext, batch) != 0 {
            throw LlamaCppError.decodeFailed
        }
        
        var fullResponse = ""
        var n_cur = n_len
        var n_decode = 0
        
        let t_start_us = llama_time_us()

        while n_cur <= maxContext {
            if isCancelled() { break }
            
            var new_token_id: llama_token = 0
            
            do {
                let logits = llama_get_logits_ith(llamaContext, batch.n_tokens - 1)
                var candidates: [llama_token_data] = .init(repeating: .init(), count: Int(llama_n_vocab(model)))
                
                for token_id in 0..<llama_n_vocab(model) {
                    candidates[Int(token_id)] = llama_token_data(id: token_id, logit: logits![Int(token_id)], p: 0.0)
                }
                
                var candidates_p = llama_token_data_array(data: &candidates, size: candidates.count, sorted: false)
                
                let top_k: Int32 = 40
                let tfs_z: Float = 1.0
                let typical_p: Float = 1.0
                
                llama_sample_top_k(llamaContext, &candidates_p, top_k, 1)
                llama_sample_tail_free(llamaContext, &candidates_p, tfs_z, 1)
                llama_sample_typical(llamaContext, &candidates_p, typical_p, 1)
                llama_sample_top_p(llamaContext, &candidates_p, Float(params.topP), 1)
                llama_sample_temp(llamaContext, &candidates_p, Float(params.temperature))
                
                new_token_id = llama_sample_token(llamaContext, &candidates_p)
            }
            
            if new_token_id == llama_token_eos(model) {
                break
            }
            
            let piece = tokenToPiece(token: new_token_id)
            fullResponse += piece
            onToken(piece)
            
            batch.n_tokens = 0
            llama_batch_add(batch, new_token_id, n_cur, [0], true)
            
            n_decode += 1
            n_cur += 1
            
            if llama_decode(llamaContext, batch) != 0 {
                throw LlamaCppError.decodeFailed
            }
        }
        
        let t_end_us = llama_time_us()
        let duration = Double(t_end_us - t_start_us) / 1_000_000.0
        print(String(format: "decoded %d tokens in %.2f s, speed: %.2f t/s", n_decode, duration, Double(n_decode) / duration))
        
        llama_print_timings(llamaContext)
        
        return fullResponse
    }

    private func tokenize(text: String, addBos: Bool) -> [llama_token] {
        guard let model else { return [] }
        let n_ctx = llama_n_ctx(llamaContext)
        var tokens = [llama_token](repeating: 0, count: Int(n_ctx))
        let n_tokens = llama_tokenize(model, text, Int32(text.utf8.count), &tokens, Int32(tokens.count), addBos, false)
        
        guard n_tokens >= 0 else { return [] }
        return Array(tokens[0..<Int(n_tokens)])
    }

    private func tokenToPiece(token: llama_token) -> String {
        guard let model else { return "" }
        var result = [CChar](repeating: 0, count: 8)
        let n_chars = llama_token_to_piece(model, token, &result, Int32(result.count), false)
        
        guard n_chars >= 0 else { return "" }
        return String(cString: result)
    }
}

enum LlamaCppError: Error {
    case modelLoadFailed
    case contextInitFailed
    case contextNotInitialized
    case decodeFailed
}

public protocol LLMEngine {
    mutating func load(modelPath: URL) throws
    func generate(prompt: String, systemPrompt: String?, params: GenerationParams, onToken: @escaping @Sendable (String)->Void, isCancelled: @escaping @Sendable ()->Bool) async throws -> String
}
#endif
import Darwin
import os

// RuntimeManager import (from Runtime/RuntimeManager.swift)
// Note: If RuntimeManager is not available, we'll handle it gracefully

// LlamaCppEngine: runtime chooses between real LLaMA.cpp bridge (if available) and a mock streaming engine.
public struct LlamaCppEngine: LLMEngine {
    // Sentinel to demarcate start of pure model output (avoid echoed prompt / logs)
    private static let responseSentinel = "<|OUTPUT|>"
    private var modelURL: URL?
    private var useMock: Bool = false // normal runs use real engine
    private let log = Logger(subsystem: "com.example.IntPerInt", category: "LlamaCppEngine")
    // Optional server backend
    private var serverProc: Process? = nil
    private var serverPort: Int? = nil
    private var serverURL: URL? { serverPort.map { URL(string: "http://127.0.0.1:\($0)")! } }

    public init() { }

    public mutating func load(modelPath: URL) throws {
        // 保存しておく
        self.modelURL = modelPath

    // Unit Test のみモック許可
    let isUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    self.useMock = isUnitTests

        // For real runs, perform a lightweight CLI invocation to ensure the model can be loaded by llama.cpp.
        // This triggers the actual library load/check at first send (initial load), and surfaces errors early.
        if !isUnitTests {
            do {
                // Prefer server backend if available, otherwise CLI preload
                if let srvPath = try? resolveLlamaServer() {
                    log.info("Starting llama-server: \(srvPath.path, privacy: .public)")
                    try startServer(execURL: srvPath, modelPath: modelPath)
                    // health check
                    try awaitServerReady(timeout: 12)
                    let portStr = String(describing: serverPort)
                    log.info("llama-server ready on port \(portStr, privacy: .public)")
                } else {
                    let cliURL = try resolveLlamaCLI()
                    log.info("Preloading model via llama.cpp CLI: \(cliURL.path, privacy: .public)")

                    let proc = Process()
                    proc.executableURL = cliURL
                    // Minimal generation to trigger model load (suppress verbose logs)
                    let tokenFlag = Self.pickTokenArg(executable: cliURL)
                    proc.arguments = ["-m", modelPath.path, "-p", "test", tokenFlag, "1", "--log-verbosity", "0"]
                    let errPipe = Pipe(); proc.standardError = errPipe
                    let outPipe = Pipe(); proc.standardOutput = outPipe

                    // Ensure Metal resources path for ggml
                    var env = ProcessInfo.processInfo.environment
                    let resDir = Self.resolveMetalResourcesPath(defaultExecDir: cliURL.deletingLastPathComponent())
                    env["GGML_METAL_PATH_RESOURCES"] = resDir
                    let resFile = URL(fileURLWithPath: resDir).appendingPathComponent("default.metallib").path
                    if FileManager.default.fileExists(atPath: resFile) {
                        env["GGML_METAL_PATH"] = resFile
                    }
                    proc.environment = env
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
            // サーバーがあればHTTPで生成、なければCLIを起動してSTDOUTをストリーム読み取り
            guard let modelURL else { throw NSError(domain: "LlamaCppEngine", code: 10, userInfo: [NSLocalizedDescriptionKey: "Model not set"]) }
            let combined = ([systemPrompt, prompt].compactMap { $0 }).joined(separator: "\n")

            if let base = serverURL {
                // Non-streaming simple path for stability
                let url = base.appendingPathComponent("completion")
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                let body: [String: Any] = {
                    var b: [String: Any] = [
                        "prompt": combined,
                        "n_predict": max(1, params.maxTokens),
                        "temperature": params.temperature
                    ]
                    if let seed = params.seed { b["seed"] = seed }
                    if let stop = params.stop, !stop.isEmpty { b["stop"] = stop }
                    return b
                }()
                req.addValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    let text = String(data: data, encoding: .utf8) ?? ""
                    throw NSError(domain: "LlamaCppEngine", code: code, userInfo: [NSLocalizedDescriptionKey: text.isEmpty ? "server error" : text])
                }
                // Parse content from possible schemas
                var text = ""
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let s = obj["content"] as? String { text = s }
                    else if let choices = obj["choices"] as? [[String: Any]],
                            let first = choices.first,
                            let s = first["text"] as? String { text = s }
                    else if let dataArr = obj["data"] as? [[String: Any]] {
                        let texts = dataArr.compactMap { $0["text"] as? String }
                        if !texts.isEmpty { text = texts.joined() }
                    }
                }
                if text.isEmpty { text = String(data: data, encoding: .utf8) ?? "" }
                if !text.isEmpty { onToken(text) }
                return text
            } else {
                // CLI fallback
                let cliURL = try resolveLlamaCLI()
                
                // Metal GPU detection - libggml-metal.dylibの存在で判定
                let hasMetalGPU = FileManager.default.fileExists(atPath: "/opt/homebrew/lib/libggml-metal.dylib") ||
                                  FileManager.default.fileExists(atPath: "/usr/local/lib/libggml-metal.dylib") ||
                                  FileManager.default.fileExists(atPath: "/opt/homebrew/Cellar/llama.cpp/6210/lib/libggml-metal.dylib")
                
                log.info("Metal GPU detection: \(hasMetalGPU ? "AVAILABLE" : "NOT_FOUND", privacy: .public)")
                if hasMetalGPU {
                    log.info("Modern llama.cpp Metal GPU support detected")
                }
                
                // Build args (llama.cpp cli オプション差異に対応)
                let tokenFlag = Self.pickTokenArg(executable: cliURL)
                // Append sentinel so we can strip everything before it in streaming
                let promptWithSentinel = combined + "\n\n" + Self.responseSentinel + "\n"
                var args: [String] = [
                    "-m", modelURL.path,
                    "-p", promptWithSentinel,
                    tokenFlag, String(max(1, params.maxTokens)),
                    "--temp", String(params.temperature),
                    "--log-verbosity", "0"
                ]

                // Quiet / simplified output flags (append only if supported)
                let quietFlags = ["--no-display-prompt", "--simple-io", "--log-disable"]
                let supported = Self.detectSupportedFlags(executable: cliURL, candidates: quietFlags)
                args.append(contentsOf: supported)
                
                // GPU acceleration configuration
                if hasMetalGPU {
                    args += ["-ngl", "99"]  // 99 = 全layers GPUに割り当て
                    args += ["--batch-size", "512", "--ctx-size", "8192"]  // GPU最適化
                    log.info("GPU acceleration ENABLED with 99 layers")
                } else {
                    args += ["-ngl", "0"]   // CPU only
                    args += ["--batch-size", "256", "--ctx-size", "4096"]  // CPU最適化
                    log.info("GPU acceleration DISABLED, using CPU")
                }
                
                if let seed = params.seed { args += ["--seed", String(seed)] }
                if let stop = params.stop, !stop.isEmpty {
                    for s in stop where !s.isEmpty { args += ["--stop", s] }
                }

                log.info("REAL ENGINE LOADED, model path: \(modelURL.path, privacy: .public)")
                log.info("system info: \(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public)")

                let proc = Process()
                proc.executableURL = cliURL
                proc.arguments = args
                
                // Ensure Metal resources path for ggml
                let env = ProcessInfo.processInfo.environment
                if hasMetalGPU {
                    // 新しいllama.cppではシンプルな設定のみ
                    log.info("Metal GPU environment configured for modern llama.cpp")
                } else {
                    log.info("Metal GPU not available, CPU fallback configured")
                }
                proc.environment = env
                let outPipe = Pipe(); proc.standardOutput = outPipe
                let errPipe = Pipe(); proc.standardError = errPipe

                actor Accumulator { var text = ""; func append(_ s: String) { text += s }; func snapshot() -> String { text } }
                actor StreamFilter {
                    let sentinel: String
                    var found = false
                    var carry = ""
                    init(sentinel: String) { self.sentinel = sentinel }
                    func process(_ incoming: String) -> String? {
                        if found { return incoming }
                        let chunk = carry + incoming
                        carry.removeAll(keepingCapacity: true)
                        if let range = chunk.range(of: sentinel) {
                            found = true
                            let after = String(chunk[range.upperBound...])
                            return after.isEmpty ? nil : after
                        } else {
                            // retain tail that could form beginning of sentinel
                            let keep = min(sentinel.count - 1, chunk.count)
                            carry = String(chunk.suffix(keep))
                            return nil
                        }
                    }
                }
                let acc = Accumulator()
                let filter = StreamFilter(sentinel: Self.responseSentinel)
                try proc.run()
                let handle = outPipe.fileHandleForReading
                handle.readabilityHandler = { fh in
                    let data = fh.availableData
                    if data.isEmpty { return }
                    if isCancelled() {
                        proc.terminate(); handle.readabilityHandler = nil; return
                    }
                    guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
                    Task {
                        if let emit = await filter.process(chunk) {
                            await acc.append(emit)
                            onToken(emit)
                        }
                    }
                }
                while proc.isRunning {
                    if isCancelled() { proc.terminate(); break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                handle.readabilityHandler = nil
                let status = proc.terminationStatus
                if status != 0 && !isCancelled() {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
                    throw NSError(domain: "LlamaCppEngine", code: Int(status), userInfo: [NSLocalizedDescriptionKey: errStr])
                }
                var finalText = await acc.snapshot()
                // Basic post-clean: trim and remove stray ANSI sequences
                finalText = Self.minimalClean(finalText)
                return finalText
            }
        }
    }
}

// MARK: - Helpers
private extension LlamaCppEngine {
    func resolveLlamaServer() throws -> URL {
        let fm = FileManager.default
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["LLAMACPP_SERVER"], !env.isEmpty { candidates.append(env) }
        if let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appBin = appSup.appendingPathComponent("IntPerInt/bin")
            candidates.append(appBin.appendingPathComponent("llama-server").path)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/opt/llama.cpp/bin/llama-server",
            "/usr/local/opt/llama.cpp/bin/llama-server",
            "/opt/homebrew/bin/llama-server",
            "/usr/local/bin/llama-server",
            "/tmp/llama.cpp/build/bin/llama-server"
        ])
        for p in candidates { if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) } }
        throw NSError(domain: "LlamaCppEngine", code: 404, userInfo: [NSLocalizedDescriptionKey: "llama-server not found"])
    }

    mutating func startServer(execURL: URL, modelPath: URL) throws {
        let port = pickFreePort() ?? 8081
        self.serverPort = port
        let proc = Process()
        proc.executableURL = execURL
        
        // Metal GPU detection for server - libggml-metal.dylibの存在で判定
        let hasMetalGPU = FileManager.default.fileExists(atPath: "/opt/homebrew/lib/libggml-metal.dylib") ||
                          FileManager.default.fileExists(atPath: "/usr/local/lib/libggml-metal.dylib") ||
                          FileManager.default.fileExists(atPath: "/opt/homebrew/Cellar/llama.cpp/6210/lib/libggml-metal.dylib")
        
        log.info("llama-server Metal GPU detection: \(hasMetalGPU ? "AVAILABLE" : "NOT_FOUND", privacy: .public)")
        
        // 20Bモデル用の最適化されたサーバー引数
        var serverArgs = [
            "-m", modelPath.path, 
            "--port", String(port)
        ]
        
        if hasMetalGPU {
            // GPU加速設定
            serverArgs += [
                "-ngl", "99",           // 全layers GPU
                "--ctx-size", "8192",   // コンテキストサイズ拡大
                "--batch-size", "512"   // バッチサイズ最適化
            ]
            log.info("llama-server: GPU acceleration ENABLED with 99 layers")
        } else {
            // CPU fallback設定
            serverArgs += [
                "-ngl", "0",            // CPU only
                "--ctx-size", "4096",   // CPU用コンテキスト
                "--batch-size", "256"   // CPU用バッチサイズ
            ]
            log.info("llama-server: GPU acceleration DISABLED, using CPU")
        }
        
        proc.arguments = serverArgs
        
        let env = ProcessInfo.processInfo.environment
        if hasMetalGPU {
            log.info("llama-server: Metal GPU environment configured for modern llama.cpp")
        } else {
            log.info("llama-server: CPU environment configured")
        }
        proc.environment = env
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        try proc.run()
        self.serverProc = proc
    }

    func awaitServerReady(timeout: TimeInterval) throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if serverProc?.isRunning == false { break }
            if let base = serverURL {
                for path in ["/health", "/healthz"] {
                    if let url = URL(string: path, relativeTo: base) {
                        var req = URLRequest(url: url); req.httpMethod = "GET"; req.timeoutInterval = 1.0
                        let sem = DispatchSemaphore(value: 1)
                        var ok = false
                        sem.wait()
                        URLSession.shared.dataTask(with: req) { _, resp, _ in
                            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) { ok = true }
                            sem.signal()
                        }.resume()
                        _ = sem.wait(timeout: .now() + 1.2)
                        if ok { return }
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        // last resort: try a tiny completion
        if serverURL != nil {
            var req = URLRequest(url: serverURL!.appendingPathComponent("completion"))
            req.httpMethod = "POST"; req.addValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["prompt": "hi", "n_predict": 1])
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 { ok = true }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + timeout/2)
            if ok { return }
        }
        throw NSError(domain: "LlamaCppEngine", code: 408, userInfo: [NSLocalizedDescriptionKey: "llama-server not ready"])
    }

    func pickFreePort() -> Int? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian
        addr.sin_addr = in_addr(s_addr: in_addr_t(0))
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        if sock < 0 { return nil }
        var a = addr
        let bindRes = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindRes != 0 { close(sock); return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        getsockname(sock, withUnsafeMutablePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }, &len)
        let port = Int(UInt16(bigEndian: a.sin_port))
        close(sock)
        return port
    }
    func resolveLlamaCLI() throws -> URL {
        // 指定順 (bundled runtime → managed runtime → env/UserDefaults → app bin → brew → tmp → which)
        let fm = FileManager.default
        var candidates: [String] = []
        // -1) Bundled runtime in app Resources
        // if let installedFromBundle = try? RuntimeManager.provisionFromBundle(), fm.isExecutableFile(atPath: installedFromBundle.path) {
        //     return installedFromBundle
        // }
        // 0) Managed runtime (Application Support/IntPerInt/runtime/bin)
        // if let managed = RuntimeManager.currentExec(), fm.isExecutableFile(atPath: managed.path) {
        //     return managed
        // }
        // 0.5) Attempt auto-provision into managed runtime once
        // if let installed = try? RuntimeManager.provisionFromSystem(), fm.isExecutableFile(atPath: installed.path) {
        //     return installed
        // }
        // 1) $LLAMACPP_CLI（最優先・ただし存在検証し、必要なら which 補完）
        if let env = ProcessInfo.processInfo.environment["LLAMACPP_CLI"], !env.isEmpty {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: env, isDirectory: &isDir), isDir.boolValue {
                for name in ["llama-cli", "llama"] {
                    let p = (env as NSString).appendingPathComponent(name)
                    if fm.isExecutableFile(atPath: p) {
                        log.debug("LLAMACPP_CLI (dir) -> using: \(p, privacy: .public)")
                        return URL(fileURLWithPath: p)
                    }
                }
            } else if fm.isExecutableFile(atPath: env) {
                log.debug("LLAMACPP_CLI -> using: \(env, privacy: .public)")
                return URL(fileURLWithPath: env)
            } else if !env.hasPrefix("/") {
                // ベース名や相対パス → which で解決
                if let wh = try? ProcessRunner.runSync("/usr/bin/which", args: [env]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), !wh.isEmpty, fm.isExecutableFile(atPath: wh) {
                    log.debug("LLAMACPP_CLI (which) -> using: \(wh, privacy: .public)")
                    return URL(fileURLWithPath: wh)
                }
            }
            // 検証NGの場合は候補スキャンへフォールバック
        }
        // 1.25) UserDefaults に保存された LLAMACPP_CLI（設定UIの保存値）も即採用
        if let pref = UserDefaults.standard.string(forKey: "LLAMACPP_CLI"), !pref.isEmpty {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: pref, isDirectory: &isDir), isDir.boolValue {
                for name in ["llama-cli", "llama"] {
                    let p = (pref as NSString).appendingPathComponent(name)
                    if fm.isExecutableFile(atPath: p) {
                        log.debug("UserDefaults LLAMACPP_CLI (dir) -> using: \(p, privacy: .public)")
                        return URL(fileURLWithPath: p)
                    }
                }
            } else if fm.isExecutableFile(atPath: pref) {
                log.debug("UserDefaults LLAMACPP_CLI -> using: \(pref, privacy: .public)")
                return URL(fileURLWithPath: pref)
            } else if !pref.hasPrefix("/") {
                if let wh = try? ProcessRunner.runSync("/usr/bin/which", args: [pref]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), !wh.isEmpty, fm.isExecutableFile(atPath: wh) {
                    log.debug("UserDefaults LLAMACPP_CLI (which) -> using: \(wh, privacy: .public)")
                    return URL(fileURLWithPath: wh)
                }
            }
            // 検証NGの場合は候補スキャンへ
        }
        // 1.5) アプリ管理の bin ディレクトリ（旧レイアウト互換）
        if let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appBin = appSup.appendingPathComponent("IntPerInt/bin")
            candidates.append(appBin.appendingPathComponent("llama-cli").path)
            candidates.append(appBin.appendingPathComponent("llama").path)
            // 新レイアウト: runtime/bin
            let rtBin = appSup.appendingPathComponent("IntPerInt/runtime/bin")
            candidates.append(rtBin.appendingPathComponent("llama-cli").path)
            candidates.append(rtBin.appendingPathComponent("llama").path)
        }
        // 2) Homebrew opt keg (安定リンク)
        candidates.append(contentsOf: [
            "/opt/homebrew/opt/llama.cpp/bin/llama-cli",
            "/opt/homebrew/opt/llama.cpp/bin/llama",
        ])
        // 3) Homebrew 共通 bin
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/llama-cli",
            "/usr/local/bin/llama-cli",
            "/opt/homebrew/bin/llama",
            "/usr/local/bin/llama",
        ])
        // 4) /tmp ローカルビルド
        candidates.append(contentsOf: [
            "/tmp/llama.cpp/build/bin/llama-cli",
            "/tmp/llama.cpp/build/bin/llama",
            "/tmp/llama.cpp/bin/llama-cli",
            "/tmp/llama.cpp/bin/llama",
            "/tmp/llama.cpp/main",
            "/tmp/llama.cpp/build/main",
        ])
        // 5) which フォールバック（PATH）
        if let whichCli = try? ProcessRunner.runSync("/usr/bin/which", args: ["llama-cli"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), !whichCli.isEmpty {
            candidates.append(whichCli)
        }
        if let whichLlama = try? ProcessRunner.runSync("/usr/bin/which", args: ["llama"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), !whichLlama.isEmpty {
            candidates.append(whichLlama)
        }

        // 候補ログ
        log.debug("Llama CLI candidates: \(candidates, privacy: .public)")
        var reportLines: [String] = []
        for p in candidates {
            // まず存在チェック
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: p, isDirectory: &isDir) && !isDir.boolValue
            if !exists {
                reportLines.append("\(p) => not found")
                continue
            }
            // 実際に --version を短時間実行して判定（偽陰性回避）
            do {
                let res = try ProcessRunner.runSync(p, args: ["--version"])
                reportLines.append("\(p) => ran --version, status=\(res.status)")
                if res.status == 0 {
                    return URL(fileURLWithPath: p)
                }
            } catch {
                reportLines.append("\(p) => run error: \(error.localizedDescription)")
            }
        }
        let report = reportLines.joined(separator: "\n")
        throw NSError(domain: "LlamaCppEngine", code: 404, userInfo: [NSLocalizedDescriptionKey: "llama.cpp CLI not found. Checked candidates:\n\(report)"])
    }

    static func resolveMetalResourcesPath(defaultExecDir: URL) -> String {
        // 例: /opt/homebrew/Cellar/llama.cpp/6180/libexec → ../share/llama.cpp
        let cellarShare = defaultExecDir.deletingLastPathComponent().appendingPathComponent("share/llama.cpp")
        // Managed runtime share dir
        let managedShare: URL = {
            if let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                return appSup.appendingPathComponent("IntPerInt/runtime/share/llama.cpp", isDirectory: true)
            }
            return URL(fileURLWithPath: "")
        }()
        // Bundled runtime share dir
        let bundledShare: URL = {
            if let res = Bundle.main.resourceURL {
                let a = res.appendingPathComponent("runtime/share/llama.cpp", isDirectory: true)
                let b = res.appendingPathComponent("BundledRuntime/runtime/share/llama.cpp", isDirectory: true)
                let fm = FileManager.default
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: a.path, isDirectory: &isDir), isDir.boolValue { return a }
                isDir = false
                if fm.fileExists(atPath: b.path, isDirectory: &isDir), isDir.boolValue { return b }
            }
            return URL(fileURLWithPath: "")
        }()
        let candidates: [URL] = [
            bundledShare,
            managedShare,
            defaultExecDir,
            cellarShare,
            URL(fileURLWithPath: "/tmp/llama.cpp/build/bin"),
            URL(fileURLWithPath: "/tmp/llama.cpp"),
            URL(fileURLWithPath: "/opt/homebrew/opt/llama.cpp/share/llama.cpp"),
            URL(fileURLWithPath: "/usr/local/opt/llama.cpp/share/llama.cpp")
        ]
        for dir in candidates {
            let file = dir.appendingPathComponent("default.metallib")
            if FileManager.default.fileExists(atPath: file.path) { return dir.path }
        }
        return defaultExecDir.path
    }

    // ディレクトリが与えられた場合に /llama-cli, /llama を補完して候補展開
    static func expandIfDirectory(_ path: String) -> [String] {
        var out: [String] = [path]
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            out = [path + "/llama-cli", path + "/llama"]
        }
        return out
    }
}

private extension LlamaCppEngine {
    // Determine token limit flag compatible with the installed llama.cpp cli.
    static func pickTokenArg(executable: URL) -> String {
        // Try help output first
        if let help = try? ProcessRunner.runSync(executable.path, args: ["-h"]).stdout {
            if help.contains("--n-predict") { return "--n-predict" }
            if help.contains("--max-tokens") { return "--max-tokens" }
        }
        // Fallback to common aliases
        return "-n"
    }

    // Detect which of the candidate flags are supported (based on --help)
    static func detectSupportedFlags(executable: URL, candidates: [String]) -> [String] {
        guard let help = try? ProcessRunner.runSync(executable.path, args: ["--help"]).stdout else { return [] }
        return candidates.filter { help.contains($0) }
    }

    static func minimalClean(_ text: String) -> String {
        // Remove ANSI escape sequences & sentinel remnants if any
        var cleaned = text.replacingOccurrences(of: "\u{001B}[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: responseSentinel, with: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// 小さな同期実行ヘルパー
fileprivate enum ProcessRunner {
    static func runSync(_ launchPath: String, args: [String]) throws -> (stdout: String, stderr: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        p.waitUntilExit()
        let so = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let se = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (so, se, p.terminationStatus)
    }
}
