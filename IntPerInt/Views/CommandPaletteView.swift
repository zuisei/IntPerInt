import SwiftUI

struct CommandPaletteView: View {
    let settings: UISettings
    let commands: [UIPaletteCommand]
    let onCommand: (UIPaletteCommand) -> Void
    
    @State private var searchText = ""
    
    private var filteredCommands: [UIPaletteCommand] {
        if searchText.isEmpty {
            return commands
        }
        return commands.filter { command in
            command.title.localizedCaseInsensitiveContains(searchText) ||
            command.subtitle?.localizedCaseInsensitiveContains(searchText) == true
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search commands...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            
            Divider()
                .padding(.vertical, 8)
            
            // Commands list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredCommands, id: \.id) { command in
                        CommandRow(command: command) {
                            onCommand(command)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(16)
        .frame(width: 400, height: 300)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
    }
}

struct CommandRow: View {
    let command: UIPaletteCommand
    let onTap: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: command.icon)
                .frame(width: 20, height: 20)
                .foregroundColor(.primary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                    .font(.system(size: 14, weight: .medium))
                if let subtitle = command.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(NSColor.quaternaryLabelColor))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color(NSColor.selectedControlColor) : Color.clear)
        .cornerRadius(6)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            onTap()
        }
    }
}
