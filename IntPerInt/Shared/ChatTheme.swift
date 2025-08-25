import SwiftUI

// MARK: - ChatTheme (canonical definition)
public struct ChatTheme {
    public static let text = Color(nsColor: .textColor)
    public static let textSecondary = Color(nsColor: .secondaryLabelColor)
    public static let background = Color(nsColor: .textBackgroundColor)
    public static let sidebar = Color(nsColor: .windowBackgroundColor).opacity(0.95)
    public static let userMessageBackground = Color.accentColor.opacity(0.2)
    public static let assistantMessageBackground = Color(nsColor: .controlBackgroundColor)
    public static let divider = Color(nsColor: .separatorColor)
    public static let inputBackground = Color(nsColor: .controlBackgroundColor)
}

public extension ChatTheme {
    static let warning = Color.orange.opacity(0.8)
    static let danger = Color.red.opacity(0.85)
    static let success = Color.green.opacity(0.8)
}
