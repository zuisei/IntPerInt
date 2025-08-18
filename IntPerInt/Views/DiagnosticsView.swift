import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    @State private var modelInput: String = ""
    @State private var output: String = ""
    @State private var isRunning: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("診断 / ログ収集").font(.headline)
            Text("llama.cpp のバージョン確認や簡易テストを実行し、結果をログとして保存できます。")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("モデルのローカルパスまたはURL (.gguf)", text: $modelInput)
                    .textFieldStyle(.roundedBorder)
                Button("バージョン確認") { runVersionCheck() }
                    .disabled(isRunning)
                Button("モデルテスト") { runModelTest() }
                    .disabled(isRunning)
            }

            TextEditor(text: $output)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08)))

            HStack {
                Spacer()
                Button("ログを保存…") { saveLog() }
                    .disabled(output.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 620)
    }

    private func runVersionCheck() {
        Task {
            if let cli = optionalCLIPath() {
                await run(commands: [[cli, ["--version"]]])
            } else {
                append("[ERR] llama.cpp CLI が見つかりません。設定で LLAMACPP_CLI を指定してください\n")
            }
        }
    }

    private func runModelTest() {
        Task {
            guard let cli = optionalCLIPath() else { append("[ERR] llama.cpp CLI が見つかりません。設定で LLAMACPP_CLI を指定してください\n"); return }
            let modelArg = modelInput.trimmingCharacters(in: .whitespacesAndNewlines)
            var localPath = modelArg
            if modelArg.hasPrefix("file://"), let url = URL(string: modelArg) { localPath = url.path }
            let args = ["-m", localPath, "-p", "test", "-n", "1"]
            await run(commands: [[cli, args]])
        }
    }

    private func run(commands: [[Any]]) async {
        await MainActor.run { isRunning = true; output = "" }
        defer { Task { await MainActor.run { isRunning = false } } }
        for entry in commands {
            guard entry.count == 2 else { continue }
            let bin = entry[0] as! String
            let args = entry[1] as! [String]
            append("$ \(bin) \(args.joined(separator: " "))\n")
            let (code, out, err) = runProcess(bin: bin, args: args)
            append(out)
            if !err.isEmpty { append(err) }
            append("[exit] \(code)\n\n")
        }
    }

    private func runProcess(bin: String, args: [String]) -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        if env["GGML_METAL_PATH_RESOURCES"] == nil {
            env["GGML_METAL_PATH_RESOURCES"] = DiagnosticsView.resolveMetalResourcesPath(defaultExecDir: URL(fileURLWithPath: bin).deletingLastPathComponent())
        }
        p.environment = env
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch {
            return (127, "", "[ERR] 実行できません: \(error.localizedDescription)\n")
        }
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out, err)
    }

    private func saveLog() {
        let panel = NSSavePanel()
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [.plainText]
        } else {
            panel.allowedFileTypes = ["txt", "log"]
        }
        panel.nameFieldStringValue = "intperint_diagnostics.log"
        if panel.runModal() == .OK, let url = panel.url {
            try? output.data(using: .utf8)?.write(to: url)
        }
    }

    private func append(_ s: String) {
        DispatchQueue.main.async { self.output += s }
    }

    // resCLIPath は未使用（CLI未設定時に /usr/bin/env を誤実行しないため）
    private func optionalCLIPath() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let pref = UserDefaults.standard.string(forKey: "LLAMACPP_CLI"), !pref.isEmpty {
            candidates.append(pref)
        }
        if let env = ProcessInfo.processInfo.environment["LLAMACPP_CLI"], !env.isEmpty {
            candidates.append(env)
        }
        // 統一された候補群（Cellar/bin, Cellar/libexec, App Support/bin などを含む）
        candidates += LlamaCLIResolver.candidates()
        for p in candidates { if fm.isExecutableFile(atPath: p) { return p } }
        return nil
    }

    private static func resolveMetalResourcesPath(defaultExecDir: URL) -> String {
        let candidates: [URL] = [
            defaultExecDir,
            URL(fileURLWithPath: "/tmp/llama.cpp/build/bin"),
            URL(fileURLWithPath: "/tmp/llama.cpp"),
            URL(fileURLWithPath: "/opt/homebrew/opt/llama.cpp/share/llama.cpp"),
            URL(fileURLWithPath: "/usr/local/opt/llama.cpp/share/llama.cpp")
        ]
        for dir in candidates {
            let file = dir.appendingPathComponent("default.metallib")
            if FileManager.default.fileExists(atPath: file.path) { return dir.path }
        }
        return defaultExecDir.path
    }
}
