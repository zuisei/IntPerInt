import SwiftUI
import Combine
import AppKit

struct ContentView: View {
    @StateObject private var modelManager = ModelManager()
    @StateObject private var ui = UISettings()
    @State private var selectedProvider: AIProvider = .llamaCpp

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if !ui.sidebarCollapsed {
                    LeftSidebar(modelManager: modelManager)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                VStack(spacing: 0) {
                    TopToolbar(selectedProvider: $selectedProvider, modelManager: modelManager)
                        .environmentObject(ui)
                    ChatGPTConversationView(
                        modelManager: modelManager,
                        selectedProvider: $selectedProvider
                    )
                    .environmentObject(ui)
                }
            }
            if ui.showAdvancedSettings { HStack { Spacer(); settingsPanel.frame(width: 280).transition(.move(edge: .trailing)) } }
            if ui.showCommandPalette { Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { ui.showCommandPalette = false }; centerOverlay }
        }
        .environmentObject(ui)
        .animation(ui.enableAnimations ? .easeInOut(duration: 0.22) : nil, value: ui.sidebarCollapsed)
    }
}

// MARK: Settings Panel Wrapper
extension ContentView {
    private var settingsPanel: some View {
        VStack(spacing: 16) {
            HStack { Text("Interface").font(.headline); Spacer(); Button(action:{ui.showAdvancedSettings=false}){Image(systemName:"xmark").font(.caption)}.buttonStyle(.plain) }
            Picker("Message Style", selection: $ui.messageStyle) { ForEach(UISettings.MessageStyle.allCases, id: \.self){ Text($0.rawValue) } }
                .pickerStyle(.segmented)
            Picker("Density", selection: $ui.density) { ForEach(UISettings.Density.allCases, id: \.self){ Text($0.rawValue) } }
                .pickerStyle(.segmented)
            HStack { Text("Font Scale"); Slider(value: $ui.fontScale, in: 0.85...1.5, step: 0.01); Text(String(format: "%.2f", ui.fontScale)).font(.caption.monospacedDigit()) }
            Toggle("Timestamps", isOn: $ui.showTimestamps)
            Toggle("Token Cursor", isOn: $ui.showTokenCursor)
            Toggle("Animations", isOn: $ui.enableAnimations)
            HStack { Text("Max Width"); Slider(value: $ui.preferredMaxContentWidth, in: 640...1000); Text(Int(ui.preferredMaxContentWidth).description).font(.caption) }
            if !modelManager.downloadProgress.isEmpty {
                Divider().padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Model Downloads").font(.headline)
                    ForEach(modelManager.downloadProgress.keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading) {
                            Text(key).font(.caption)
                            ProgressView(value: modelManager.downloadProgress[key] ?? 0)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(18)
        .background(ChatTheme.sidebar)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(ChatTheme.divider,lineWidth:1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.top, 50)
        .padding(.trailing, 12)
    }
    private var centerOverlay: some View {
        VStack { CommandPaletteView(settings: ui, commands: paletteCommands){ $0.action() } }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    private var paletteCommands: [UIPaletteCommand] {
        [
            UIPaletteCommand(title: "Toggle Sidebar", subtitle: nil, icon: "sidebar.left", shortcut: "⌘B", action: { ui.sidebarCollapsed.toggle() }),
            UIPaletteCommand(title: "Interface Settings", subtitle: "Open UI panel", icon: "slider.horizontal.3", shortcut: "⌘,", action: { ui.showAdvancedSettings = true }),
            UIPaletteCommand(title: "Hide Command Palette", subtitle: "Close", icon: "xmark", shortcut: "ESC", action: { ui.showCommandPalette=false })
        ]
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
