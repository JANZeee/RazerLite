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
                    Toggle("自动刷新电量", isOn: $preferences.automaticBatteryRefresh)
                        .disabled(!manager.isSimulation && batteryRefresh.eligibleDeviceCount == 0 && !preferences.automaticBatteryRefresh)
                    if preferences.automaticBatteryRefresh {
                        Picker("刷新间隔", selection: $preferences.batteryRefreshInterval) {
                            ForEach(BatteryRefreshInterval.allCases) { Text($0.title).tag($0) }
                        }
                        LabeledContent("刷新状态", value: batteryRefresh.status)
                        if let time = batteryRefresh.nextRefreshAt {
                            LabeledContent("下次刷新", value: time.formatted(date: .omitted, time: .shortened))
                        }
                    }
                    if !manager.isSimulation {
                        Text("真实设备自动刷新待验收，当前可手动读取电量。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("低电量提醒", isOn: Binding(get: { batteryAlerts.isEnabled || batteryAlerts.isUpdating }, set: { enabled in
                        Task { await batteryAlerts.setEnabled(enabled) }
                    }))
                    if batteryAlerts.isEnabled {
                        Picker("提醒阈值", selection: $preferences.lowBatteryThreshold) {
                            ForEach([10, 15, 20], id: \.self) { Text("\($0)%").tag($0) }
                        }
                    }
                    LabeledContent(manager.isSimulation ? "模拟通知权限" : "通知权限", value: batteryAlerts.authorization.title)
                    if let issue = batteryAlerts.issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
                    Text(manager.isSimulation ? "离线通知由假服务接收，不弹出系统提醒。" : "仅新取得的设备电量触发提醒，系统缓存与历史值不触发。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("启动") {
                    Toggle("登录时启动", isOn: Binding(get: { loginItem.status.isRegistered }, set: { enabled in
                        Task { await loginItem.setEnabled(enabled) }
                    }))
                    .disabled(loginItem.isUpdating || (!loginItem.status.isRegistered && !loginItem.canEnable))
                    LabeledContent("系统状态", value: loginItem.status.title)
                    if let issue = loginItem.issue ?? loginItem.installationIssue {
                        Text(issue).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if loginItem.status == .requiresApproval {
                        Button("前往系统登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Section("本地档案") {
                    LabeledContent("已保存预设", value: "\(profiles.profiles.count) 个")
                    Text("载入档案只填入编辑器，确认后才会应用到设备。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    DisclosureGroup("存储位置") {
                        Text(profiles.storageURL.path)
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Section("隐私") {
                    Text("无需账号，无遥测，不记录键鼠输入。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("诊断信息") {
                        LabeledContent("HID 接口", value: "\(manager.interfaceCount)")
                        if let milliseconds = manager.discoveryReadyMilliseconds {
                            LabeledContent("发现服务初始化", value: String(format: "%.2f ms", milliseconds))
                                .help("仅为发现服务初始化耗时，不代表窗口启动时间")
                        }
                        Button("刷新设备信息") { manager.refresh() }.disabled(manager.isSuspended)
                    }
                }
            }.formStyle(.grouped)
        }
        .frame(width: 540, height: 700)
        .background(RazerTheme(scheme: scheme).canvas)
        .tint(RazerTheme(scheme: scheme).accent)
        .task { loginItem.refresh(); await batteryAlerts.refreshAuthorization() }
    }
}
