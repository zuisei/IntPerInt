import SwiftUI
import Combine

final class UISettings: ObservableObject {
    // MARK: - Sidebar
    @Published var sidebarCollapsed: Bool = false

    // MARK: - Command Palette
    @Published var showCommandPalette: Bool = false

    // MARK: - Advanced Settings Panel
    @Published var showAdvancedSettings: Bool = false

    // MARK: - Message Appearance
    enum MessageStyle: String, CaseIterable { case bubbly, plain }
    @Published var messageStyle: MessageStyle = .bubbly

    enum Density: String, CaseIterable { case compact, comfortable, spacious }
    @Published var density: Density = .comfortable

    @Published var fontScale: Double = 1.0
    @Published var showTimestamps: Bool = false
    @Published var showTokenCursor: Bool = true
    @Published var preferredMaxContentWidth: Double = 800

    // MARK: - General
    @Published var enableAnimations: Bool = true
}
