import SwiftUI
import RazerLiteCore
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject var profiles: ProfileService
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var loginItem: LoginItemController
    @ObservedObject var batteryRefresh: BatteryRefreshController
    @ObservedObject var batteryAlerts: LowBatteryAlertController
    @Environment(\.colorScheme) private var scheme
    private var offersBatteryAlerts: Bool {
        manager.isSimulation || batteryAlerts.isEnabled || batteryAlerts.isUpdating || batteryAlerts.issue != nil
            || manager.physicalDevices.contains { device in
                DeviceReadRegistry.backends(for: device).contains { $0 != .macOSBluetoothBattery }
            }
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 16) {
                Text("R").font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(white: 0.10)).frame(width: 56, height: 56)
                    .background(RazerTheme.green, in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 5) {
                    Text("RazerLite").font(.system(size: 24, weight: .semibold))
                    Text("外设管理").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版本")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }.padding(.horizontal, 30).padding(.top, 27).padding(.bottom, 12)
            Form {
                Section("通用") {
                    Picker("外观", selection: $preferences.appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("关闭主窗口后", selection: $preferences.closeBehavior) {
                        ForEach(WindowCloseBehavior.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("电量") {
                    if manager.isSimulation || batteryRefresh.eligibleDeviceCount > 0 || preferences.automaticBatteryRefresh {
                        Toggle("自动刷新电量", isOn: $preferences.automaticBatteryRefresh)
                        if preferences.automaticBatteryRefresh {
                            Picker("刷新间隔", selection: $preferences.batteryRefreshInterval) {
                                ForEach(BatteryRefreshInterval.allCases) { Text($0.title).tag($0) }
                            }
                            Text(batteryRefresh.status).font(.caption).foregroundStyle(.secondary)
                            if let time = batteryRefresh.nextRefreshAt {
                                LabeledContent("下次刷新", value: time.formatted(date: .omitted, time: .shortened))
                            }
                        }
                    } else if !manager.physicalDevices.isEmpty {
                        Text("自动刷新暂不可用，可在设备页手动读取。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if offersBatteryAlerts {
                        Toggle("低电量提醒", isOn: Binding(get: { batteryAlerts.isEnabled || batteryAlerts.isUpdating }, set: { enabled in
                            Task { await batteryAlerts.setEnabled(enabled) }
                        }))
                        if batteryAlerts.isEnabled {
                            Picker("提醒阈值", selection: $preferences.lowBatteryThreshold) {
                                ForEach([10, 15, 20], id: \.self) { Text("\($0)%").tag($0) }
                            }
                        }
                        if batteryAlerts.isEnabled || batteryAlerts.isUpdating || batteryAlerts.issue != nil {
                            LabeledContent(manager.isSimulation ? "模拟通知权限" : "通知权限", value: batteryAlerts.authorization.title)
                        }
                        if let issue = batteryAlerts.issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
                        Text(manager.isSimulation ? "模拟提醒不会发送系统通知。" : "读取到低电量时提醒；不使用历史值或系统缓存。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(manager.physicalDevices.isEmpty ? "连接支持电量读取的设备后，可设置低电量提醒。" : "当前设备暂不支持低电量提醒。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("启动") {
                    Toggle("登录时启动", isOn: Binding(get: { loginItem.status.isRegistered }, set: { enabled in
                        Task { await loginItem.setEnabled(enabled) }
                    }))
                    .disabled(loginItem.isUpdating || (!loginItem.status.isRegistered && !loginItem.canEnable))
                    if let issue = loginItem.issue ?? loginItem.installationIssue {
                        Text(issue).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if loginItem.status == .requiresApproval || loginItem.status == .unavailable {
                        Text(loginItem.status.title).font(.caption).foregroundStyle(.secondary)
                    }
                    if loginItem.status == .requiresApproval {
                        Button("前往系统登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Section {
                    DisclosureGroup("存储与诊断") {
                        LabeledContent("本地预设", value: "\(profiles.profiles.count) 个")
                        Text(profiles.storageURL.path)
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        LabeledContent("HID 接口", value: "\(manager.interfaceCount)")
                        if let milliseconds = manager.discoveryReadyMilliseconds {
                            LabeledContent("发现服务初始化", value: String(format: "%.2f ms", milliseconds))
                                .help("仅为发现服务初始化耗时，不代表窗口启动时间")
                        }
                    }
                    Text("本地存储 · 无遥测 · 不记录键鼠输入")
                        .font(.caption).foregroundStyle(.secondary)
                }

            }.formStyle(.grouped)
        }
        .frame(width: 540, height: 600)
        .background(RazerTheme(scheme: scheme).canvas)
        .tint(RazerTheme(scheme: scheme).accent)
        .task { loginItem.refresh(); await batteryAlerts.refreshAuthorization() }
    }
}
