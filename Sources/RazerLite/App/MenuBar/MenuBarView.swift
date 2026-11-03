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
                if let battery = batterySummary(device) {
                    Text("电量：\(battery.percent)% · \(battery.source)")
                    Text("取得于 \(battery.acquiredAt.formatted(date: .abbreviated, time: .shortened))")
                } else if let previous = manager.adapterAssessment(for: device).capabilities
                    .first(where: { $0.id == "battery" })?.session.previous {
                    Text("上次电量：\(previous.value) · 历史值")
                    Text("\(previous.at.formatted(date: .abbreviated, time: .shortened)) · \(previous.source)")
                } else {
                    Text("电量未取得")
                }
                if !DeviceReadRegistry.backends(for: device).isEmpty {
                    Button(manager.capabilityActivity(for: device.id).reading.contains("battery") ? "正在读取电量…"
                        : SystemBatteryService.canRead(device) ? "读取系统电量"
                        : KeyboardPowerReadService.canRead(device) ? "试读电量" : "读取电量") {
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
        if manager.physicalDevices.isEmpty {
            Text("未发现 Razer 设备")
            Button("检查连接…") {
                workspace.section = .devices
                workspace.requestsConnectionCheck = true
                openWindow(id: "devices")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        localProfilesMenu
        Divider()
        Button("打开设备窗口") {
            workspace.section = .devices
            openWindow(id: "devices")
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut("o")
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
