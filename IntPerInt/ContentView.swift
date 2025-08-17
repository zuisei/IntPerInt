import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var modelManager = ModelManager()
    @State private var selectedProvider: AIProvider = .llamaCpp
    @State private var messageInput = ""
    @State private var selectedModel: String? = nil

    var body: some View {
        NavigationSplitView {
            // Sidebar: ChatGPT風 会話リスト
            VStack(spacing: 8) {
                HStack {
                    Button {
                        modelManager.newConversation()
                    } label: {
                        Label("New Chat", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)

                // Search placeholder
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("Search").foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06))
                )
                .padding(.horizontal, 10)

                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(modelManager.conversations) { conv in
                            ConversationRow(
                                conversation: conv,
                                isSelected: conv.id == modelManager.selectedConversationID
                            ) {
                                modelManager.selectConversation(conv.id)
                            }
                        }
                        .onDelete { indexSet in
                            modelManager.deleteConversation(at: indexSet)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                }

                Spacer()
            }
            .frame(minWidth: 260)
        } detail: {
            VStack(spacing: 0) {
                // 右上ヘッダー：会話ごとのProvider/Model選択
                HStack(spacing: 8) {
                    if !modelManager.availableModels.isEmpty {
                        // 選択値は String（非Optional）に統一
                        Picker("Model", selection: Binding<String>(
                            get: {
                                if let id = modelManager.selectedConversationID,
                                   let conv = modelManager.conversations.first(where: { $0.id == id }) {
                                    return conv.modelName ?? (selectedModel ?? modelManager.availableModels.first!)
                                }
                                return selectedModel ?? modelManager.availableModels.first!
                            },
                            set: { newVal in
                                if let id = modelManager.selectedConversationID,
                                   let idx = modelManager.conversations.firstIndex(where: { $0.id == id }) {
                                    modelManager.conversations[idx].modelName = newVal
                                }
                                selectedModel = newVal
                            }
                        )) {
                            ForEach(modelManager.availableModels, id: \.self) { m in
                                Text(m).tag(m)
                            }
                        }
                        .frame(maxWidth: 320)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial)

                // チャット本文
                ChatArea(
                    messages: modelManager.messages,
                    isGenerating: modelManager.isGenerating,
                    selectedModel: selectedModel,
                    messageInput: $messageInput,
                    onSend: sendMessage,
                    onCancel: { modelManager.cancelGeneration() }
                )
            }
        }
        .onAppear { modelManager.loadAvailableModels() }
        .onChange(of: modelManager.availableModels) { models in
            // 初回ロード/更新時、会話やローカル未選択なら自動選択
            if let first = (models.first { $0.hasSuffix(".gguf") } ?? models.first) {
                if selectedModel == nil { selectedModel = first }
                if let id = modelManager.selectedConversationID,
                   let idx = modelManager.conversations.firstIndex(where: { $0.id == id }),
                   modelManager.conversations[idx].modelName == nil {
                    modelManager.conversations[idx].modelName = first
                }
            }
        }
        .onChange(of: modelManager.selectedConversationID) { _ in
            // 会話切替時、モデル未設定なら自動で割り当て
            guard let id = modelManager.selectedConversationID else { return }
            if let first = (modelManager.availableModels.first { $0.hasSuffix(".gguf") } ?? modelManager.availableModels.first),
               let idx = modelManager.conversations.firstIndex(where: { $0.id == id }),
               modelManager.conversations[idx].modelName == nil {
                modelManager.conversations[idx].modelName = first
            }
        }
    }

    private func sendMessage() {
        let trimmed = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 会話ごとのModelを優先（Providerはグローバル設定を使用）
    let providerToUse = selectedProvider
    var modelToUse = selectedModel
        if let id = modelManager.selectedConversationID,
           let conv = modelManager.conversations.first(where: { $0.id == id }) {
            modelToUse = conv.modelName ?? modelToUse
        }
        // モデル未選択時は自動選択
        if modelToUse == nil {
            modelToUse = (modelManager.availableModels.first { $0.hasSuffix(".gguf") } ?? modelManager.availableModels.first)
            // 会話に反映
            if let id = modelManager.selectedConversationID,
               let idx = modelManager.conversations.firstIndex(where: { $0.id == id }) {
                modelManager.conversations[idx].modelName = modelToUse
            }
            selectedModel = modelToUse
        }
    guard let model = modelToUse else { return }

        messageInput = ""
        modelManager.sendMessage(trimmed, using: model, provider: providerToUse)
    }
}

