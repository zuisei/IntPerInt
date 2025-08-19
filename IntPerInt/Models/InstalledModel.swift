import Foundation

// インストール済みモデルの情報
struct InstalledModel: Identifiable, Hashable {
    let id = UUID()
    let name: String      // 表示名
    let fileName: String  // 実ファイル名
    let url: URL
}
