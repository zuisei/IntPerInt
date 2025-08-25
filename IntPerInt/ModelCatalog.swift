import Foundation

/// Catalog of auxiliary modules used by video generation engines.
struct ModelCatalog {
    /// Representation of a downloadable module.
    struct Module: Identifiable, Hashable {
        let id: String
        let name: String
        let repoURL: String
        let fileName: String
    }

    /// Supported modules. These entries allow the app to detect when
    /// a module has been downloaded and route it to the proper engine.
    static let modules: [Module] = [
        Module(
            id: "animatediff",
            name: "AnimateDiff",
            repoURL: "https://github.com/guoyww/AnimateDiff",
            fileName: "animatediff.safetensors"
        ),
        Module(
            id: "rife",
            name: "RIFE",
            repoURL: "https://github.com/hzwer/Practical-RIFE",
            fileName: "rife.pth"
        )
    ]

    /// Lookup helper to find a module based on a downloaded file name.
    static func module(forFile fileName: String) -> Module? {
        return modules.first { $0.fileName == fileName }
    }
}
