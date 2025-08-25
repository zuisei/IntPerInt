import Foundation

enum OutputCleaner {
    static func removeANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{001B}[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }
    static func stripSentinel(_ s: String, sentinel: String) -> String {
        if let r = s.range(of: sentinel) { return String(s[r.upperBound...]) } else { return s }
    }
    static func stripTags(_ s: String) -> String { s.replacingOccurrences(of: "<\\|[^>]+\\|>", with: "", options: .regularExpression) }
    static func clean(raw: String, sentinel: String = "<|OUTPUT|>") -> String {
        var t = stripSentinel(removeANSI(raw), sentinel: sentinel)
        t = stripTags(t)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
