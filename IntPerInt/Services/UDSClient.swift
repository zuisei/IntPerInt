import Foundation
import Network

enum UDSClientError: Error { case notConnected, invalidResponse }

final class UDSClient {
    private let path: String
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "uds.client.queue")

    init(path: String = "/tmp/intperint.sock") { self.path = path }

    func connect(completion: @escaping (Error?) -> Void) {
        let endpoint = NWEndpoint.unix(path: path)
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: completion(nil)
            case .failed(let e): completion(e)
            case .cancelled:
                completion(NSError(domain: "UDS", code: -1, userInfo: [NSLocalizedDescriptionKey: "cancelled"]))
            default: break
            }
        }
        conn.start(queue: queue)
    }

    func close() { connection?.cancel(); connection = nil }

    // single request -> single line response
    func send(json: [String: Any], timeout: TimeInterval = 15, completion: @escaping ([String: Any]?, Error?) -> Void) {
        guard let conn = connection else { completion(nil, UDSClientError.notConnected); return }
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: [])
            var payload = Data(); payload.append(data); payload.append(0x0A)
            conn.send(content: payload, completion: .contentProcessed { sendErr in
                if let e = sendErr { completion(nil, e); return }
                self.receiveOneJSON(conn: conn, timeout: timeout, completion: completion)
            })
        } catch { completion(nil, error) }
    }

    // request -> streaming multiple JSON lines
    func sendAndStream(json: [String: Any], onEvent: @escaping ([String: Any]) -> Void, onDone: @escaping (Error?) -> Void) {
        guard let conn = connection else { onDone(UDSClientError.notConnected); return }
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: [])
            var payload = Data(); payload.append(data); payload.append(0x0A)
            conn.send(content: payload, completion: .contentProcessed { sendErr in
                if let e = sendErr { onDone(e); return }
                self.receiveStream(conn: conn, onEvent: onEvent, onDone: onDone)
            })
        } catch { onDone(error) }
    }

    private func receiveOneJSON(conn: NWConnection, timeout: TimeInterval, completion: @escaping ([String: Any]?, Error?) -> Void) {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        func loop() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { content, _, _, err in
                if let e = err { completion(nil, e); return }
                if let content = content {
                    buffer.append(content)
                    if let idx = buffer.firstIndex(of: 0x0A) {
                        let line = buffer.subdata(in: 0..<idx)
                        do {
                            if let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] {
                                completion(obj, nil)
                            } else { completion(nil, UDSClientError.invalidResponse) }
                        } catch { completion(nil, error) }
                        return
                    }
                    if Date() > deadline {
                        completion(nil, NSError(domain: "UDS", code: 2, userInfo: [NSLocalizedDescriptionKey: "timeout receiving"]))
                        return
                    }
                    loop()
                } else {
                    completion(nil, NSError(domain: "UDS", code: 3, userInfo: [NSLocalizedDescriptionKey: "no content"]))
                }
            }
        }
        loop()
    }

    private func receiveStream(conn: NWConnection, onEvent: @escaping ([String: Any]) -> Void, onDone: @escaping (Error?) -> Void) {
        var buffer = Data()
        func loop() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { content, _, _, err in
                if let e = err { onDone(e); return }
                guard let content = content, !content.isEmpty else { onDone(NSError(domain: "UDS", code: 5, userInfo: [NSLocalizedDescriptionKey: "no content"])) ; return }
                buffer.append(content)
                while let idx = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: 0..<idx)
                    buffer.removeSubrange(0...idx)
                    if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        if let op = obj["op"] as? String {
                            if op == "done" { onDone(nil); return }
                            else if op == "error" {
                                let msg = (obj["error"] as? String) ?? "error"
                                onDone(NSError(domain: "UDS", code: 6, userInfo: [NSLocalizedDescriptionKey: msg])); return
                            }
                        }
                        onEvent(obj)
                    }
                }
                loop()
            }
        }
        loop()
    }
}