private struct ChatArea: View {
    let messages: [ChatMessage]
    let isGenerating: Bool
    let selectedModel: String?
    @Binding var messageInput: String
    let onSend: () -> Void
    let onCancel: () -> Void
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Messages (中央カラム)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .center, spacing: 8) {
                        ForEach(messages) { message in
                            HStack {
                                Spacer(minLength: 0)
                                ChatMessageRow(message: message)
                                    .frame(maxWidth: 900)
                                    .id(message.id)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .onChange(of: messages.count) { _ in
                    if let last = messages.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }

            // 入力バー（ChatGPT風フローティング）
            VStack(spacing: 6) {
                HStack {
                    Spacer(minLength: 0)

                    // 入力ピル本体
                    HStack(spacing: 10) {
                        // 左アイコン群
                        HStack(spacing: 8) {
                            Button(action: {}) { Image(systemName: "plus") }
                            Button(action: {}) { Image(systemName: "paperclip") }
                            Button(action: {}) { Image(systemName: "globe") }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        // エディタ＋プレースホルダ
                        ZStack(alignment: .leading) {
                            if messageInput.isEmpty {
                                Text("Ask anything")
                                    .foregroundStyle(.secondary)
                            }
                            TextEditor(text: $messageInput)
                                .font(.body)
                                .frame(height: 40)
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)
                                .focused($isInputFocused)
                        }

                        // 右アイコン群
                        HStack(spacing: 8) {
                            Button(action: {}) { Image(systemName: "bolt.fill") }
                            Button(action: {}) { Image(systemName: "mic.fill") }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    // 送信ボタンの重なり分だけ右側に余白を確保
                    .padding(.trailing, 36)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .shadow(color: .black.opacity(0.15), radius: 8, y: 1)
                    )
                    .frame(maxWidth: 900)
                    // 送信ボタンを重ねて右に半分はみ出す
                        .overlay(alignment: .trailing) {
                            if isGenerating {
                                Button(action: onCancel) {
                                    Image(systemName: "stop.fill")
                                        .imageScale(.medium)
                                        .foregroundStyle(.white)
                                        .padding(12)
                                        .background(Color.red, in: Circle())
                                }
                                .offset(x: 12)
                            } else {
                                Button(action: onSend) {
                                    Image(systemName: "paperplane.fill")
                                        .imageScale(.medium)
                                        .foregroundStyle(.white)
                                        .padding(12)
                                        .background((messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedModel == nil) ? Color.accentColor.opacity(0.5) : Color.accentColor, in: Circle())
                                }
                                .keyboardShortcut(.return, modifiers: [.command])
                                .disabled(messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .offset(x: 12)
                            }
                        }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 8)

                Text("⌘⏎ で送信 • Shift+Enterで改行")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 900)
            }
            .background(.ultraThinMaterial)
        }
    }
}

private struct ModelRow: View {
    let modelName: String
    let isSelected: Bool
    let isDownloading: Bool
    let downloadProgress: Double?
    let onSelect: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(modelName)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                if isDownloading, let progress = downloadProgress {
                    ProgressView(value: progress).progressViewStyle(.linear)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !modelName.hasSuffix(".gguf") {
                Button("Download") { onDownload() }
                    .disabled(isDownloading)
                    .font(.caption)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { if modelName.hasSuffix(".gguf") { onSelect() } }
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Avatar
            ZStack {
                Circle().fill(message.isUser ? Color.accentColor : Color.secondary.opacity(0.2))
                Image(systemName: message.isUser ? "person.fill" : "sparkles")
                    .foregroundStyle(message.isUser ? .white : .primary)
            }
            .frame(width: 24, height: 24)

            // Bubble
            VStack(alignment: .leading, spacing: 6) {
                Text(message.isUser ? "You" : "Assistant")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Group {
                    if let attributed = try? AttributedString(markdown: message.content) {
                        Text(attributed)
                    } else {
                        Text(message.content)
                    }
                }
                .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(message.isUser ? Color.accentColor.opacity(0.12) : Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.06))
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title)
                    .lineLimit(1)
                Text(conversation.updatedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

#Preview { ContentView() }
