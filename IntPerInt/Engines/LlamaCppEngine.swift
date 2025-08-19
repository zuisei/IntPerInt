import Foundation
import Darwin
import os

// LlamaCppEngine: runtime chooses between real LLaMA.cpp bridge (if available) and a mock streaming engine.
public struct LlamaCppEngine: LLMEngine {
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
    let isUnitTests = RuntimeEnv.isRunningTests
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
                // Build args (llama.cpp cli オプション差異に対応)
                let tokenFlag = Self.pickTokenArg(executable: cliURL)
                var args: [String] = [
                    "-m", modelURL.path,
                    "-p", combined,
                    tokenFlag, String(max(1, params.maxTokens)),
                    "--temp", String(params.temperature),
                    "--log-verbosity", "0"
                ]
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
                var env = ProcessInfo.processInfo.environment
                let resDir = Self.resolveMetalResourcesPath(defaultExecDir: cliURL.deletingLastPathComponent())
                env["GGML_METAL_PATH_RESOURCES"] = resDir
                let resFile = URL(fileURLWithPath: resDir).appendingPathComponent("default.metallib").path
                if FileManager.default.fileExists(atPath: resFile) {
                    env["GGML_METAL_PATH"] = resFile
                }
                proc.environment = env
                let outPipe = Pipe(); proc.standardOutput = outPipe
                let errPipe = Pipe(); proc.standardError = errPipe

                actor Accumulator { var text = ""; func append(_ s: String) { text += s }; func snapshot() -> String { text } }
                let acc = Accumulator()
                try proc.run()
                let handle = outPipe.fileHandleForReading
                handle.readabilityHandler = { fh in
                    let data = fh.availableData
                    if data.isEmpty { return }
                    if isCancelled() {
                        proc.terminate(); handle.readabilityHandler = nil; return
                    }
                    if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                        Task { await acc.append(chunk) }
                        onToken(chunk)
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
                return await acc.snapshot()
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
        proc.arguments = ["-m", modelPath.path, "--port", String(port), "--ctx-size", "4096"]
        var env = ProcessInfo.processInfo.environment
        let resDir = Self.resolveMetalResourcesPath(defaultExecDir: execURL.deletingLastPathComponent())
        env["GGML_METAL_PATH_RESOURCES"] = resDir
        let resFile = URL(fileURLWithPath: resDir).appendingPathComponent("default.metallib").path
        if FileManager.default.fileExists(atPath: resFile) {
            env["GGML_METAL_PATH"] = resFile
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
        if let installedFromBundle = try? RuntimeManager.provisionFromBundle(), fm.isExecutableFile(atPath: installedFromBundle.path) {
            return installedFromBundle
        }
        // 0) Managed runtime (Application Support/IntPerInt/runtime/bin)
        if let managed = RuntimeManager.currentExec(), fm.isExecutableFile(atPath: managed.path) {
            return managed
        }
        // 0.5) Attempt auto-provision into managed runtime once
        if let installed = try? RuntimeManager.provisionFromSystem(), fm.isExecutableFile(atPath: installed.path) {
            return installed
        }
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
