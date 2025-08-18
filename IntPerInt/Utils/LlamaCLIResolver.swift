import Foundation

/// Resolves the llama.cpp CLI executable path in a robust and unified way.
/// Priority:
/// 1) $LLAMACPP_CLI
/// 2) Homebrew symlinks (/opt/homebrew/bin, /usr/local/bin)
/// 3) Homebrew opt keg (/opt/homebrew/opt/llama.cpp/bin, /usr/local/opt/llama.cpp/bin)
/// 4) Common local build locations under /tmp/llama.cpp
public enum LlamaCLIResolver {
    public static func resolve() throws -> URL {
        let fm = FileManager.default
        for path in candidates() {
            if fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        throw notFoundError()
    }

    public static func candidates() -> [String] {
        var paths: [String] = []
    // App-managed location (Application Support/IntPerInt/bin)
    if let appBin = appManagedCLIPaths().first { paths.append(appBin) }
        if let env = ProcessInfo.processInfo.environment["LLAMACPP_CLI"], !env.isEmpty {
            paths.append(env)
        }
        // Homebrew common bins first
        paths.append(contentsOf: [
            "/opt/homebrew/bin/llama-cli",
            "/usr/local/bin/llama-cli",
            "/opt/homebrew/bin/llama",
            "/usr/local/bin/llama",
        ])
        // Homebrew opt keg (stable symlink to current version)
        paths.append(contentsOf: [
            "/opt/homebrew/opt/llama.cpp/bin/llama-cli",
            "/usr/local/opt/llama.cpp/bin/llama-cli",
            "/opt/homebrew/opt/llama.cpp/bin/llama",
            "/usr/local/opt/llama.cpp/bin/llama",
        ])
    // Homebrew Cellar (versioned) — bin or libexec (fallback)
    paths.append(contentsOf: cellarCandidates(prefix: "/opt/homebrew/Cellar/llama.cpp"))
    paths.append(contentsOf: cellarCandidates(prefix: "/usr/local/Cellar/llama.cpp"))
        // Typical local build locations
        paths.append(contentsOf: [
            "/tmp/llama.cpp/build/bin/llama-cli",
            "/tmp/llama.cpp/bin/llama-cli",
            "/tmp/llama.cpp/main",
            "/tmp/llama.cpp/build/bin/llama",
            "/tmp/llama.cpp/bin/llama",
        ])
        return paths
    }

    public static func notFoundError() -> NSError {
        let msg = "llama.cpp CLI not found. Set LLAMACPP_CLI, `brew install llama.cpp`, or build to /tmp/llama.cpp."
        return NSError(domain: "LlamaCLIResolver", code: 404, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

// MARK: - Private helpers
private extension LlamaCLIResolver {
    static func appManagedCLIPaths() -> [String] {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return [] }
        let dir = base.appendingPathComponent("IntPerInt/bin", isDirectory: true)
        return [
            dir.appendingPathComponent("llama-cli").path,
            dir.appendingPathComponent("llama").path,
        ]
    }
    static func cellarCandidates(prefix: String) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: prefix, isDirectory: &isDir), isDir.boolValue,
           let entries = try? fm.contentsOfDirectory(atPath: prefix) {
            // sort versions descending (numeric)
            let versions = entries.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for v in versions.prefix(3) {
                let base = prefix + "/" + v
                out += [
                    base + "/bin/llama-cli",
                    base + "/bin/llama",
                    base + "/libexec/llama-cli",
                    base + "/libexec/llama",
                ]
            }
        }
        return out
    }
}
