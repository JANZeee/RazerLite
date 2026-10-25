import AppKit
import SwiftUI
import RazerLiteCore

private enum LibrarySheet: Identifiable {
    case editor(MouseDPIProfile?), target(MouseDPIProfile), importing, exporting
    var id: String {
        switch self {
        case .editor: "editor"
        case .target: "target"
        case .importing: "import"
        case .exporting: "export"
        }
    }
}

@MainActor
private final class LocalLibraryState: ObservableObject {
    @Published var search = ""
    @Published var sheet: LibrarySheet?
    @Published var deleting: MouseDPIProfile?
    @Published var feedback: String?
}

struct LocalProfileLibraryView: View {
    @ObservedObject var profiles: ProfileService
    @ObservedObject var manager: DeviceManager
    @ObservedObject var workspace: AppWorkspace
    @StateObject private var state = LocalLibraryState()
    @Environment(\.colorScheme) private var scheme
    private var theme: RazerTheme { RazerTheme(scheme: scheme) }
    private var filtered: [MouseDPIProfile] {
        let query = state.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return profiles.profiles.filter {
            query.isEmpty || "\($0.name) \($0.target.displayName) \($0.x) \($0.y)".localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("本地档案").font(.system(size: 26, weight: .semibold))
                        Text("离线整理 DPI 预设。").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("导入…") { state.sheet = .importing }.disabled(!profiles.canModify)
                    Menu {
                        Button("导出全部预设…") { state.sheet = .exporting }.disabled(profiles.profiles.isEmpty)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize().help("档案操作").accessibilityLabel("档案操作")
                    Button { state.sheet = .editor(nil) } label: { Label("新建预设", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).disabled(!profiles.canModify)
                }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索名称、型号或 DPI", text: $state.search).textFieldStyle(.plain).accessibilityLabel("搜索本地预设")
                    if !state.search.isEmpty {
                        Button { state.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除档案搜索")
                    }
                }.padding(12).background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.line) }
                if !profiles.canModify {
                    Label(profiles.lastError ?? "本地档案无法修改，原文件已保留。", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                }
                if let feedback = state.feedback {
                    HStack(alignment: .top) {
                        Text(feedback).font(.system(size: 12)).textSelection(.enabled)
                        Spacer()
                        Button { state.feedback = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("关闭档案提示")
                    }.foregroundStyle(.secondary)
                }
                if filtered.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: profiles.profiles.isEmpty ? "rectangle.stack.badge.plus" : "magnifyingglass")
                            .font(.system(size: 32, weight: .light)).foregroundStyle(theme.accent)
                        Text(!profiles.canModify ? "档案未载入" : profiles.profiles.isEmpty ? "创建第一个预设" : "没有匹配的预设")
                            .font(.system(size: 20, weight: .semibold))
                        Text(!profiles.canModify ? "原文件已保留，可在设置中查看存储位置。"
                             : profiles.profiles.isEmpty ? "无需连接设备，即可保存目标 DPI。" : "试试其他名称或 DPI 数值。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 65)
                } else {
                    LazyVStack(spacing: 10) { ForEach(filtered) { row($0) } }
                }
                HStack {
                    Text(profiles.canModify ? "\(filtered.count) / \(profiles.profiles.count) 个预设" : "本地档案不可用")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("载入编辑器后，仍需确认应用。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(28).frame(maxWidth: 1060).frame(maxWidth: .infinity)
        }.background(theme.canvas)
        .sheet(item: $state.sheet) { sheet in
            switch sheet {
            case let .editor(profile):
                LocalProfileEditor(profile: profile) { name, x, y in
                    if let profile { _ = try profiles.update(profile, name: name, x: x, y: y) }
                    else { _ = try profiles.create(name: name, target: .viperV4ProDPI, x: x, y: y) }
                    state.sheet = nil
                }
            case let .target(profile):
                ProfileTargetPicker(profile: profile, manager: manager) { id in
                    guard let device = manager.devices.first(where: { $0.id == id && profile.target.matches($0) }), !manager.isSuspended else {
                        throw ProfileLibraryError.profileDoesNotMatchDevice
                    }
                    try profiles.select(profile, for: device)
                    state.sheet = nil
                    workspace.select(device, page: .controls)
                }
            case .importing:
                LocalProfileImportSheet(profiles: profiles) { result in
                    state.sheet = nil
                    state.feedback = "已导入 \(result.added) 个，跳过 \(result.skipped) 个重复项；\(result.conflicts) 个标识冲突已作为副本保留。"
                }
            case .exporting:
                JSONExportSheet(snapshotData: { try profiles.exportData(for: profiles.profiles) }, simulation: manager.isSimulation, kind: .profiles)
            }
        }
        .confirmationDialog("删除本地预设？", isPresented: Binding(get: { state.deleting != nil }, set: { if !$0 { state.deleting = nil } })) {
            if let profile = state.deleting {
                Button("删除「\(profile.name)」", role: .destructive) {
                    do { try profiles.delete(profile) } catch { state.feedback = error.localizedDescription }
                    state.deleting = nil
                }
            }
            Button("取消", role: .cancel) { state.deleting = nil }
        } message: { Text("仅删除本机预设，不改变设备设置。") }
    }

    private func row(_ profile: MouseDPIProfile) -> some View {
        SurfaceCard {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.stack").font(.system(size: 22, weight: .light)).foregroundStyle(theme.accent)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 7) {
                    Text(profile.name).font(.system(size: 14, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                    Text("X \(profile.x) / Y \(profile.y) DPI").font(.system(size: 12, design: .rounded))
                    Text(profile.target.displayName).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if profiles.selectedProfileIDs[profile.target.storageKey] == profile.id { SmallBadge(title: "本地已选") }
                Button("载入编辑器…") { state.sheet = .target(profile) }
                    .disabled(!profiles.canModify || manager.isSuspended || !manager.devices.contains { profile.target.matches($0) })
                    .help("需要匹配的已连接设备；载入不会发送设备命令")
                Menu {
                    Button("编辑…") { state.sheet = .editor(profile) }
                    Button("复制") {
                        do { _ = try profiles.duplicate(profile) } catch { state.feedback = error.localizedDescription }
                    }
                    Divider()
                    Button("删除…", role: .destructive) { state.deleting = profile }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(!profiles.canModify)
                    .accessibilityLabel("管理预设：\(profile.name)").help("管理预设：\(profile.name)")
            }
        }
    }
}

@MainActor
private final class ProfileEditorDraft: ObservableObject {
    @Published var name: String
    @Published var x: String
    @Published var y: String
    @Published var error: String?
    init(_ profile: MouseDPIProfile?) {
        name = profile?.name ?? ""
        x = String(profile?.x ?? 1600)
        y = String(profile?.y ?? 1600)
    }
    var values: (Int, Int)? {
        guard let x = Int(x), let y = Int(y),
              (try? MouseDPIProfile(name: name, target: .viperV4ProDPI, x: x, y: y)) != nil else { return nil }
        return (x, y)
    }
}

private struct LocalProfileEditor: View {
    let profile: MouseDPIProfile?
    let onSave: (String, Int, Int) throws -> Void
    @StateObject private var draft: ProfileEditorDraft
    @Environment(\.dismiss) private var dismiss
    init(profile: MouseDPIProfile?, onSave: @escaping (String, Int, Int) throws -> Void) {
        self.profile = profile
        self.onSave = onSave
        _draft = StateObject(wrappedValue: ProfileEditorDraft(profile))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(profile == nil ? "新建本地预设" : "编辑本地预设").font(.system(size: 23, weight: .semibold))
            Text(ProfileDeviceTarget.viperV4ProDPI.displayName).font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("名称").font(.caption)
                TextField("例如：办公 / 游戏", text: $draft.name).textFieldStyle(.roundedBorder).accessibilityLabel("预设名称")
            }
            HStack(spacing: 20) {
                dpiField("X 轴 DPI", text: $draft.x)
                dpiField("Y 轴 DPI", text: $draft.y)
            }
            Text("100–50,000 DPI · 步进 50 · 名称最多 48 字符")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("这是本地目标值，不会读取或修改设备。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let error = draft.error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存到本地") {
                    guard let (x, y) = draft.values else { return }
                    do { try onSave(draft.name, x, y) } catch { draft.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(draft.values == nil)
            }
        }.padding(28).frame(width: 460)
    }
    private func dpiField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption)
            TextField("目标 DPI", text: text).textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }
    }
}

