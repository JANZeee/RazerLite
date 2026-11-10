import SwiftUI
import RazerLiteCore

struct KeyboardPowerPanel: View {
    let device: DeviceInfo
    @ObservedObject var manager: DeviceManager
    private var busy: Bool { manager.isSuspended || manager.isDeviceBusy(device.id) }
    private var battery: KeyboardPowerReading? { manager.keyboardBatteryReadouts[device.id] }
    private var charging: KeyboardPowerReading? { manager.keyboardChargingReadouts[device.id] }
    private var batteryText: String {
        if let current = manager.batteryReadouts[device.id] {
            return current.isValid ? current.percent.map { "\($0)%" } ?? "未取得" : "未取得"
        }
        return battery?.hasValue == true ? battery?.batteryPercent.map { "\($0)%" } ?? "未取得" : "未读取"
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("电量", systemImage: "battery.100").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button {
                        Task { await refresh() }
                    } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(busy)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(batteryText).font(.system(size: 32, weight: .light, design: .rounded)).monospacedDigit()
                    if let state = charging?.chargingState, charging?.hasValue == true {
                        Text(state.title).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if manager.readingKeyboardPowerIDs.contains(device.id) { ProgressView().controlSize(.small) }
                }
                if let time = manager.batteryReadouts[device.id]?.acquiredAt ?? battery?.readAt {
                    Text("读取于 \(time.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let issue = manager.batteryReadouts[device.id]?.issue ?? battery?.issue ?? charging?.issue {
                    Text(issue.message).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: "\(device.id)-\(manager.isSuspended)") {
            guard await manager.waitUntilAvailable(for: device.id) else { return }
            if manager.batteryReadouts[device.id] == nil && battery == nil { await refresh() }
        }
    }

    private func refresh() async {
        await manager.readKeyboardPower(for: device.id, field: .battery)
        if !Task.isCancelled { await manager.readKeyboardPower(for: device.id, field: .charging) }
    }
}
