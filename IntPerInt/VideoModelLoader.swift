import Foundation

/// Helper responsible for loading any downloaded video modules into their engines.
actor VideoModelLoader {
    private let modelsDirectory: URL

    init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    /// Iterate over known catalog modules and load those whose files exist
    /// in the models directory.
    func loadAll() async {
        for module in ModelCatalog.modules {
            let url = modelsDirectory.appendingPathComponent(module.fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                await VideoEngineRegistry.shared.load(module: module, from: url)
            }
        }
    }
}
