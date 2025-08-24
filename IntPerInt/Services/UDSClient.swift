import Foundation

/// JSON Lines クライアント (UNIX Domain Socket)
final class UDSClient: @unchecked Sendable {
    private let socketPath: String
    init(socketPath: String = "/tmp/intperint.sock") { self.socketPath = socketPath }

    enum UDSClientError: Error { case connectFailed, writeFailed, readFailed, timeout }

    /// 1リクエスト (複数行応答想定時は handler で逐次処理)
    func sendLines(lines: [String], onLine: @escaping (String)->Void) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw UDSClientError.connectFailed }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let pathData = socketPath.utf8
        guard pathData.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw UDSClientError.connectFailed }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: pathData)
            buf[pathData.count] = 0
        }
        let size = socklen_t(MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size + pathData.count + 1)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        if rc != 0 { close(fd); throw UDSClientError.connectFailed }
        // write
        for l in lines {
            let line = l.hasSuffix("\n") ? l : l + "\n"
            line.withCString { cstr in _ = write(fd, cstr, strlen(cstr)) }
        }
        // read until EOF (caller decides when to stop by server semantics)
        let bufSize = 4096
        var data = Data(); data.reserveCapacity(bufSize)
        var tmp = [UInt8](repeating: 0, count: bufSize)
        while true {
            let n = read(fd, &tmp, bufSize)
            if n > 0 {
                data.append(contentsOf: tmp[0..<n])
                // dispatch complete lines
                while let range = data.firstRange(of: Data([0x0a])) { // \n
                    let lineData = data.subdata(in: 0..<range.lowerBound)
                    if let s = String(data: lineData, encoding: .utf8) { onLine(s) }
                    data.removeSubrange(0..<range.upperBound)
                }
            } else if n == 0 { break } else { break }
        }
        close(fd)
    }
}
