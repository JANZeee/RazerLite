import SwiftUI
import RazerLiteCore

struct KeyboardPowerPanel: View {
    let device: DeviceInfo
    @ObservedObject var manager: DeviceManager
    private var busy: Bool { manager.isSuspended || manager.readingBatteryIDs.contains(device.id) || manager.drainingOperationIDs.contains(device.id) || manager.readingKeyboardPowerIDs.contains(device.id) }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("键盘电源状态", systemImage: "battery.100").font(.system(size: 13, weight: .medium))
                    Spacer()
                    SmallBadge(title: "试验适配", color: .orange).help("尚待 macOS 真机验证")
                }
                if manager.readingKeyboardPowerIDs.contains(device.id) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取，请稍候…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                row(.battery, reading: manager.keyboardBatteryReadouts[device.id])
                Divider()
                row(.charging, reading: manager.keyboardChargingReadouts[device.id])
                DisclosureGroup("读取说明") {
                    Text("电量和充电状态独立读取。“未充电”不代表正在放电。应用仅共享打开接口，不订阅输入或切换设备模式；尚待真机验证。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ field: KeyboardPowerField, reading: KeyboardPowerReading?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(field.title).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(value(field, reading: reading)).font(.system(size: 17, weight: .medium))
                }
                Spacer()
                Button("试读\(field.title)") { Task { await manager.readKeyboardPower(for: device.id, field: field) } }
                    .disabled(busy)
            }
            if field == .battery, let current = manager.batteryReadouts[device.id] {
                Text("取得于 \(current.acquiredAt.formatted(date: .abbreviated, time: .standard)) · \(current.source.title)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if let issue = current.issue { Text(issue.message).font(.caption).foregroundStyle(.secondary) }
            } else if let reading {
                Text("\(reading.hasValue ? "读取于" : "尝试于") \(reading.readAt.formatted(date: .abbreviated, time: .standard)) · 设备读取")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if let issue = reading.issue {
                    if let kind = issue.kind { SmallBadge(title: kind.title, color: .orange) }
                    Text(issue.message).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func value(_ field: KeyboardPowerField, reading: KeyboardPowerReading?) -> String {
        if field == .battery {
            if manager.readingBatteryIDs.contains(device.id) { return "正在读取…" }
            if let value = manager.batteryReadouts[device.id] { return value.isValid ? value.percent.map { "\($0)%" } ?? "未取得" : "未取得" }
        }
        guard let reading else { return "尚未读取" }
        guard reading.hasValue else { return "未取得" }
        return field == .battery ? reading.batteryPercent.map { "\($0)%" } ?? "未取得" : reading.chargingState?.title ?? "未取得"
    }
}
