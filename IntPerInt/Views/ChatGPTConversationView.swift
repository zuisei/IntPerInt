import SwiftUI
import Foundation
import AppKit

// ChatEmptyState now lives in ChatEmptyState.swift (same module)

// Shared models & settings types live in other files; ensure module sees them
// (Xcode sometimes loses indexing after large deletes; no-op comment to trigger recompile)
// Access shared UI / models symbols

struct ChatGPTConversationView: View {
    @ObservedObject var modelManager: ModelManager
    @Binding var selectedProvider: AIProvider
    @EnvironmentObject var ui: UISettings
    
    // Local state for generation parameters
    @State private var messageInput = ""
    @State private var temperature: Double = 0.7
    @State private var topP: Double = 1.0
    @State private var maxTokens: Double = 1024
    @State private var seedText: String = ""
    @State private var stopWords: String = ""
    @State private var lastAutoScrollTime: Date = .distantPast

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: messageSpacing) {
                        if !modelManager.messages.isEmpty {
                            ForEach(modelManager.messages) { message in
                                MessageView(message: message)
                                    .id(message.id)
                            }
                            if modelManager.isGenerating {
                                HStack(alignment: .center, spacing: 8) {
                                    ProgressView().scaleEffect(0.7)
                                    Text("Generating...")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                            }
                        } else {
                            ChatEmptyState()
                        }
                    }
                    .padding()
                }
                .onChange(of: modelManager.messages.count) { _ in
                    // 新規メッセージ追加時のみ追従（アシスタント継続トークンは content 更新でcount変化しない）
                    throttledScroll(proxy: proxy)
                }
            }
            
            BottomInputBar(
                messageInput: $messageInput,
                onSend: sendMessage,
                showParams: true,
                temperature: $temperature,
                topP: $topP,
                maxTokens: $maxTokens,
                isGenerating: modelManager.isGenerating,
                onCancel: cancelGeneration
            )
        }
        .background(ChatTheme.background)
    }

    private func sendMessage() {
        guard !messageInput.isEmpty else { return }
        switch modelManager.selectedUseCase {
        case .chat:
            let params = GenerationParams(
                temperature: temperature,
                topP: topP,
                maxTokens: Int(maxTokens),
                seed: seedText.isEmpty ? nil : Int(seedText),
                stop: stopWords.split(separator: ",").map(String.init)
            )
            // モデル自動補完: 会話に未設定なら最初の validInstalledModels を設定
            var activeModel = currentConversationModel()
            if activeModel == nil || activeModel == "" {
                if let first = modelManager.validInstalledModels.first?.fileName {
                    modelManager.setCurrentModelForSelectedConversation(name: first)
                    activeModel = first
                }
            }
            let active = activeModel ?? ""
            modelManager.sendMessage(messageInput, using: active, provider: selectedProvider, params: params)
        case .imageUnderstanding:
            let model = modelManager.selectedVQAModel
            Task { _ = await modelManager.runVQA(question: messageInput, image: NSImage(), modelName: model) }
        case .imageGeneration:
            let model = modelManager.selectedImageModel
            Task { _ = await modelManager.generateImage(prompt: messageInput, modelName: model) }
        }
        messageInput = ""
    }

    private func cancelGeneration() { modelManager.cancelGeneration() }

    private func currentConversationModel() -> String? {
        guard let id = modelManager.selectedConversationID,
              let conv = modelManager.conversations.first(where: { $0.id == id }) else { return nil }
        return conv.model
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let lastMessageId = modelManager.messages.last?.id else { return }
        withAnimation {
            proxy.scrollTo(lastMessageId, anchor: .bottom)
        }
    }

    private func throttledScroll(proxy: ScrollViewProxy) {
        let now = Date()
        if now.timeIntervalSince(lastAutoScrollTime) > 0.25 {
            lastAutoScrollTime = now
            scrollToBottom(proxy: proxy)
        }
    }
}

// MARK: - Spacing helper
private extension ChatGPTConversationView {
    var messageSpacing: CGFloat {
        switch ui.density {
        case .compact: return 4
        case .comfortable: return 8
        case .spacious: return 14
        }
    }
}

struct MessageView: View {
    let message: ChatMessage
    @EnvironmentObject var ui: UISettings

    var body: some View {
        HStack {
            if message.isUser { Spacer() }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isUser ? ChatTheme.userMessageBackground : ChatTheme.assistantMessageBackground)
                    .cornerRadius(12)
                    .textSelection(.enabled)
                    .animation(nil, value: message.content) // 頻繁な再レイアウトのアニメを抑制
                
                if ui.showTimestamps {
                    Text(message.timestamp, style: .time)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: ui.preferredMaxContentWidth, alignment: message.isUser ? .trailing : .leading)
            
            if !message.isUser { Spacer() }
        }
    }
}

struct BottomInputBar: View {
    @Binding var messageInput: String
    var onSend: () -> Void
    var showParams: Bool
    @Binding var temperature: Double
    @Binding var topP: Double
    @Binding var maxTokens: Double
    var isGenerating: Bool
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if showParams {
                HStack {
                    VStack {
                        Text("Temp: \(String(format: "%.2f", temperature))")
                        Slider(value: $temperature, in: 0.0...2.0)
                    }
                    VStack {
                        Text("Top-P: \(String(format: "%.2f", topP))")
                        Slider(value: $topP, in: 0.0...1.0)
                    }
                    VStack {
                        Text("Max Tokens: \(Int(maxTokens))")
                        Slider(value: $maxTokens, in: 64...4096)
                    }
                }
                .padding()
                .background(ChatTheme.sidebar.opacity(0.5))
            }
            
            HStack {
                TextField("Enter message...", text: $messageInput, onCommit: onSend)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(ChatTheme.inputBackground)
                    .cornerRadius(16)
                if isGenerating {
                    Button(action: onCancel) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(.red)
                            .help("Cancel Generation")
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .disabled(messageInput.isEmpty)
                    .help("Send Message")
                }
            }
            .padding()
        }
        .background(ChatTheme.sidebar)
    }
}


