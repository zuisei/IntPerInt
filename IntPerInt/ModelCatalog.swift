import Foundation

struct ModelCatalogEntry: Codable {
    let fileName: String
    let modelType: String
    let quantization: String
}

enum ModelCatalog {
    static func load() -> [String: ModelCatalogEntry] {
        guard let url = Bundle.main.url(forResource: "model_catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([ModelCatalogEntry].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.fileName, $0) })
    }
}
