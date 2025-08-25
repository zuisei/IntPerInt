import Foundation

/// Base protocol for video generation engines.
protocol VideoEngine {
    /// Unique identifier used to match catalog modules.
    var id: String { get }
    /// Load a model located at the given URL.
    func loadModel(at url: URL) async throws
}

/// Engine implementation for AnimateDiff.
final class AnimateDiffEngine: VideoEngine {
    static let shared = AnimateDiffEngine()
    let id = "animatediff"
    private init() {}

    func loadModel(at url: URL) async throws {
        // Placeholder: actual model loading logic for AnimateDiff would go here.
        // For now we simply print to indicate a load attempt.
        print("[AnimateDiffEngine] Loading module at \(url.path)")
    }
}

/// Engine implementation for RIFE frame interpolation.
final class RIFEEngine: VideoEngine {
    static let shared = RIFEEngine()
    let id = "rife"
    private init() {}

    func loadModel(at url: URL) async throws {
        // Placeholder for RIFE model loading.
        print("[RIFEEngine] Loading module at \(url.path)")
    }
}

/// Registry that manages available video engines and dispatches models to them.
actor VideoEngineRegistry {
    static let shared = VideoEngineRegistry()
    private var engines: [String: VideoEngine]

    init() {
        engines = [
            AnimateDiffEngine.shared.id: AnimateDiffEngine.shared,
            RIFEEngine.shared.id: RIFEEngine.shared
        ]
    }

    /// Load the given catalog module into its associated engine.
    func load(module: ModelCatalog.Module, from url: URL) async {
        guard let engine = engines[module.id] else { return }
        do {
            try await engine.loadModel(at: url)
        } catch {
            print("Failed to load module \(module.name): \(error)")
        }
    }
}
