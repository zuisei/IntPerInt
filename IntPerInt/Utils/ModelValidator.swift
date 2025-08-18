import Foundation

enum ModelValidator {
    static func resolveLlamaCLI() throws -> URL {
        let fm = FileManager.default
        var paths: [String] = []
        if let env = ProcessInfo.processInfo.environment["LLAMACPP_CLI"], !env.isEmpty { paths.append(env) }
        // Specified order: env → brew bin/opt → /tmp local builds
        paths.append(contentsOf: [
            "/opt/homebrew/bin/llama-cli",
            "/usr/local/bin/llama-cli",
            "/opt/homebrew/bin/llama",
            "/usr/local/bin/llama",
            "/opt/homebrew/opt/llama.cpp/bin/llama-cli",
            "/usr/local/opt/llama.cpp/bin/llama-cli",
            "/opt/homebrew/opt/llama.cpp/bin/llama",
            "/usr/local/opt/llama.cpp/bin/llama",
            "/tmp/llama.cpp/build/bin/llama-cli",
            "/tmp/llama.cpp/bin/llama-cli",
            "/tmp/llama.cpp/main",
            "/tmp/llama.cpp/build/bin/llama",
            "/tmp/llama.cpp/bin/llama"
        ])
        for p in paths { if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) } }
    throw NSError(domain: "ModelValidator", code: 404, userInfo: [NSLocalizedDescriptionKey: "llama.cpp CLI not found. Set LLAMACPP_CLI, `brew install llama.cpp`, or build to /tmp/llama.cpp."])
    }

    static func quickValidateBlocking(cliURL: URL, modelURL: URL, timeoutSeconds: Double = 8) -> Bool {
        let proc = Process()
        proc.executableURL = cliURL
        proc.arguments = ["-m", modelURL.path, "-p", "test", "-n", "1"]
        let errPipe = Pipe(); proc.standardError = errPipe
        let outPipe = Pipe(); proc.standardOutput = outPipe
        // Ensure ggml metal resource path similar to engine
        var env = ProcessInfo.processInfo.environment
        if env["GGML_METAL_PATH_RESOURCES"] == nil {
            env["GGML_METAL_PATH_RESOURCES"] = resolveMetalResourcesPath(defaultExecDir: cliURL.deletingLastPathComponent())
        }
        proc.environment = env
        do { try proc.run() } catch { return false }
        let start = Date()
        while proc.isRunning {
            if Date().timeIntervalSince(start) > timeoutSeconds {
                proc.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return proc.terminationStatus == 0
    }
}

// local helper for metallib lookup
private func resolveMetalResourcesPath(defaultExecDir: URL) -> String {
    let candidates: [URL] = [
        defaultExecDir,
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
