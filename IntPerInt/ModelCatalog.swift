import Foundation

// Catalog definitions for various non-LLM models.

public enum ModelCategory: String, CaseIterable {
    case vqa
    case imageBase
    case imageRefiner
    case lora
}

public struct CatalogModel: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let category: ModelCategory

    public init(id: String, name: String, category: ModelCategory) {
        self.id = id
        self.name = name
        self.category = category
    }
}

public enum ModelCatalog {
    // Registered models grouped by category.
    public static let all: [CatalogModel] = [
        CatalogModel(id: "blip2", name: "BLIP-2", category: .vqa),
        CatalogModel(id: "llava", name: "LLaVA", category: .vqa),
        CatalogModel(id: "sdxl-base", name: "SDXL base", category: .imageBase),
        CatalogModel(id: "sdxl-refiner", name: "SDXL refiner", category: .imageRefiner),
        CatalogModel(id: "lora", name: "LoRA", category: .lora)
    ]

    public static var vqaModels: [CatalogModel] {
        all.filter { $0.category == .vqa }
    }

    public static var imageModels: [CatalogModel] {
        all.filter { $0.category == .imageBase || $0.category == .imageRefiner || $0.category == .lora }
    }
}

