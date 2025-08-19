import SwiftUI
import AppKit
import Foundation

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
            // Modal overlay (island style): background tap to dismiss, no dimming
            if showDownloadSheet {
                ZStack(alignment: .topTrailing) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showDownloadSheet = false }
                        .ignoresSafeArea()

                    ModelDownloadView(modelManager: modelManager) { fileName in
                        modelManager.setCurrentModelForSelectedConversation(name: fileName)
                        hasSeenWelcome = true
                        showDownloadSheet = false
                        onComplete()
                    } onClose: { showDownloadSheet = false }
                    .frame(width: 560, height: 560)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.white.opacity(0.08))
                    )
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
                    .padding(.top, 72)
                    .padding(.trailing, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(1000)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showDownloadSheet)
            }
        }
        .onAppear { modelManager.loadAvailableModels() }
    }
}

struct ModelDownloadView: View {
    @ObservedObject var modelManager: ModelManager
    var onUseModel: (String) -> Void
    var onClose: () -> Void
    var minimize: (() -> Void)? = nil
    @State private var query = ""
    @State private var showDeleteConfirm = false
    @State private var pendingDeleteFileName: String? = nil

    private var recommended: [ModelInfo] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ModelInfo.availableModels }
        return ModelInfo.availableModels.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.fileName.localizedCaseInsensitiveContains(query) || $0.huggingFaceRepo.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header toolbar（左群／検索／右アクション）
            HStack(alignment: .center, spacing: 12) {
                // 左側（タイトル＋合計）
                HStack(spacing: 10) {
                    Label("モデルをダウンロード", systemImage: "arrow.down.circle")
                        .font(.title2.bold())
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(10)
                    Divider().frame(height: 18)
                    Text("インストール済み 合計 \(formatGB(modelManager.installedTotalBytes)) GB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 検索（固定幅にして左右を安定）
                TextField("検索", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .lineLimit(1)
                    .layoutPriority(1)

                // 右アクション（固定サイズのカプセル）
                HStack(spacing: 4) {
                    CapsuleAction(icon: "folder", title: "フォルダ") {
                        NSWorkspace.shared.activateFileViewerSelecting([modelManager.modelsDir])
                    }
                    if let minimize { CapsuleAction(icon: "arrow.down.right.and.arrow.up.left", title: nil) { minimize() }.help("最小化") }
                    CapsuleAction(icon: "xmark", title: nil) { onClose() }
                        .help("閉じる")
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .fixedSize(horizontal: true, vertical: true)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.08))
                )
            }

            // Installed を先頭に固定表示 + Remote Catalog
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !modelManager.installedModels.isEmpty {
                        Text("インストール済み").font(.headline)
                            .padding(.horizontal, 6)
                        VStack(spacing: 6) {
                            ForEach(modelManager.installedModels) { im in
                                installedRow(im)
                            }
                        }
                        Divider().padding(.vertical, 4)
                    }
                    Text("カタログ").font(.headline)
                        .padding(.horizontal, 6)
                    VStack(spacing: 6) {
                        ForEach(recommended) { m in
                            catalogRow(m)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            // (Table section removed — now shown in compact list above)
        }
        .padding(20)
        // ドロップでローカル追加
        .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
            for item in providers {
                _ = item.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        try? modelManager.importLocalModel(from: url)
                    }
                }
            }
            return true
        }
        .alert("モデルを削除しますか？", isPresented: $showDeleteConfirm, presenting: pendingDeleteFileName) { file in
            Button("削除", role: .destructive) {
                modelManager.deleteInstalledModel(file)
                pendingDeleteFileName = nil
            }
            Button("キャンセル", role: .cancel) { pendingDeleteFileName = nil }
        } message: { file in
            Text(file)
        }
        .onAppear { modelManager.loadAvailableModels() }
    }

    // MARK: - Rows (compact, island style)
    @ViewBuilder
    private func catalogRow(_ m: ModelInfo) -> some View {
        let isDownloading = modelManager.downloadingModels.contains(m.name)
        let progress = modelManager.downloadProgress[m.name] ?? 0
        let speed = modelManager.downloadSpeed[m.name] ?? 0
        let expected = modelManager.downloadExpectedBytes[m.name] ?? 0
        let received = modelManager.downloadReceivedBytes[m.name] ?? 0
        let path = modelManager.modelsDir.appendingPathComponent(m.fileName).path
        let isDownloaded = FileManager.default.fileExists(atPath: path)

        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.name).font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    Text(m.fileName).font(.caption2).foregroundStyle(.secondary)
                    Text("· \(m.huggingFaceRepo)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 6) {
                if isDownloaded {
                    Text("インストール済み").font(.caption).foregroundStyle(.secondary)
                } else if isDownloading {
                    ProgressView(value: progress).progressViewStyle(.linear)
                    HStack(spacing: 8) {
                        Text(formatPercent(progress))
                        Text(formatMBps(speed))
                        if expected > 0 { Text("\(formatGB(received)) / \(formatGB(expected)) GB") }
                        if let eta = formatETA(expected: expected, received: received, speedMBps: speed) { Text("ETA \(eta)") }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                } else {
                    Text("未ダウンロード").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                if isDownloaded {
                    CapsuleAction(icon: "checkmark.circle", title: "使う") { onUseModel(m.fileName) }
                    CapsuleAction(icon: "folder", title: nil) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    CapsuleAction(icon: "trash", title: nil) {
                        pendingDeleteFileName = m.fileName
                        showDeleteConfirm = true
                    }
                } else if isDownloading {
                    CapsuleAction(icon: "xmark.circle", title: "キャンセル") { modelManager.cancelDownload(m.name) }
                } else {
                    CapsuleAction(icon: "arrow.down.circle", title: "ダウンロード") { modelManager.downloadModel(m.name) }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06))
        )
    }

    @ViewBuilder
    private func installedRow(_ im: InstalledModel) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(im.name).font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    Text(im.fileName).font(.caption2).foregroundStyle(.secondary)
                    if let size = fileSizeGB(im.url) { Text("· \(size) GB").font(.caption2).foregroundStyle(.tertiary) }
                    if let modified = (try? FileManager.default.attributesOfItem(atPath: im.url.path)[.modificationDate] as? Date) ?? nil {
                        Text("· 更新 \(modified, style: .date)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                CapsuleAction(icon: "checkmark.circle", title: "使う") { onUseModel(im.fileName) }
                CapsuleAction(icon: "folder", title: nil) { NSWorkspace.shared.activateFileViewerSelecting([im.url]) }
                CapsuleAction(icon: "trash", title: nil) {
                    pendingDeleteFileName = im.fileName
                    showDeleteConfirm = true
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06))
        )
    }
}

