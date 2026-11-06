import SwiftUI
import RazerLiteCore

@MainActor
final class DPIEditorState: ObservableObject {
    @Published var input = ViperDPIInput()
    var loadedProfileID: UUID?
}

struct DPIEditorView: View {
    let device: DeviceInfo
    @ObservedObject var manager: DeviceManager
    let selectedProfile: MouseDPIProfile?
    @StateObject private var editor = DPIEditorState()
    @Environment(\.colorScheme) private var scheme
    private var busy: Bool { manager.isSuspended || manager.isDeviceBusy(device.id) }
    private var current: MouseDPIStage? { manager.mouseReadouts[device.id]?.dpi?.current }
    private var unchanged: Bool { current.map { editor.input.matches($0) } ?? false }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("DPI 设置", systemImage: "slider.horizontal.3").font(.system(size: 13, weight: .medium))
                    Spacer()
                    SmallBadge(title: manager.dpiWriteResults[device.id]?.outcome == .verified
                               ? manager.isSimulation ? "模拟读回" : "读回已验证" : "需确认")
                }
                if let selectedProfile {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.stack.fill").font(.system(size: 11)).foregroundStyle(RazerTheme(scheme: scheme).accent)
                        Text("本地档案「\(selectedProfile.name)」· \(matchesProfile(selectedProfile) ? "编辑器目标一致" : "目标已修改") · X \(selectedProfile.x) / Y \(selectedProfile.y) DPI")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("重新载入") { load(selectedProfile) }.font(.system(size: 10)).disabled(busy)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RazerTheme(scheme: scheme).accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("修改当前档位，或展开下方编辑全部档位。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Toggle("联动 X/Y", isOn: Binding(get: { editor.input.axesLinked }, set: { editor.input.setLinked($0) }))
                        .toggleStyle(.checkbox).font(.system(size: 11))
                        .help("开启时将 Y 设为 X，之后编辑任一轴同步两轴；仅修改草稿。")
                    Spacer()
                    Button("载入当前值") {
                        guard let current else { return }
                        editor.input = ViperDPIInput(x: current.x, y: current.y)
                    }.disabled(current == nil).font(.system(size: 11))
                        .help("载入已读取的当前档位，不发送设备查询；替换当前输入。")
                }.disabled(busy)
                HStack(spacing: 18) {
                    axisField("X 轴 DPI", text: Binding(get: { editor.input.x }, set: { editor.input.editX($0) }))
                    axisField("Y 轴 DPI", text: Binding(get: { editor.input.y }, set: { editor.input.editY($0) }))
                    Spacer(minLength: 0)
                    Button(busy ? "正在处理…" : "检查变更…") {
                        guard let target = editor.input.target else { return }
                        Task { await manager.prepareDPIChange(for: device.id, x: target.x, y: target.y) }
                    }.disabled(busy || unchanged || editor.input.target == nil).controlSize(.large)
                }.disabled(busy)
                if let message = editor.input.validationMessage(preserving: current) {
                    Text(message).font(.system(size: 11)).foregroundStyle(.orange)
                } else if unchanged {
                    Text("与已读取的当前值相同。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("100–50,000 DPI · 步进 50")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .help("设备原值可能不符合输入步进，不会自动取整")
                Label("会提交全部档位，可能保存到设备。", systemImage: "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                DPIStagesEditorView(device: device, manager: manager, busy: busy)
                if let error = manager.dpiErrors[device.id] {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if let result = manager.dpiWriteResults[device.id] {
                    Label(result.message, systemImage: result.outcome == .verified ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(result.outcome == .verified ? RazerTheme(scheme: scheme).accent : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(item: Binding(get: { manager.pendingDPIChanges[device.id] }, set: { value in
            if value == nil { manager.cancelDPIChange(for: device.id) }
        })) { plan in
            DPIConfirmationView(plan: plan, isSimulation: manager.isSimulation, onCancel: { manager.cancelDPIChange(for: device.id) }, onConfirm: {
                Task { await manager.confirmDPIChange(for: device.id, planID: plan.id) }
            })
        }
        .onAppear { synchronizeSelectedProfile() }
        .onChange(of: selectedProfile?.id) { _ in synchronizeSelectedProfile() }
        .onDisappear { manager.cancelDPIChange(for: device.id) }
    }

    private func axisField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            TextField("输入目标 DPI", text: text).textFieldStyle(.roundedBorder)
                .accessibilityLabel(title).frame(width: 135)
        }
    }

    private func synchronizeSelectedProfile() {
        guard let selectedProfile, editor.loadedProfileID != selectedProfile.id else { return }
        load(selectedProfile)
    }

    private func matchesProfile(_ profile: MouseDPIProfile) -> Bool {
        editor.loadedProfileID == profile.id && Int(editor.input.x) == profile.x && Int(editor.input.y) == profile.y
    }

    private func load(_ profile: MouseDPIProfile) {
        editor.input = ViperDPIInput(x: profile.x, y: profile.y)
        editor.loadedProfileID = profile.id
    }
}

struct DPIConfirmationView: View {
    let plan: MouseDPIPlan
    var isSimulation = false
    let onCancel: () -> Void
    let onConfirm: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            Label(isSimulation ? "模拟 DPI 变更" : "确认修改 DPI", systemImage: "slider.horizontal.3").font(.system(size: 23, weight: .semibold))
            if isSimulation {
                Text("模拟数据 · 仅调用假服务，没有真实设备通信。")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
            }
            Text(plan.deviceName).font(.system(size: 12)).foregroundStyle(.secondary)
            Text("修改第 \(plan.changedStages.map(String.init).joined(separator: "、")) 档的 X/Y 数值，保持当前档位不变。底层命令会提交全部 \(plan.before.stages.count) 档；可能保存到设备，不能保证临时生效。")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 12) {
                HStack {
                    Text("档位").frame(width: 64, alignment: .leading)
                    Text("当前 X / Y").frame(maxWidth: .infinity, alignment: .leading)
                    Text("目标 X / Y").frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                Divider()
                ForEach(plan.before.stages.indices, id: \.self) { index in
                    HStack {
                        Text("第 \(index + 1) 档").frame(width: 64, alignment: .leading)
                        Text("\(plan.before.stages[index].x) / \(plan.before.stages[index].y)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(plan.after.stages[index].x) / \(plan.after.stages[index].y)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.system(size: 12, weight: plan.changedStages.contains(index + 1) ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(plan.changedStages.contains(index + 1) ? Color.primary : Color.secondary)
                }
            }.padding(17).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            Text("计划有效期 60 秒。写入前会再次读取；设备、当前档位或表内数值有变化即中止。失败后不自动重试或回滚。这是实验性设备写入；保存与跨重启行为尚待验证。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(isSimulation ? "确认模拟应用" : "确认写入设备", action: onConfirm).buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 540)
    }
}
