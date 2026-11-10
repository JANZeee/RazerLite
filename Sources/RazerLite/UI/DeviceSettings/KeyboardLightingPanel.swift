import SwiftUI
import RazerLiteCore

@MainActor
private final class KeyboardLightingDraft: ObservableObject {
    @Published var deviceID: String?
}

struct KeyboardLightingPanel: View {
    let device: DeviceInfo
    @ObservedObject var manager: DeviceManager
    @Environment(\.colorScheme) private var scheme
    @StateObject private var draft = KeyboardLightingDraft()

    private var theme: RazerTheme { RazerTheme(scheme: scheme) }
    private var reading: KeyboardBrightnessReading? { manager.keyboardBrightnessReadouts[device.id] }
    private var currentPercent: Int? { reading?.hasValue == true ? reading?.percent : nil }
    private var target: Int? { manager.liveBrightnessTargets[device.id] }
    private var displayed: Double? { target.map(Double.init) ?? currentPercent.map(Double.init) }
    private var busy: Bool { !manager.canAdjustLiveBrightness(for: device.id) }
    private var isReading: Bool { manager.readingKeyboardBrightnessIDs.contains(device.id) }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: "sun.max")
                        .font(.system(size: 25, weight: .light)).foregroundStyle(theme.accent)
                        .frame(width: 50, height: 50)
                        .background(theme.selected, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("灯光亮度").font(.system(size: 14, weight: .medium))
                        Text(target != nil ? "正在应用…" : isReading ? "正在读取…" : currentPercent == nil ? "等待读取" : "拖动即可调整")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(displayed.map { "\(Int($0))%" } ?? "—")
                        .font(.system(size: 32, weight: .light, design: .rounded)).monospacedDigit()
                }
                if let displayed {
                    HStack(spacing: 12) {
                        Image(systemName: "sun.min").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { self.displayed ?? displayed }, set: { value in
                            manager.setKeyboardBrightness(for: device.id, percent: Int(value.rounded()))
                        }), in: 0...100)
                        .tint(theme.accent).disabled(busy)
                        .accessibilityLabel("灯光亮度，拖动立即应用")
                        .accessibilityValue("\(Int(displayed))%")
                        Image(systemName: "sun.max").foregroundStyle(.secondary)
                    }.font(.system(size: 13))
                }
                HStack {
                    Button("关闭灯光") {
                        manager.setKeyboardBrightness(for: device.id, percent: 0)
                    }.disabled(busy || displayed == nil || displayed == 0)
                    Spacer()
                    Button {
                        Task { await manager.readKeyboardBrightness(for: device.id) }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(manager.isSuspended || manager.isDeviceBusy(device.id))
                    .help("重新读取设备亮度").accessibilityLabel("刷新亮度")
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                        .help("修改会直接应用，可能保存到设备。连续拖动会合并请求；停止后读回确认最终值。")
                }.font(.system(size: 11))
                feedback
            }
        }
        .task(id: device.id) {
            if draft.deviceID != device.id {
                if let previous = draft.deviceID { manager.cancelLiveBrightness(for: previous) }
                draft.deviceID = device.id
            }

        }
        .onDisappear {
            if let id = draft.deviceID { manager.cancelLiveBrightness(for: id) }
        }
    }

    @ViewBuilder private var feedback: some View {
        if let issue = reading?.issue {
            Text(issue.message).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = manager.brightnessWriteErrors[device.id] {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.system(size: 11)).foregroundStyle(.red)
        } else if target == nil, let result = manager.brightnessWriteResults[device.id], result.outcome != .verified {
            Label(result.message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
