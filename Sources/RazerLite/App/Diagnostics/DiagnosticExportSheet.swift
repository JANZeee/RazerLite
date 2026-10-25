import AppKit
import SwiftUI
import RazerLiteCore

@MainActor
private final class DiagnosticExportSheetState: ObservableObject {
    @Published var directoryPath = ""
    @Published var fileName = ""
    @Published var errorMessage: String?
    @Published var successURL: URL?

    init() {
        reset()
    }

    func reset(prefix: String = "diagnostics") {
        directoryPath = Self.defaultDirectory.path
        fileName = Self.defaultFileName(prefix: prefix)
        errorMessage = nil
        successURL = nil
    }

    private var absoluteDirectoryPath: String? {
        let expandedPath = (directoryPath as NSString).expandingTildeInPath
        return expandedPath.hasPrefix("/") ? expandedPath : nil
    }

    var directoryURL: URL {
        guard let absoluteDirectoryPath else { return Self.defaultDirectory }
        return URL(fileURLWithPath: absoluteDirectoryPath, isDirectory: true)
    }

    var displayedPath: String {
        guard let absoluteDirectoryPath else {
            return "请输入以 / 开头的完整文件夹路径"
        }
        return URL(fileURLWithPath: absoluteDirectoryPath, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false).path
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择文件夹"
        panel.message = "选择 JSON 文件的保存位置。"
        panel.directoryURL = directoryURL
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                self?.directoryPath = url.path
                self?.errorMessage = nil
            }
        }
    }

    func export(snapshotData: () throws -> Data) {
        errorMessage = nil
        successURL = nil
        do {
            let destination = try DiagnosticExportDestination(directoryPath: directoryPath, fileName: fileName)
            let url = try DiagnosticExportWriter().write(snapshotData(), to: destination)
            successURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static var defaultDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private static func defaultFileName(prefix: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "RazerLite-\(prefix)-\(formatter.string(from: Date())).json"
    }
}

/// An app-owned export flow that does not rely on NSSavePanel's filename
/// validation. The output path and filename remain visible until the user
/// explicitly presses Save.
struct JSONExportSheet: View {
    enum Kind { case diagnostics, profiles }
    let snapshotData: () throws -> Data
    var simulation = false
    var kind = Kind.diagnostics

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @StateObject private var state = DiagnosticExportSheetState()

    private var theme: RazerTheme { RazerTheme(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Label(kind == .profiles ? simulation ? "导出模拟预设" : "导出本地预设"
                      : simulation ? "导出模拟诊断" : "导出诊断", systemImage: "square.and.arrow.up")
                    .font(.system(size: 22, weight: .semibold))
                Text(simulation ? "模拟数据，仅用于界面与流程检查，不代表硬件验证。"
                     : kind == .profiles ? "导出全部本地预设，不包含设备会话或写入许可。" : "将当前设备状态与诊断信息保存为 JSON。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            if let successURL = state.successURL {
                success(successURL)
            } else {
                destinationForm
                if let errorMessage = state.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 12) {
                Spacer()
                Button(state.successURL == nil ? "取消" : "完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if state.successURL == nil {
                    Button("保存 JSON") { state.export(snapshotData: snapshotData) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(width: 620)
        .onAppear {
            let prefix = kind == .profiles ? "profiles" : "diagnostics"
            state.reset(prefix: simulation ? "simulation-\(prefix)" : prefix)
        }
    }

    private var destinationForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("保存位置").font(.system(size: 13, weight: .medium))
                    HStack(spacing: 10) {
                        TextField("文件夹路径", text: $state.directoryPath)
                            .textFieldStyle(.roundedBorder)
                        Button("选择文件夹…") { state.chooseDirectory() }
                    }
                }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("文件名").font(.system(size: 13, weight: .medium))
                    TextField("文件名必须以 .json 结尾", text: $state.fileName)
                        .textFieldStyle(.roundedBorder)
                    Text("同名文件不会被覆盖。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("将保存到").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Text(state.displayedPath)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            .padding(.horizontal, 4)
        }
    }

    private func success(_ url: URL) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 13) {
                Label("JSON 文件已保存", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(theme.accent)
                Text(url.path)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .controlSize(.small)
            }
        }
    }
}
