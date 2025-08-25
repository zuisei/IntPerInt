import SwiftUI

struct UIPaletteCommand: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let icon: String
    let shortcut: String?
    let action: () -> Void

    static func == (lhs: UIPaletteCommand, rhs: UIPaletteCommand) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
