import SwiftUI
import RazerLiteCore

@MainActor
private final class KeyboardLightingDraft: ObservableObject {
    @Published var deviceID: String?
    @Published var percent: Double?
    @Published var isEdited = false
}

struct KeyboardLightingPanel: View {
    let device: DeviceInfo
    @ObservedObject var manager: DeviceManager
    @Environment(\.colorScheme) private var scheme
    @StateObject private var draft = KeyboardLightingDraft()

    private var theme: RazerTheme { RazerTheme(scheme: scheme) }
    private var reading: KeyboardBrightnessReading? { manager.keyboardBrightnessReadouts[device.id] }
    private var currentPercent: Int? { reading?.hasValue == true ? reading?.percent : nil }
    private var busy: Bool { manager.isSuspended || manager.isDeviceBusy(device.id) }
    private var isReading: Bool { manager.readingKeyboardBrightnessIDs.contains(device.id) }
    private var isWriting: Bool { manager.brightnessWriteBusyIDs.contains(device.id) }
    private var canPrepare: Bool {
        guard !busy, draft.isEdited, let draftPercent = draft.percent, let currentPercent else { return false }
        return Int(draftPercent) != currentPercent
    }
    private var brightnessDetail: String {
        "读取的是设备配置通道 1 的亮度，不是对键盘实际发光的测量。切换板载配置或设备模式后，可见灯光可能不同；读取时间不代表持续在线。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("灯光").font(.system(size: 24, weight: .semibold)).tracking(-0.5)
            SurfaceCard {
                VStack(alignment: .leading, spacing: 22) {
                    readout
                    if draft.percent != nil {
                        Divider()
                        editor
                    }
                    feedback
                }
            }
        }
        .sheet(item: Binding(get: { manager.pendingBrightnessChanges[device.id] }, set: { plan in
            if plan == nil { manager.cancelBrightnessChange(for: device.id) }
        })) { plan in
            confirmation(plan)
        }
        .onAppear { synchronizeDevice() }
        .onChange(of: device.id) { _ in synchronizeDevice() }
        .onChange(of: reading) { _ in seedDraftIfUnedited() }
        .onChange(of: manager.brightnessWriteResults[device.id]?.completedAt) { _ in
            guard let result = manager.brightnessWriteResults[device.id], result.outcome == .verified,
                  let readback = result.readback, readback.hasValue, let percent = readback.percent else { return }
            draft.percent = Double(percent)
            draft.isEdited = false
        }
        .onDisappear {
            if let editingDeviceID = draft.deviceID { manager.cancelBrightnessChange(for: editingDeviceID) }
        }
    }

    private var readout: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: "sun.max")
                .font(.system(size: 28, weight: .light)).foregroundStyle(theme.accent)
                .frame(width: 58, height: 58)
                .background(theme.selected, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("亮度配置").font(.system(size: 12, weight: .medium))
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                        .help(brightnessDetail).accessibilityLabel(brightnessDetail)
                }
                Text(currentPercent.map { "\($0)%" } ?? "未读取")
                    .font(.system(size: currentPercent == nil ? 24 : 36, weight: .light, design: .rounded))
                    .monospacedDigit()
                if let reading {
                    Text("\(reading.hasValue ? "读取于" : "尝试于") \(reading.readAt.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await manager.readKeyboardBrightness(for: device.id) }
            } label: {
                Label(isReading ? "正在读取…" : "读取亮度", systemImage: "arrow.down.circle")
            }
            .disabled(busy)
            .help("按需读取亮度配置，不修改设备")
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("目标亮度").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(draft.percent ?? 0))%")
                    .font(.system(size: 14, weight: .medium, design: .rounded)).monospacedDigit()
            }
            HStack(spacing: 12) {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                Slider(value: Binding(get: { draft.percent ?? 0 }, set: { value in
                    draft.percent = value.rounded()
                    draft.isEdited = true
                }), in: 0...100)
                    .tint(theme.accent).disabled(busy)
                    .accessibilityLabel("目标亮度，确认后应用")
                    .accessibilityValue("\(Int(draft.percent ?? 0))%")
                Image(systemName: "sun.max").foregroundStyle(.secondary)
            }.font(.system(size: 13))
            HStack {
                Button("关闭灯光") {
                    draft.percent = 0
                    draft.isEdited = true
                }
                .disabled(busy || draft.percent == 0)
                .help("将目标设为 0%，检查并确认后应用")
                .accessibilityHint("仅修改目标亮度，确认后才写入设备")
                Text("确认后应用").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button(isWriting ? "正在处理…" : "检查变更…") {
                    guard let draftPercent = draft.percent else { return }
                    Task { await manager.prepareBrightnessChange(for: device.id, percent: Int(draftPercent)) }
                }
                .disabled(!canPrepare)
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
            }
        }
    }

    @ViewBuilder private var feedback: some View {
        if let issue = reading?.issue {
            Label(issue.message, systemImage: "exclamationmark.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = manager.brightnessWriteErrors[device.id] {
            Text(error).font(.system(size: 11)).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let result = manager.brightnessWriteResults[device.id] {
            Label(result.message, systemImage: result.outcome == .verified ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(result.outcome == .verified ? Color.secondary : .orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func confirmation(_ plan: KeyboardBrightnessPlan) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(manager.isSimulation ? "模拟亮度变更" : "确认修改亮度", systemImage: "sun.max")
                .font(.system(size: 22, weight: .semibold))
            if manager.isSimulation {
                Text("模拟数据 · 没有真实设备通信。").font(.system(size: 12)).foregroundStyle(.orange)
            }
            Text(plan.deviceName).font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Text(plan.before.percent.map { "\($0)%" } ?? "未读取")
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Text("\(plan.afterPercent)%").bold()
            }.font(.system(size: 30, weight: .light, design: .rounded)).monospacedDigit()
            Text("将修改设备亮度，可能保存到设备。确认后写入一次并读回配置；实际灯光变化需查看键盘。")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text("60 秒内有效；配置变化即中止，失败不自动重试。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("取消") { manager.cancelBrightnessChange(for: device.id) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(manager.isSimulation ? "确认模拟应用" : "确认写入设备") {
                    Task { await manager.confirmBrightnessChange(for: device.id, planID: plan.id) }
                }
                .disabled(manager.isSuspended || isWriting || manager.drainingOperationIDs.contains(device.id))
                .buttonStyle(.borderedProminent).tint(theme.accent)
            }
        }.padding(28).frame(width: 470)
    }

    private func synchronizeDevice() {
        if draft.deviceID != device.id {
            if let editingDeviceID = draft.deviceID { manager.cancelBrightnessChange(for: editingDeviceID) }
            draft.deviceID = device.id
            draft.percent = nil
            draft.isEdited = false
        }
        seedDraftIfUnedited()
    }

    private func seedDraftIfUnedited() {
        guard !draft.isEdited, let currentPercent else { return }
        draft.percent = Double(currentPercent)
    }
}
