import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var modelManager = ModelManager()
    @State private var selectedProvider: AIProvider = .llamaCpp
    @State private var messageInput = ""
    @State private var selectedModel: String? = nil
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            VStack(alignment: .leading, spacing: 16) {
                Text("AI Models")
                    .font(.headline)
                    .padding(.horizontal)
                
                // Provider Selection
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)
                
                // Model Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Available Models")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(modelManager.availableModels, id: \.self) { model in
                                ModelRow(
                                    modelName: model,
                                    isSelected: selectedModel == model,
                                    isDownloading: modelManager.downloadingModels.contains(model),
                                    downloadProgress: modelManager.downloadProgress[model]
                                ) {
                                    selectedModel = model
                                } onDownload: {
                                    modelManager.downloadModel(model)
                                }
                            }
                        }
                    }
                }
                
                Spacer()
                
                // Status
                if modelManager.isLoading {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading...")
                            .font(.caption)
                    }
                    .padding(.horizontal)
                }
            }
            .frame(minWidth: 250)
        } detail: {
            // Chat Interface
            VStack(spacing: 0) {
                // Messages
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(modelManager.messages) { message in
                            MessageBubble(message: message)
                        }
                    }
                    .padding()
                }
                
                Divider()
                
                // Input
                HStack {
                    TextField("Type your message...", text: $messageInput, axis: .vertical)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .lineLimit(1...5)
                    
                    Button("Send") {
                        sendMessage()
                    }
                    .disabled(messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedModel == nil)
                }
                .padding()
            }
        }
        .onAppear {
            modelManager.loadAvailableModels()
        }
    }
    
    private func sendMessage() {
        guard !messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let model = selectedModel else { return }
        
        let message = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        messageInput = ""
        
        modelManager.sendMessage(message, using: model, provider: selectedProvider)
    }
}

struct ModelRow: View {
    let modelName: String
    let isSelected: Bool
    let isDownloading: Bool
    let downloadProgress: Double?
    let onSelect: () -> Void
    let onDownload: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(modelName)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                
                if isDownloading, let progress = downloadProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(LinearProgressViewStyle())
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if !modelName.hasSuffix(".gguf") {
                Button("Download") {
                    onDownload()
                }
                .disabled(isDownloading)
                .font(.caption)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .onTapGesture {
            if modelName.hasSuffix(".gguf") {
                onSelect()
            }
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.isUser {
                Spacer()
            }
            
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(message.isUser ? Color.accentColor : Color.secondary.opacity(0.2))
                    )
                    .foregroundColor(message.isUser ? .white : .primary)
                
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            if !message.isUser {
                Spacer()
            }
        }
    }
}

#Preview {
    ContentView()
}
