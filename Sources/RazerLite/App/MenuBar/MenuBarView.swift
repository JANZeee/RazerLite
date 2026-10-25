import SwiftUI
import RazerLiteCore

struct MenuBarView: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject var profiles: ProfileService
    @ObservedObject var workspace: AppWorkspace
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(manager.isSimulation ? "RazerLite · 模拟数据" : "RazerLite")
        Divider()
        ForEach(manager.physicalDevices) { device in
            Menu(deviceTitle(device)) {
                Text("连接：\(device.transport)")
                Text(manager.adapterAssessment(for: device).readingSummary)
                ForEach(manager.adapterAssessment(for: device).capabilities.filter { $0.session.previous != nil }) { capability in
                    if let previous = capability.session.previous {
                        Text("上次成功 · \(capability.title)：\(previous.value)")
                        Text("\(previous.at.formatted(date: .abbreviated, time: .standard)) · \(previous.source)")
                    }
                }
                if let battery = batterySummary(device) {
                    Text("电量：\(battery.percent)% · \(battery.source)")
                    Text("取得于 \(battery.acquiredAt.formatted(date: .abbreviated, time: .standard))")
                } else {
                    Text("电量未取得")
                }
                if let reading = manager.mouseReadouts[device.id], reading.issues.contains(where: { manager.batteryReadouts[device.id] == nil || $0.field != "battery" }) {
                    Text("尝试于 \(reading.readAt.formatted(date: .abbreviated, time: .standard))")
                    ForEach(Array(reading.issues.filter { manager.batteryReadouts[device.id] == nil || $0.field != "battery" }.enumerated()), id: \.offset) { _, issue in Text(issue.message) }
                }
                if let reading = manager.keyboardBatteryReadouts[device.id], !reading.hasValue, manager.batteryReadouts[device.id] == nil {
                    Text("尝试于 \(reading.readAt.formatted(date: .abbreviated, time: .standard))")
                    if let issue = reading.issue { Text(issue.message) }
                }
                if let reading = manager.keyboardChargingReadouts[device.id] {
                    Text("键盘充电状态：\(reading.hasValue ? reading.chargingState?.title ?? "未取得" : "未取得")")
                    Text("\(reading.hasValue ? "读取于" : "尝试于") \(reading.readAt.formatted(date: .omitted, time: .standard))")
                    if let issue = reading.issue { Text(issue.message) }
                }
                if let reading = manager.chargingReadouts[device.id] {
                    Text("充电状态：\(reading.state?.title ?? "未取得")")
                    Text("\(reading.state == nil ? "尝试于" : "读取于") \(reading.readAt.formatted(date: .abbreviated, time: .standard))")
                    if let issue = reading.issue { Text(issue.message) }
                }
                if let reading = manager.systemBatteryReadings[device.id], reading.issue != nil, manager.batteryReadouts[device.id] == nil {
                    Text("尝试于 \(reading.acquiredAt.formatted(date: .abbreviated, time: .standard))")
                    if let issue = reading.issue { Text(issue) }
                }
                if let reading = manager.batteryReadouts[device.id], let issue = reading.issue {
                    Text("电量：\(issue.message)")
                    Text("尝试于 \(reading.acquiredAt.formatted(date: .abbreviated, time: .standard))")
                }
                if !DeviceReadRegistry.backends(for: device).isEmpty {
                    Button(manager.capabilityActivity(for: device.id).reading.contains("battery") ? "正在读取电量…"
                        : SystemBatteryService.canRead(device) ? "读取系统电量" : "读取电量") {
                        Task { await manager.readBattery(for: device.id) }
                    }.disabled(manager.isDeviceBusy(device.id) || manager.isSuspended)
                }
                Button("打开设备详情") {
                    workspace.select(device)
                    openWindow(id: "devices")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        if manager.physicalDevices.isEmpty { Text("未发现 Razer 设备") }
        localProfilesMenu
        Divider()
        Button("打开本地档案") {
            workspace.section = .profiles
            openWindow(id: "devices")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("打开设备窗口") {
            workspace.section = .devices
            openWindow(id: "devices")
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut("o")
        Button("刷新设备") { manager.refresh() }.disabled(manager.isSuspended)
        if #available(macOS 14, *) {
            SettingsLink { Text("设置…") }.keyboardShortcut(",")
        } else {
            Button("设置…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }.keyboardShortcut(",")
        }
        Divider()
        Button("退出 RazerLite") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func deviceTitle(_ device: DeviceInfo) -> String {
        device.product + (batterySummary(device).map { " · \($0.percent)%" } ?? "")
    }

    private func batterySummary(_ device: DeviceInfo) -> MenuBatterySummary? { manager.batterySummary(for: device) }

    @ViewBuilder
    private var localProfilesMenu: some View {
        let supported = manager.physicalDevices.filter { ProfileDeviceTarget(device: $0) != nil }
        if !supported.isEmpty {
            Divider()
            Menu("本地 DPI 档案") {
                ForEach(supported) { device in
                    let options = profiles.profiles(for: device)
                    if options.isEmpty {
                        Text("\(device.presentation.name)：暂无本地预设")
                    } else {
                        Menu(device.presentation.name) {
                            ForEach(options) { profile in
                                Button {
                                    select(profile, for: device)
                                } label: {
                                    if profiles.selectedProfile(for: device)?.id == profile.id {
                                        Label(profileTitle(profile), systemImage: "checkmark")
                                    } else {
                                        Text(profileTitle(profile))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func profileTitle(_ profile: MouseDPIProfile) -> String {
        let value = profile.x == profile.y ? "\(profile.x)" : "\(profile.x) / \(profile.y)"
        return "\(profile.name) · \(value) DPI"
    }

    private func select(_ profile: MouseDPIProfile, for device: DeviceInfo) {
        do {
            try profiles.select(profile, for: device)
            workspace.select(device, page: .controls)
            openWindow(id: "devices")
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            // ProfileService exposes the failure in the main window on the next open.
        }
    }
}
