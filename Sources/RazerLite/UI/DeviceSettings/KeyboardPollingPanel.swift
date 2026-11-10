import SwiftUI
import RazerLiteCore

struct KeyboardPollingPanel: View {
    let device: DeviceInfo
    @ObservedObject var manager: DeviceManager

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("回报率", systemImage: "waveform.path").font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text(manager.pollingReadouts[device.id]?.configuredHertz.map { "\($0) Hz" } ?? "未读取")
                        .font(.system(size: 16, weight: .medium, design: .rounded)).monospacedDigit()
                    Button {
                        Task { await manager.readPollingRate(for: device.id) }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(manager.isSuspended || manager.isDeviceBusy(device.id))
                    .accessibilityLabel("刷新回报率")
                }
                if let issue = manager.pollingReadouts[device.id]?.issue {
                    Text(issue.message).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                PollingRateEditorView(device: device, manager: manager)
                Text("接收器支持 125–1000 Hz 调整；显示值为设备配置。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("更高回报率涉及共享接收器限制，暂未开放设置。")
            }
        }
    }
}
