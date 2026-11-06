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
                batteryItems(for: device)
                Divider()
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
    private func batteryItems(for device: DeviceInfo) -> some View {
        let capability = manager.adapterAssessment(for: device).capability("battery")
        if let capability, capability.implementation == .implemented {
            if let battery = batterySummary(device) {
                Text("电量：\(battery.percent)% · \(battery.source)")
                Text("取得于 \(battery.acquiredAt.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Text("电量：\(capability.session.state.title)\(capability.session.state == .failed ? capability.session.failureKind.map { " · \($0.title)" } ?? "" : "")")
                if let previous = capability.session.previous {
                    Text("上次电量：\(previous.value) · 历史值")
                    Text("\(previous.at.formatted(date: .abbreviated, time: .shortened)) · \(previous.source)")
                }
            }
            if capability.routeAvailable {
                Button(batteryActionTitle(for: device, session: capability.session)) {
                    Task { await manager.readBattery(for: device.id) }
                }.disabled(manager.isDeviceBusy(device.id) || manager.isSuspended || !manager.isMonitoring)
            }
        } else {
            Text("电量读取尚未适配")
        }
    }

    private func batteryActionTitle(for device: DeviceInfo, session: CapabilitySession) -> String {
        if session.state == .reading { return "正在读取电量…" }
        let retry = session.state == .failed || session.state == .cancelled
        if SystemBatteryService.canRead(device) { return retry ? "重试读取系统电量" : "读取系统电量" }
        if KeyboardPowerReadService.canRead(device) { return retry ? "重试电量试读" : "试读电量" }
        return retry ? "重试读取电量" : "读取电量"
    }

    @ViewBuilder
    private var localProfilesMenu: some View {
        let supported = manager.physicalDevices.filter { ProfileDeviceTarget(device: $0) != nil }
        Divider()
        Menu("本地 DPI 档案") {
            if !profiles.canModify {
                Text("本地档案不可用，请打开档案查看原因")
            } else {
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
                                }.disabled(manager.isSuspended || manager.isDeviceBusy(device.id))
                            }
                        }
                    }
                }
            }
            if !supported.isEmpty { Divider() }
            Button("管理本地档案…") {
                workspace.section = .profiles
                openDeviceWindow()
            }
        }
    }

    private func profileTitle(_ profile: MouseDPIProfile) -> String {
        let value = profile.x == profile.y ? "\(profile.x)" : "\(profile.x) / \(profile.y)"
        return "\(profile.name) · \(value) DPI"
    }

    private func select(_ profile: MouseDPIProfile, for device: DeviceInfo) {
        do {
            guard let current = manager.physicalDevices.first(where: { $0.id == device.id }),
                  profile.target.matches(current) else { throw ProfileLibraryError.profileDoesNotMatchDevice }
            guard !manager.isSuspended, !manager.isDeviceBusy(current.id) else {
                manager.reportError("设备正在处理其他操作，请稍后载入预设。")
                openDeviceWindow()
                return
            }
            try profiles.select(profile, for: current)
            workspace.loadProfile(profile, for: current)
            openDeviceWindow()
        } catch {
            workspace.section = .profiles
            manager.reportError("预设未载入：\(error.localizedDescription)")
            openDeviceWindow()
        }
    }

    private func openDeviceWindow() {
        openWindow(id: "devices")
        NSApp.activate(ignoringOtherApps: true)
    }
}
