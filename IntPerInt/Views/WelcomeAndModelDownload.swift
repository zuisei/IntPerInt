import SwiftUI
import AppKit

struct WelcomeView: View {
    @ObservedObject var modelManager: ModelManager
    @Binding var hasSeenWelcome: Bool
    @State private var showDownloadSheet = false
    let onComplete: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.blue.opacity(0.12), Color.purple.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text("Welcome to IntPerInt")
                        .font(.system(size: 36, weight: .bold))
                    Text("ローカル LLM とクラウドを統合した、あなたの macOS アシスタント")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                HStack(spacing: 16) {
                    // Start Now card
                    VStack(alignment: .leading, spacing: 12) {
                        Text("今すぐ開始")
                            .font(.title2.bold())
                        Text("既にローカルモデルをお持ちの場合は、すぐにチャットを始められます。")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            hasSeenWelcome = true
                            onComplete()
                        } label: {
                            Label("今すぐ開始", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!modelManager.hasAnyLocalModel)
                        .help(modelManager.hasAnyLocalModel ? "開始" : "ローカルモデルが必要です")
                    }
                    .padding(20)
                    .frame(width: 420, height: 220)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .textBackgroundColor)))
                    .shadow(color: .black.opacity(0.1), radius: 12, y: 2)

                    // Get Models card
                    VStack(alignment: .leading, spacing: 12) {
                        Text("モデルを入手")
                            .font(.title2.bold())
                        Text("推奨 GGUF モデルをカタログからダウンロードするか、フォルダを開いて手動で配置できます。")
                            .foregroundStyle(.secondary)
                        Spacer()
                        HStack {
                            Button {
                                showDownloadSheet = true
                            } label: {
                                Label("モデルをダウンロード", systemImage: "arrow.down.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([modelManager.modelsDir])
                            } label: {
                                Label("フォルダを開く", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(20)
                    .frame(width: 420, height: 220)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .textBackgroundColor)))
                    .shadow(color: .black.opacity(0.1), radius: 12, y: 2)
                }
                .frame(maxWidth: 880)

                Spacer()
            }
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $showDownloadSheet) {
            ModelDownloadView(modelManager: modelManager) { fileName in
                modelManager.setCurrentModelForSelectedConversation(name: fileName)
                hasSeenWelcome = true
                onComplete()
            }
            .frame(minWidth: 800, minHeight: 520)
        }
        .onAppear { modelManager.loadAvailableModels() }
    }
}

struct ModelDownloadView: View {
    @ObservedObject var modelManager: ModelManager
    var onUseModel: (String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    @State private var pendingDelete: ModelInfo? = nil

    private var recommended: [ModelInfo] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ModelInfo.availableModels }
        return ModelInfo.availableModels.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.fileName.localizedCaseInsensitiveContains(query) || $0.huggingFaceRepo.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Text("モデルをダウンロード")
                    .font(.title2.bold())
                Spacer()
                TextField("検索", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .imageScale(.medium)
                }
                .buttonStyle(.bordered)
                .help("閉じる")
            }

            Table(recommended) {
                TableColumn("名称") { m in
                    VStack(alignment: .leading) {
                        Text(m.name)
                        Text(m.fileName).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                TableColumn("出所") { m in
                    Text(m.huggingFaceRepo).font(.caption)
                }
                TableColumn("操作") { m in
                    HStack(spacing: 8) {
                        let isDownloading = modelManager.downloadingModels.contains(m.name)
                        let progress = modelManager.downloadProgress[m.name] ?? 0
                        let isDownloaded = FileManager.default.fileExists(atPath: modelManager.modelsDir.appendingPathComponent(m.fileName).path)

                        if isDownloading {
                            ProgressView(value: progress)
                                .frame(width: 120)
                            Button("キャンセル") { modelManager.cancelDownload(m.name) }
                        } else if isDownloaded {
                            Button("このモデルを使う") { onUseModel(m.fileName) }
                            Button("フォルダ") { NSWorkspace.shared.activateFileViewerSelecting([modelManager.modelsDir.appendingPathComponent(m.fileName)]) }
                            Button(role: .destructive) {
                                pendingDelete = m
                                showDeleteConfirm = true
                            } label: { Text("削除") }
                        } else {
                            Button("ダウンロード") { modelManager.downloadModel(m.name) }
                        }
                    }
                }
            }

            // インストール済みモデル（カタログ外も含む）
            if !modelManager.installedModels.isEmpty {
                Divider().padding(.top, 8)
                Text("インストール済み")
                    .font(.headline)
                Table(modelManager.installedModels) {
                    TableColumn("名称") { im in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(im.name)
                            Text(im.fileName).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    TableColumn("操作") { im in
                        HStack(spacing: 8) {
                            Button("このモデルを使う") { onUseModel(im.fileName) }
                            Button("フォルダ") { NSWorkspace.shared.activateFileViewerSelecting([im.url]) }
                            Button(role: .destructive) { pendingDelete = ModelInfo(name: im.name, huggingFaceRepo: "", fileName: im.fileName); showDeleteConfirm = true } label: { Text("削除") }
                        }
                    }
                }
                .frame(minHeight: 160)
            }
        }
        .padding(20)
        .alert("モデルを削除しますか？", isPresented: $showDeleteConfirm, presenting: pendingDelete) { m in
            Button("削除", role: .destructive) {
                modelManager.deleteInstalledModel(m.fileName)
                pendingDelete = nil
            }
            Button("キャンセル", role: .cancel) { pendingDelete = nil }
        } message: { m in
            Text(m.fileName)
        }
        .onAppear { modelManager.loadAvailableModels() }
    }
}

private extension ModelInfo { var _dummy: String { "" } }
