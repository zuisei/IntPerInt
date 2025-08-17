import Foundation

actor ConversationStore {
    static let shared = ConversationStore()
    private let fileURL: URL

    // default init for app
    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("IntPerInt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("conversations.json")
    }

    // test-only convenience init
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() async -> [Conversation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let convs = try decoder.decode([Conversation].self, from: data)
            return convs
        } catch {
            print("ConversationStore.load error: \(error)")
            return []
        }
    }

    func save(_ conversations: [Conversation]) async {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(conversations)
            // atomic write
            let tmpURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.moveItem(at: tmpURL, to: fileURL)
        } catch {
            print("ConversationStore.save error: \(error)")
        }
    }
}
