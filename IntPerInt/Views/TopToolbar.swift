import SwiftUI
import Foundation

struct TopToolbar: View {
    @Binding var selectedProvider: AIProvider
    @ObservedObject var modelManager: ModelManager
    @EnvironmentObject private var ui: UISettings

    var body: some View {
        HStack(spacing: 14) {
            // Sidebar toggle
            Button(action: { withAnimation(.easeInOut(duration: 0.25)) { ui.sidebarCollapsed.toggle() } }) {
                Image(systemName: ui.sidebarCollapsed ? "sidebar.right" : "sidebar.left")
                    .font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Toggle Sidebar")

            // Provider picker
            Picker("Provider", selection: $selectedProvider) {
                ForEach(AIProvider.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)

            // Model picker
            Picker("Model", selection: Binding(
                get: { currentConversationModel ?? "__none__" },
                set: { name in setCurrentModel(name == "__none__" ? "" : name) }
            )) {
                Text("Select Model…").tag("__none__")
                if modelManager.validInstalledModels.isEmpty {
                    Text("(No Valid Models)").tag("__no_models__").disabled(true)
                } else {
                    ForEach(modelManager.validInstalledModels, id: \.fileName) { m in
                        Text(prettyModelName(m.fileName)).tag(m.fileName)
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(width: 170)
            .help("Select Model")

            // Status chip
            statusChip

            Spacer()

            Button(action: { ui.showAdvancedSettings.toggle() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Advanced Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().frame(height: 0.5).foregroundColor(Color(NSColor.separatorColor)).opacity(0.6)
        }
    }

    // MARK: - Helpers
    private var currentConversationModel: String? {
        guard let id = modelManager.selectedConversationID,
              let conv = modelManager.conversations.first(where: { $0.id == id }) else { return nil }
        return conv.model
    }

    private func setCurrentModel(_ name: String) {
        guard !name.isEmpty else { return }
        modelManager.setCurrentModelForSelectedConversation(name: name)
    }

    private func prettyModelName(_ raw: String) -> String {
        raw.replacingOccurrences(of: ".gguf", with: "")
            .replacingOccurrences(of: "-", with: " ")
    }

    @ViewBuilder
    private var statusChip: some View {
        switch modelManager.engineStatus {
        case .idle:
            ChipView(text: "Idle", color: .gray.opacity(0.25))
        case .loading(let n):
            ChipView(text: "Loading…" + trimName(n), color: .orange.opacity(0.35), progress: true)
        case .loaded(let n):
            ChipView(text: trimName(n), color: .green.opacity(0.35))
        case .failed(let msg):
            ChipView(text: "Error", color: .red.opacity(0.35), tooltip: msg)
        }
    }

    private func trimName(_ n: String) -> String { String(n.prefix(18)) }
}

private struct ChipView: View {
    let text: String
    let color: Color
    var progress: Bool = false
    var tooltip: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if progress { ProgressView().scaleEffect(0.4) }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(color)
                .clipShape(Capsule())
        }
        .help(tooltip ?? text)
    }
}
