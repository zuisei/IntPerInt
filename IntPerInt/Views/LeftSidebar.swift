import SwiftUI
import Combine
import Foundation
// Models.swift の型をモジュール内で明示利用

// 左サイドバー刷新: 日付グルーピング + 折りたたみ + インラインリネーム + モデルバッジ + relative time + 検索ハイライト
struct LeftSidebar: View {
    @ObservedObject var modelManager: ModelManager
    @State private var hoverID: Conversation.ID? = nil
    @State private var search = ""
    @State private var collapsedSections: Set<String> = []
    @State private var renamingID: Conversation.ID? = nil
    @State private var draftTitle: String = ""

    private let width: CGFloat = 260

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ChatTheme.divider).padding(.bottom, 2)
            searchField
            ScrollView {
                LazyVStack(spacing: 10, pinnedViews: [.sectionHeaders]) {
                    if isSearching {
                        Section(header: sectionHeader(title: "Search Results", icon: "magnifyingglass", collapsible: false)) {
                            ForEach(filteredFlat) { conv in
                                cell(for: conv)
                            }
                        }
                    } else {
                        ForEach(groupedSections) { section in
                            Section(header: sectionHeader(title: section.title, icon: section.icon, collapsible: true)) {
                                if !collapsedSections.contains(section.title) {
                                    ForEach(section.items) { conv in
                                        cell(for: conv)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
        }
        .frame(minWidth: width, maxWidth: width)
        .background(
            LinearGradient(colors: [ChatTheme.sidebar, ChatTheme.background.opacity(0.2)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    // MARK: - Header
    private var header: some View {
        HStack(spacing: 8) {
            Text("Conversations")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))
            Spacer()
            Button(action: { modelManager.newConversation() }) {
                Label("New", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.9))
            .help("New Chat")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Search
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: 12))
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
                .onSubmit { /* no-op */ }
            if !search.isEmpty {
                Button(action: { search = "" }) { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .accessibilityLabel("Clear Search")
            }
        }
        .padding(8)
        .background(ChatTheme.background.opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ChatTheme.divider.opacity(0.4), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Grouping
    private struct SectionData: Identifiable { let id = UUID(); let title: String; let icon: String; let items: [Conversation] }

    private var groupedSections: [SectionData] {
        var buckets: [String: [Conversation]] = [:]
        let cal = Calendar.current; let now = Date()
        func key(_ d: Date) -> String {
            if cal.isDate(d, inSameDayAs: now) { return "Today" }
            if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
            if let week = cal.date(byAdding: .day, value: -7, to: now), d > week { return "Last 7 Days" }
            if let month = cal.date(byAdding: .day, value: -30, to: now), d > month { return "Last 30 Days" }
            return "Older"
        }
        for c in modelManager.conversations { buckets[key(c.updatedAt), default: []].append(c) }
        let order = ["Today","Yesterday","Last 7 Days","Last 30 Days","Older"]
        return order.compactMap { k in
            guard var items = buckets[k] else { return nil }
            items.sort { $0.updatedAt > $1.updatedAt }
            let icon: String
            if k == "Today" { icon = "sun.max" }
            else if k == "Yesterday" { icon = "moon" }
            else if k == "Last 7 Days" { icon = "calendar" }
            else if k == "Last 30 Days" { icon = "calendar.badge.clock" }
            else { icon = "archivebox" }
            return SectionData(title: k, icon: icon, items: items)
        }
    }

    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }
    private var filteredFlat: [Conversation] {
        guard isSearching else { return modelManager.conversations }
        return modelManager.conversations.filter { c in
            if c.title.localizedCaseInsensitiveContains(search) { return true }
            return c.messages.last?.content.localizedCaseInsensitiveContains(search) ?? false
        }
    }

    // MARK: - Section Header
    private func sectionHeader(title: String, icon: String, collapsible: Bool) -> some View {
        HStack(spacing: 6) {
            if collapsible {
                Button(action: { toggleSection(title) }) {
                    Image(systemName: collapsedSections.contains(title) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
            Image(systemName: icon).foregroundColor(.white.opacity(0.55)).font(.system(size: 11))
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.6))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 2)
        .background(Color.clear.blur(radius: 0))
    }

    private func toggleSection(_ title: String) { if collapsedSections.contains(title) { collapsedSections.remove(title) } else { collapsedSections.insert(title) } }

    // MARK: - Conversation Cell
    private func cell(for c: Conversation) -> some View {
        ConversationCell(
            conversation: c,
            isSelected: c.id == modelManager.selectedConversationID,
            hovered: hoverID == c.id,
            isRenaming: renamingID == c.id,
            draftTitle: renamingID == c.id ? $draftTitle : .constant(""),
            searchTerm: search,
            onCommitRename: { title in commitRename(c, title: title) },
            onDelete: { delete(c) },
            onSelect: { select(c) },
            onBeginRename: { beginRename(c) }
        )
        .onHover { h in hoverID = h ? c.id : nil }
    }

    private func beginRename(_ c: Conversation) { renamingID = c.id; draftTitle = c.title.isEmpty ? "New Chat" : c.title }
    private func commitRename(_ c: Conversation, title: String) {
        guard let idx = modelManager.conversations.firstIndex(where: { $0.id == c.id }) else { return }
        modelManager.conversations[idx].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingID = nil
    }
    private func select(_ c: Conversation) { modelManager.selectConversation(c.id) }
    private func delete(_ c: Conversation) {
        if let idx = modelManager.conversations.firstIndex(where: { $0.id == c.id }) {
            modelManager.deleteConversation(at: IndexSet(integer: idx))
        }
    }
}

// MARK: - Conversation Cell Implementation
private struct ConversationCell: View {
    let conversation: Conversation
    let isSelected: Bool
    let hovered: Bool
    let isRenaming: Bool
    @Binding var draftTitle: String
    let searchTerm: String
    let onCommitRename: (String)->Void
    let onDelete: ()->Void
    let onSelect: ()->Void
    let onBeginRename: ()->Void

    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                if isRenaming {
                    TextField("Title", text: $draftTitle, onCommit: { onCommitRename(draftTitle) })
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .focused($titleFieldFocused)
                        .onAppear { titleFieldFocused = true }
                } else {
                    highlighted(text: conversation.title.isEmpty ? "New Chat" : conversation.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)
                        .onTapGesture(count: 2, perform: onBeginRename)
                }
                Spacer(minLength: 4)
                if hovered && !isRenaming {
                    HStack(spacing: 6) {
                        if conversation.model != nil { modelBadge }
                        Button(action: onBeginRename) { Image(systemName: "pencil").font(.system(size: 11, weight: .semibold)) }
                            .buttonStyle(.plain)
                            .foregroundColor(.white.opacity(0.6))
                            .help("Rename")
                        Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 11, weight: .semibold)) }
                            .buttonStyle(.plain)
                            .foregroundColor(.red.opacity(0.75))
                            .help("Delete")
                    }
                    .padding(.trailing, 2)
                }
            }
            if let last = conversation.messages.last?.content, !last.isEmpty {
                highlighted(text: last)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                if let model = conversation.model { modelChip(model) }
                Text(relativeTime(conversation.updatedAt))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
                Spacer()
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if !isRenaming { onSelect() } }
        .contextMenu {
            Button(action: onSelect) { Label("Open", systemImage: "arrow.forward") }
            Button(action: onBeginRename) { Label("Rename", systemImage: "pencil") }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
        .onSubmit { if isRenaming { onCommitRename(draftTitle) } }
        .onChange(of: titleFieldFocused) { focused in if !focused && isRenaming { onCommitRename(draftTitle) } }
    }

    // MARK: - UI Helpers
    private var rowBackground: some View {
        Group {
            if isSelected { ChatTheme.background.opacity(0.9) }
            else if hovered { ChatTheme.background.opacity(0.55) }
            else { Color.white.opacity(0.05) }
        }
    }

    private var modelBadge: some View {
        Circle().fill(Color.accentColor.opacity(0.8)).frame(width: 6, height: 6)
    }

    private func modelChip(_ name: String) -> some View {
        Text(prettyModelName(name))
            .font(.system(size: 9, weight: .semibold))
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(Color.accentColor.opacity(0.25))
            .foregroundColor(.white.opacity(0.85))
            .clipShape(Capsule())
            .help(name)
    }

    private func prettyModelName(_ raw: String) -> String {
        raw.replacingOccurrences(of: ".gguf", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .prefix(18)
            .trimmingCharacters(in: .whitespaces)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let m = seconds / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        if h < 24 { return "\(h)h ago" }
        let d = h / 24
        if d < 7 { return "\(d)d ago" }
        let fmt = DateFormatter(); fmt.dateFormat = "MMM d"; return fmt.string(from: date)
    }

    private func highlighted(text: String) -> Text {
        guard !searchTerm.isEmpty else { return Text(text) }
        let lower = text.lowercased()
        let term = searchTerm.lowercased()
        guard let range = lower.range(of: term) else { return Text(text) }
        let start = String(text[..<range.lowerBound])
        let match = String(text[range])
        let end = String(text[range.upperBound...])
        return Text(start) + Text(match).foregroundColor(.accentColor) + Text(end)
    }
}
