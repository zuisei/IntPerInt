import Foundation
import os

/// UDS 経由で intperint_helper にチャット生成を委譲する LLMEngine 実装
public struct UDSLLMEngine: LLMEngine {
    private let sockPath: String
    private let log = Logger(subsystem: "com.example.IntPerInt", category: "UDSLLMEngine")
    private var modelURL: URL? = nil
    public init(sockPath: String = "/tmp/intperint.sock") { self.sockPath = sockPath }

    public mutating func load(modelPath: URL) throws { self.modelURL = modelPath }

    public func generate(
        prompt: String,
        systemPrompt: String?,
        params: GenerationParams,
        onToken: @escaping @Sendable (String) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> String {
        // ソケット接続
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw NSError(domain: "UDSLLMEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed"]) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = sockPath.utf8
        if pathBytes.count >= MemoryLayout.size(ofValue: addr.sun_path) { close(fd); throw NSError(domain: "UDSLLMEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "socket path too long"]) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        if rc != 0 { close(fd); throw NSError(domain: "UDSLLMEngine", code: 3, userInfo: [NSLocalizedDescriptionKey: "connect failed"]) }

        // JSON 構築
        var obj: [String: Any] = [
            "op": "start_chat",
            "prompt": prompt,
            "tokens": params.maxTokens
        ]
        if let modelURL { obj["model_path"] = modelURL.path }
        if let seed = params.seed { obj["seed"] = seed }
        // sentinel / system prompt 差し込みは helper 側現状シンプルなので結合
        if let sys = systemPrompt, !sys.isEmpty { obj["prompt"] = sys + "\n\n" + prompt }
        let startData = try JSONSerialization.data(withJSONObject: obj, options: [])
        let line = startData + Data([0x0a])
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

        // 読み取りループ
        var acc = ""
        let bufSize = 4096
    var partial = Data()

        func sendCancel(jobid: String) {
            let c: [String: Any] = ["op": "cancel", "jobid": jobid]
            if let d = try? JSONSerialization.data(withJSONObject: c, options: []) { _ = d.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }; _ = write(fd, "\n", 1) }
        }

        var currentJob: String? = nil
        while true {
            if isCancelled() { if let j = currentJob { sendCancel(jobid: j) }; break }
            var tmp = [UInt8](repeating: 0, count: bufSize)
            let n = read(fd, &tmp, bufSize)
            if n > 0 {
                partial.append(contentsOf: tmp[0..<n])
                while let nl = partial.firstIndex(of: 0x0a) { // '\n'
                    let lineData = partial.subdata(in: 0..<nl)
                    partial.removeSubrange(0..<(nl+1))
                    guard !lineData.isEmpty, let s = String(data: lineData, encoding: .utf8) else { continue }
                    if s.contains("\"op\":\"chat_started\"") {
                        // jobid 抜き出し
                        if let range = s.range(of: "\"jobid\":\"") { let after = s[range.upperBound...]; if let end = after.firstIndex(of: "\"") { currentJob = String(after[..<end]) } }
                    } else if s.contains("\"op\":\"token\"") {
                        if let range = s.range(of: "\"data\":\"") { let after = s[range.upperBound...]; if let end = after.firstIndex(of: "\"") { let token = String(after[..<end]); acc += token; onToken(token) } }
                    } else if s.contains("\"op\":\"done\"") { break }
                    else if s.contains("\"op\":\"error\"") { log.error("UDS error: \(s, privacy: .public)"); throw NSError(domain: "UDSLLMEngine", code: 10, userInfo: [NSLocalizedDescriptionKey: s]) }
                }
            } else if n == 0 { break } else { break }
        }
        close(fd)
        return acc
    }
}