@MainActor
private final class ProfileTargetState: ObservableObject {
    @Published var deviceID = ""
    @Published var error: String?
}

private struct ProfileTargetPicker: View {
    let profile: MouseDPIProfile
    @ObservedObject var manager: DeviceManager
    let onLoad: (String) throws -> Void
    @StateObject private var state = ProfileTargetState()
    @Environment(\.dismiss) private var dismiss
    private var devices: [DeviceInfo] { manager.devices.filter { profile.target.matches($0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("载入设备编辑器").font(.system(size: 23, weight: .semibold))
            Text("\(profile.name) · X \(profile.x) / Y \(profile.y) DPI").font(.system(size: 13))
            Picker("目标设备", selection: $state.deviceID) {
                Text("选择当前连接").tag("")
                ForEach(devices) { Text("\($0.presentation.name) · \($0.id)").tag($0.id) }
            }.help("会话 ID 用于区分当前接收器，不会写入档案")
            Text("仅填入编辑器；实际应用仍需检查变更并确认。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if devices.isEmpty { Text("匹配设备已断开，请重新连接后再选择。").font(.caption).foregroundStyle(.orange) }
            if let error = state.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("载入编辑器") {
                    do { try onLoad(state.deviceID) } catch { state.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
                    .disabled(manager.isSuspended || !devices.contains { $0.id == state.deviceID })
            }
        }.padding(28).frame(width: 500)
        .onAppear { if devices.count == 1 { state.deviceID = devices[0].id } }
        .onReceive(manager.$devices) { value in
            if !value.contains(where: { $0.id == state.deviceID && profile.target.matches($0) }) { state.deviceID = "" }
        }
    }
}

private struct LocalProfileImportSheet: View {
    @ObservedObject var profiles: ProfileService
    let onImport: (ProfileImportSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = ProfileImportDraft()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("导入本地预设").font(.system(size: 23, weight: .semibold))
            Text("选择 JSON 文件，或输入完整文件路径。上限 1 MiB。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                TextField("/完整路径/预设.json", text: $state.path).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("导入文件路径")
                Button("选择文件…") { state.chooseFile() }
            }
            Button("检查文件") {
                do {
                    let expanded = (state.path as NSString).expandingTildeInPath
                    guard expanded.hasPrefix("/"), (expanded as NSString).pathExtension.lowercased() == "json" else {
                        throw ProfileLibraryError.invalidImportFile
                    }
                    let url: URL
                    if let selected = state.selectedURL, selected.path == expanded { url = selected }
                    else { url = URL(fileURLWithPath: expanded) }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try ProfileService.readImportFile(url)
                    state.summary = try profiles.previewImport(data)
                    state.data = data
                    state.error = nil
                } catch {
                    state.data = nil
                    state.summary = nil
                    state.error = error.localizedDescription
                }
            }.disabled(state.path.isEmpty)
            if let summary = state.summary {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("新增 \(summary.added) 个 · 重复 \(summary.skipped) 个 · 标识冲突 \(summary.conflicts) 个")
                            .font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                        Text("重复内容会跳过；标识冲突的不同内容将作为新副本保留。不覆盖已有预设或切换本地选择。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let error = state.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("导入到本地") {
                    guard let data = state.data else { return }
                    do { onImport(try profiles.importData(data)) } catch { state.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(state.data == nil)
            }
        }.padding(28).frame(width: 540)
        .onChange(of: state.path) { _ in state.data = nil; state.summary = nil; state.error = nil }
    }
}

@MainActor
private final class ProfileImportDraft: ObservableObject {
    @Published var path = ""
    @Published var data: Data?
    @Published var summary: ProfileImportSummary?
    @Published var error: String?
    var selectedURL: URL?
    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择文件"
        panel.message = "选择本地预设 JSON；选中后仍会检查格式。"
        // Validate the selected bytes ourselves; do not depend on this OS's UTI filter.
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in self?.selectedURL = url; self?.path = url.path }
        }
    }
}
