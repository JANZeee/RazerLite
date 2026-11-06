import SwiftUI
import RazerLiteCore

@MainActor
private final class ProfileLibraryViewState: ObservableObject {
    @Published var draftName = ""
    @Published var pendingDelete: MouseDPIProfile?
    @Published var feedback: String?
}

/// A Synapse-style local preset page. Profile actions are intentionally only
/// local JSON operations; HID preparation and writing remain in DPIEditorView.
struct ProfileLibraryView: View {
    let device: DeviceInfo
    var telemetry: MouseTelemetry?
    @ObservedObject var profiles: ProfileService
    var onOpenLibrary: () -> Void = {}
    var canLoadIntoEditor = true
    let onLoadIntoEditor: () -> Void

    @Environment(\.colorScheme) private var scheme
    @StateObject private var state = ProfileLibraryViewState()

    private var theme: RazerTheme { RazerTheme(scheme: scheme) }
    private var availableProfiles: [MouseDPIProfile] { profiles.profiles(for: device) }
    private var selected: MouseDPIProfile? { profiles.selectedProfile(for: device) }
    private var currentDPI: MouseDPIStage? { telemetry?.dpi?.current }
    private var canSaveCurrent: Bool {
        guard let currentDPI else { return false }
        return ViperDPIInput(x: currentDPI.x, y: currentDPI.y).target != nil
    }
    private var currentDPIValidationMessage: String? {
        guard let currentDPI else { return nil }
        return ViperDPIInput(x: currentDPI.x, y: currentDPI.y).validationMessage()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("配置档案").font(.system(size: 24, weight: .semibold))
                    Text("保存与切换本地 DPI 预设。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                SmallBadge(title: "本地 · \(availableProfiles.count) 个", color: theme.accent, dot: true)
            }

            if !profiles.canModify {
                Label(profiles.lastError ?? "本地档案无法修改，原文件已保留。可在设置中查看存储位置。",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Label("保存当前 DPI", systemImage: "plus.circle")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        SmallBadge(title: currentDPI == nil ? "尚未读取" : "已读取", color: currentDPI == nil ? .secondary : theme.accent)
                    }
                    if let currentDPI {
                        Text("本次读取的当前第 \(telemetry?.dpi?.activeStage ?? 0) 档：X \(currentDPI.x) / Y \(currentDPI.y) DPI")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if let message = currentDPIValidationMessage {
                            Text("\(message) 可在本地档案中新建目标预设。")
                                .font(.system(size: 10)).foregroundStyle(.orange)
                        }
                    } else {
                        Text("先读取状态，再保存当前 DPI。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        TextField("例如：办公 / 竞技", text: $state.draftName)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                            .disabled(!profiles.canModify)
                            .accessibilityLabel("当前 DPI 预设名称")
                        Button("保存到本地") { saveCurrent() }
                            .disabled(!profiles.canModify || !canSaveCurrent || ProfileNameValidation.message(for: state.draftName) != nil)
                        Spacer(minLength: 0)
                    }
                    if profiles.canModify, let message = ProfileNameValidation.message(for: state.draftName) {
                        Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        Label("本地 DPI 预设", systemImage: "rectangle.stack")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button("管理全部预设", action: onOpenLibrary).controlSize(.small)
                    }
                    Text("载入预设只填入编辑器，确认后才会应用到设备。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if availableProfiles.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 25, weight: .light))
                                .foregroundStyle(.secondary)
                            Text(profiles.canModify ? "还没有本地预设" : "档案未载入").font(.system(size: 12, weight: .medium))
                            Text(profiles.canModify ? "可保存当前 DPI，也可在本地档案中新建。" : "原文件已保留，请先检查档案存储。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(availableProfiles) { profile in profileRow(profile) }
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(theme.accent)
                Text("适用于 Viper V4 Pro · USB。同型号设备共享本地预设选择。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 3)
        }
        .onAppear { seedDraftNameIfNeeded() }
        .onChange(of: telemetry?.dpi?.activeStage) { _ in seedDraftNameIfNeeded() }
        .confirmationDialog("删除本地预设？", isPresented: Binding(get: { state.pendingDelete != nil }, set: { if !$0 { state.pendingDelete = nil } })) {
            if let profile = state.pendingDelete {
                Button("删除「\(profile.name)」", role: .destructive) { delete(profile) }
                    .disabled(!profiles.canModify)
            }
            Button("取消", role: .cancel) { state.pendingDelete = nil }
        } message: {
            Text("仅删除本机预设，不改变设备设置。")
        }
        .alert("本地档案", isPresented: Binding(get: { state.feedback != nil || (profiles.canModify && profiles.lastError != nil) }, set: { value in
            if !value { state.feedback = nil; if profiles.canModify { profiles.clearError() } }
        })) {
            Button("好") { state.feedback = nil; if profiles.canModify { profiles.clearError() } }
        } message: { Text(state.feedback ?? profiles.lastError ?? "未知错误") }
    }

    private func profileRow(_ profile: MouseDPIProfile) -> some View {
        let isSelected = selected?.id == profile.id
        return HStack(spacing: 14) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? theme.accent : .secondary).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                Text("X \(profile.x) / Y \(profile.y) DPI · 本地预设")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected { SmallBadge(title: "本地已选", color: theme.accent) }
            Button("载入编辑器") { select(profile) }.controlSize(.small)
                .disabled(!profiles.canModify || !canLoadIntoEditor)
            Button(role: .destructive) { state.pendingDelete = profile } label: {
                Image(systemName: "trash").font(.system(size: 11))
            }.buttonStyle(.borderless).help("删除本地预设").disabled(!profiles.canModify)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(isSelected ? theme.accent.opacity(0.075) : theme.elevated.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? theme.accent.opacity(0.28) : theme.line) }
    }

    private func seedDraftNameIfNeeded() {
        guard state.draftName.isEmpty, let currentDPI else { return }
        state.draftName = "DPI \(currentDPI.x)"
    }

    private func saveCurrent() {
        guard let currentDPI else { return }
        do {
            let saved = try profiles.save(name: state.draftName, for: device, x: currentDPI.x, y: currentDPI.y)
            state.draftName = ""
            state.feedback = "已保存「\(saved.name)」，它已成为当前本地选择。"
        } catch { state.feedback = error.localizedDescription }
    }

    private func select(_ profile: MouseDPIProfile) {
        guard canLoadIntoEditor else { return }
        do {
            try profiles.select(profile, for: device)
            onLoadIntoEditor()
        } catch { state.feedback = error.localizedDescription }
    }

    private func delete(_ profile: MouseDPIProfile) {
        defer { state.pendingDelete = nil }
        do {
            try profiles.delete(profile)
            state.feedback = "已从本地移除「\(profile.name)」。"
        } catch { state.feedback = error.localizedDescription }
    }

}

struct ProfileUnavailableView: View {
    let device: DeviceInfo
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SurfaceCard {
            VStack(spacing: 14) {
                Image(systemName: "rectangle.stack.badge.xmark").font(.system(size: 34, weight: .light))
                    .foregroundStyle(RazerTheme(scheme: scheme).accent)
                Text("暂不支持此设备的档案").font(.system(size: 20, weight: .semibold))
                Text("目前仅支持 Viper V4 Pro 的本地 DPI 预设。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            }.padding(.vertical, 58).frame(maxWidth: .infinity)
        }
    }
}
