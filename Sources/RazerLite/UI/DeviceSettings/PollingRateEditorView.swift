import SwiftUI
import RazerLiteCore

@MainActor
private final class PollingRateEditorState: ObservableObject {
    @Published var hertz: Int?
}

struct PollingRateEditorView: View {
    let device: DeviceInfo
    @ObservedObject var manager: DeviceManager
    @StateObject private var editor = PollingRateEditorState()
    private var busy: Bool { manager.isSuspended || manager.isDeviceBusy(device.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Picker("回报率", selection: Binding(get: { editor.hertz }, set: { hertz in
                editor.hertz = hertz
                guard let hertz else { return }
                Task { await manager.preparePollingChange(for: device.id, hertz: hertz) }
            })) {
                Text("选择回报率").tag(Int?.none)
                ForEach(PollingRateControlService.supportedRates(for: device), id: \.self) { hertz in
                    Text("\(hertz) Hz").tag(Optional(hertz))
                }
                if let hertz = editor.hertz, !PollingRateControlService.supportedRates(for: device).contains(hertz) {
                    Text("\(hertz) Hz · 当前").tag(Optional(hertz))
                }
            }.frame(maxWidth: 280).disabled(busy)
            Text("选择后确认应用，可能短暂中断无线连接。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let error = manager.pollingWriteErrors[device.id] {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            if let result = manager.pollingWriteResults[device.id] {
                Label(result.message, systemImage: result.outcome == .verified ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(result.outcome == .verified ? Color.secondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: Binding(get: { manager.pendingPollingChanges[device.id] }, set: { value in
            if value == nil { manager.cancelPollingChange(for: device.id) }
        })) { plan in
            VStack(alignment: .leading, spacing: 20) {
                Label(manager.isSimulation ? "模拟回报率变更" : "确认修改回报率", systemImage: "waveform.path")
                    .font(.system(size: 22, weight: .semibold))
                if manager.isSimulation {
                    Text("模拟数据 · 没有真实设备通信。").font(.system(size: 12)).foregroundStyle(.orange)
                }
                Text(plan.deviceName).font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    Text("\(plan.before) Hz")
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text("\(plan.after) Hz").bold()
                }.font(.system(size: 28, weight: .light, design: .rounded))
                Text("将修改设备回报率配置，可能短暂中断无线连接，保存及跨重启行为尚未验证。确认后发送一次并读回配置，不代表实际输入频率。")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Text("60 秒内有效；写前重新检查。配置变化即中止，失败不自动重试或回滚。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("取消") { manager.cancelPollingChange(for: device.id) }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(manager.isSimulation ? "确认模拟应用" : "确认写入设备") {
                        Task { await manager.confirmPollingChange(for: device.id, planID: plan.id) }
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(28).frame(width: 480)
        }
        .onAppear {
            if let current = manager.pollingReadouts[device.id]?.configuredHertz { editor.hertz = current }
        }
        .onChange(of: manager.pollingReadouts[device.id]?.configuredHertz) { value in
            if manager.pendingPollingChanges[device.id] == nil { editor.hertz = value }
        }
        .onChange(of: manager.pendingPollingChanges[device.id]?.id) { value in
            if value == nil, let current = manager.pollingReadouts[device.id]?.configuredHertz { editor.hertz = current }
        }
        .onChange(of: manager.pollingWriteErrors[device.id]) { value in
            if value != nil { editor.hertz = nil }
        }
        .onDisappear { manager.cancelPollingChange(for: device.id) }
    }
}