// MARK: - Helpers
private func formatGB(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0.00" }
    let gb = Double(bytes) / 1_000_000_000.0
    return String(format: "%.2f", gb)
}

// Display helpers
private func formatPercent(_ progress: Double) -> String {
    guard progress.isFinite && progress >= 0 else { return "-" }
    return String(format: "%d%%", Int(progress * 100))
}

private func formatMBps(_ mbps: Double) -> String {
    guard mbps.isFinite && mbps > 0 else { return "- MB/s" }
    return String(format: "%.2f MB/s", mbps)
}

private func formatETA(expected: Int64, received: Int64, speedMBps: Double) -> String? {
    guard expected > 0, received >= 0, speedMBps > 0 else { return nil }
    let remain = max(0, expected - received)
    if remain == 0 { return "0s" }
    let sec = Double(remain) / (speedMBps * 1_000_000.0)
    if sec.isNaN || !sec.isFinite { return nil }
    let s = Int(sec.rounded())
    let h = s / 3600
    let m = (s % 3600) / 60
    let ss = s % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, ss) }
    else { return String(format: "%d:%02d", m, ss) }
}

private func fileSizeGB(_ url: URL) -> String? {
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let num = attrs[.size] as? NSNumber {
        return formatGB(num.int64Value)
    }
    return nil
}

// MARK: - Capsule action button (lightweight "island" style)
private struct CapsuleAction: View {
    let icon: String
    var title: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).imageScale(.medium)
                if let title {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.9)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                Capsule().fill(Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
