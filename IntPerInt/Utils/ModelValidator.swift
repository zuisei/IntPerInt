import Foundation

enum ModelValidator {
    static func resolveLlamaCLI() throws -> URL {
        let fm = FileManager.default
        var paths: [String] = []
        if let env = ProcessInfo.processInfo.environment["LLAMACPP_CLI"], !env.isEmpty { paths.append(env) }
        paths.append(contentsOf: [
            // Homebrew / system
            "/opt/homebrew/bin/llama",
            "/usr/local/bin/llama",
            "/opt/homebrew/bin/llama-cli",
            "/usr/local/bin/llama-cli",
            // Local builds
            "/tmp/llama.cpp/build/bin/llama",
            "/tmp/llama.cpp/build/bin/llama-cli",
            "/tmp/llama.cpp/bin/llama",
            "/tmp/llama.cpp/bin/llama-cli",
            "/tmp/llama.cpp/main"
        ])
        for p in paths { if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) } }
        throw NSError(domain: "ModelValidator", code: 404, userInfo: [NSLocalizedDescriptionKey: "llama.cpp CLI not found. Set LLAMACPP_CLI or build to /tmp/llama.cpp."])
    }

    static func quickValidateBlocking(cliURL: URL, modelURL: URL, timeoutSeconds: Double = 8) -> Bool {
        let proc = Process()
        proc.executableURL = cliURL
        proc.arguments = ["-m", modelURL.path, "-p", "test", "-n", "1"]
        let errPipe = Pipe(); proc.standardError = errPipe
        let outPipe = Pipe(); proc.standardOutput = outPipe
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
