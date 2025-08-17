import Foundation
import Combine

@MainActor
class ModelManager: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var availableModels: [String] = []
    @Published var downloadingModels: Set<String> = []
    @Published var downloadProgress: [String: Double] = [:]
    @Published var isLoading: Bool = false
    
    private let modelsDirectory: URL
    // TODO: Re-enable when LLaMA.cpp is properly linked
    // private let llamaCppWrapper = LLamaCppWrapper()
    
    init() {
        // Create models directory in user's Documents folder
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        modelsDirectory = documentsPath.appendingPathComponent("IntPerInt/Models")
        
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }
    
    func loadAvailableModels() {
        var models: [String] = []
        
        // Add downloadable models
        models.append(contentsOf: ModelInfo.availableModels.map { $0.name })
        
        // Add already downloaded models
        if let contents = try? FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil) {
            let ggufFiles = contents.filter { $0.pathExtension == "gguf" }
                .map { $0.lastPathComponent }
            models.append(contentsOf: ggufFiles)
        }
        
        availableModels = Array(Set(models)).sorted()
    }
    
    func downloadModel(_ modelName: String) {
        guard let modelInfo = ModelInfo.availableModels.first(where: { $0.name == modelName }),
              !downloadingModels.contains(modelName) else { return }
        
        downloadingModels.insert(modelName)
        downloadProgress[modelName] = 0.0
        
        Task {
            await downloadModelFile(modelInfo)
        }
    }
    
    private func downloadModelFile(_ modelInfo: ModelInfo) async {
        let url = URL(string: "https://huggingface.co/\(modelInfo.huggingFaceRepo)/resolve/main/\(modelInfo.fileName)")!
        let destination = modelsDirectory.appendingPathComponent(modelInfo.fileName)
        
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            
            // Check if file already exists
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            
            try FileManager.default.moveItem(at: tempURL, to: destination)
            
            await MainActor.run {
                downloadingModels.remove(modelInfo.name)
                downloadProgress.removeValue(forKey: modelInfo.name)
                loadAvailableModels()
            }
        } catch {
            print("Download failed: \(error)")
            await MainActor.run {
                downloadingModels.remove(modelInfo.name)
                downloadProgress.removeValue(forKey: modelInfo.name)
            }
        }
    }
    
    func sendMessage(_ content: String, using modelName: String, provider: AIProvider) {
        let userMessage = ChatMessage(content: content, isUser: true)
        messages.append(userMessage)
        
        Task {
            do {
                let response = try await generateResponse(for: content, using: modelName, provider: provider)
                let aiMessage = ChatMessage(content: response, isUser: false)
                
                await MainActor.run {
                    messages.append(aiMessage)
                }
            } catch {
                let errorMessage = ChatMessage(content: "Error: \(error.localizedDescription)", isUser: false)
                await MainActor.run {
                    messages.append(errorMessage)
                }
            }
        }
    }
    
    private func generateResponse(for prompt: String, using modelName: String, provider: AIProvider) async throws -> String {
        switch provider {
        case .llamaCpp:
            return try await generateLlamaCppResponse(prompt: prompt, modelName: modelName)
        }
    }
    
    private func generateLlamaCppResponse(prompt: String, modelName: String) async throws -> String {
        // TODO: Implement actual LLaMA.cpp integration
        // For now, return a mock response to test the UI
        
        // Simulate processing time
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        
        return "Mock response to: \(prompt)\n\nThis is a placeholder response. The actual LLaMA.cpp integration will be implemented once the library is properly linked to the project."
    }
}
