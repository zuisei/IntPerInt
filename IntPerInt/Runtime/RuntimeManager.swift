import Foundation

/// Provisions a self-contained llama.cpp runtime under Application Support.
/// Layout:
///   ~/Library/Application Support/IntPerInt/runtime/
///     bin/{llama|llama-cli}
///     share/llama.cpp/default.metallib
enum RuntimeManager {
    static var baseDir: URL {
        let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSup.appendingPathComponent("IntPerInt/runtime", isDirectory: true)
    }
    static var binDir: URL { baseDir.appendingPathComponent("bin", isDirectory: true) }
    static var shareDir: URL { baseDir.appendingPathComponent("share/llama.cpp", isDirectory: true) }

    /// Returns current managed executable if present.
    static func currentExec() -> URL? {
        let fm = FileManager.default
        let cands = [binDir.appendingPathComponent("llama-cli"), binDir.appendingPathComponent("llama")]
        for u in cands where fm.isExecutableFile(atPath: u.path) { return u }
        return nil
    }

    /// Ensure dirs exist.
    @discardableResult
    private static func ensureDirs() throws -> (URL, URL) {
        let fm = FileManager.default
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: shareDir, withIntermediateDirectories: true)
        return (binDir, shareDir)
    }

    /// Provision from app bundle resources if present: Bundle.main.resourceURL/runtime/**
    /// Returns path to installed executable.
    static func provisionFromBundle() throws -> URL {
        let fm = FileManager.default
        try ensureDirs()
        guard let res = Bundle.main.resourceURL else {
            throw NSError(domain: "RuntimeManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "bundle resources unavailable"])
        }
        // Support either runtime/ directly under Resources or nested under BundledRuntime/
        let runtimeDirCandidates = [
            res.appendingPathComponent("runtime", isDirectory: true),
            res.appendingPathComponent("BundledRuntime/runtime", isDirectory: true)
        ]
        guard let runtimeDir = runtimeDirCandidates.first(where: { var isDir: ObjCBool = false; return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue }) else {
            throw NSError(domain: "RuntimeManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "bundled runtime not found"])
        }
        // copy exec
        let execCandidates = ["llama-cli", "llama"].map { runtimeDir.appendingPathComponent("bin/") .appendingPathComponent($0) }
        guard let execSrc = execCandidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            throw NSError(domain: "RuntimeManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "bundled llama executable missing"])
        }
        let installed = try install(fromExec: execSrc)
        // copy metallib if exists in bundled share
        let metalSrc = runtimeDir.appendingPathComponent("share/llama.cpp/default.metallib")
        if fm.fileExists(atPath: metalSrc.path) {
            let target = shareDir.appendingPathComponent("default.metallib")
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            try? fm.copyItem(at: metalSrc, to: target)
        }
        return installed
    }

    /// Provision from known system locations (Homebrew opt/Cellar, PATH) into runtime.
    /// Returns path to installed executable.
    static func provisionFromSystem() throws -> URL {
        let fm = FileManager.default
        try ensureDirs()
        // Candidate executables
        var execs: [String] = [
            "/opt/homebrew/opt/llama.cpp/bin/llama",
            "/opt/homebrew/opt/llama.cpp/bin/llama-cli",
            "/usr/local/opt/llama.cpp/bin/llama",
            "/usr/local/opt/llama.cpp/bin/llama-cli",
            "/opt/homebrew/bin/llama",
            "/opt/homebrew/bin/llama-cli",
            "/usr/local/bin/llama",
            "/usr/local/bin/llama-cli"
        ]
        // PATH which fallback
        if let w1 = which("llama") { execs.insert(w1, at: 0) }
        if let w2 = which("llama-cli") { execs.insert(w2, at: 0) }

        guard let srcPath = execs.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "RuntimeManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "llama executable not found on system"])
        }
        let src = URL(fileURLWithPath: srcPath).resolvingSymlinksInPath()
        return try install(fromExec: src)
    }

    /// Provision from a user-specified executable path into runtime.
    static func install(fromExec exec: URL) throws -> URL {
        let fm = FileManager.default
        try ensureDirs()
        let name = exec.lastPathComponent == "llama" || exec.lastPathComponent == "llama-cli" ? exec.lastPathComponent : "llama"
        let dst = binDir.appendingPathComponent(name)
        if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
        try fm.copyItem(at: exec, to: dst)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        // metallib: look in common locations relative to exec
        if let metal = locateDefaultMetallib(nearExec: exec) {
            let target = shareDir.appendingPathComponent("default.metallib")
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            try? fm.copyItem(at: metal, to: target)
        }
        return dst
    }

    /// Find metallib near a given exec (exec dir, ../share/llama.cpp, Homebrew opt share).
    static func locateDefaultMetallib(nearExec exec: URL) -> URL? {
        let fm = FileManager.default
        let execDir = exec.deletingLastPathComponent()
        let candidates: [URL] = [
            execDir.appendingPathComponent("default.metallib"),
            execDir.deletingLastPathComponent().appendingPathComponent("share/llama.cpp/default.metallib"),
            URL(fileURLWithPath: "/opt/homebrew/opt/llama.cpp/share/llama.cpp/default.metallib"),
            URL(fileURLWithPath: "/usr/local/opt/llama.cpp/share/llama.cpp/default.metallib")
        ]
        for u in candidates where fm.fileExists(atPath: u.path) { return u }
        return nil
    }

    private static func which(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [name]
        let out = Pipe(); p.standardOutput = out
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }
}
