import SwiftUI
import RazerLiteCore

@MainActor
final class DeviceDetailState: ObservableObject {
    @Published var page = DevicePage.overview {
        didSet { if page != .controls { profileLoadRequest = nil } }
    }
    @Published var profileLoadRequest: DPIProfileLoadRequest?

}

struct DeviceDetailView: View {
    let device: DeviceInfo
    @ObservedObject var manager: DeviceManager
    @ObservedObject var profiles: ProfileService
    @ObservedObject var workspace: AppWorkspace
    @StateObject private var state = DeviceDetailState()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            DevicePageContent(device: device, logs: manager.logs, state: state,
                              telemetry: manager.mouseReadouts[device.id],
                              isReading: manager.readingDeviceIDs.contains(device.id),
                              onRead: { Task { await manager.readMouseState(for: device.id) } },
                              systemBattery: manager.systemBatteryReadings[device.id],
                              isReadingSystemBattery: manager.readingSystemBatteryIDs.contains(device.id),
                              onReadSystemBattery: { Task { await manager.readSystemBattery(for: device.id) } },
                              polling: manager.pollingReadouts[device.id],
                              isReadingPolling: manager.readingPollingDeviceIDs.contains(device.id),
                              onReadPolling: { Task { await manager.readPollingRate(for: device.id) } },
                              charging: manager.chargingReadouts[device.id],
                              isReadingCharging: manager.readingChargingDeviceIDs.contains(device.id),
                              onReadCharging: { Task { await manager.readChargingState(for: device.id) } },
                              dpiManager: manager, profiles: profiles, onOpenProfileLibrary: { workspace.section = .profiles })
                .padding(28).frame(maxWidth: 1060).frame(maxWidth: .infinity)
        }.background(RazerTheme(scheme: scheme).canvas)
        .onAppear { consumeNavigationRequest() }
        .onChange(of: workspace.navigationRequest?.id) { _ in consumeNavigationRequest() }
    }

    private func consumeNavigationRequest() {
        // Read after publication: @Published's publisher emits before the
        // stored property changes, so consuming it inside onReceive can race.
        guard let request = workspace.navigationRequest, request.deviceID == device.id else { return }
        state.profileLoadRequest = request.profileLoad
        state.page = request.page
        workspace.navigationRequest = nil
    }
}

struct DevicePageContent: View {
    let device: DeviceInfo
    let logs: [DiagnosticLog]
    @ObservedObject var state: DeviceDetailState
    var telemetry: MouseTelemetry? = nil
    var isReading = false
    var onRead: () -> Void = {}
    var systemBattery: SystemBatteryReading? = nil
    var isReadingSystemBattery = false
    var onReadSystemBattery: () -> Void = {}
    var polling: MousePollingReading? = nil
    var isReadingPolling = false
    var onReadPolling: () -> Void = {}
    var charging: MouseChargingReading? = nil
    var isReadingCharging = false
    var onReadCharging: () -> Void = {}
    var dpiManager: DeviceManager? = nil
    @ObservedObject var profiles: ProfileService
    var onOpenProfileLibrary: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    private var theme: RazerTheme { RazerTheme(scheme: scheme) }
    private var summary: DeviceReadSummary {
        if let dpiManager { return dpiManager.readSummary(for: device.id) }
        return DeviceReadSummary.assess(mouse: telemetry, systemBattery: systemBattery, polling: polling, charging: charging,
                                 keyboardBattery: dpiManager?.keyboardBatteryReadouts[device.id],
                                 keyboardCharging: dpiManager?.keyboardChargingReadouts[device.id],
                                 isReading: isReading || isReadingSystemBattery || isReadingPolling || isReadingCharging
                                    || dpiManager?.readingKeyboardPowerIDs.contains(device.id) == true,
                                 isSuspended: (dpiManager?.isSuspended == true || dpiManager?.drainingOperationIDs.contains(device.id) == true || dpiManager?.readingBatteryIDs.contains(device.id) == true))
    }

    private var visibleMouseIssues: [MouseReadIssue] {
        (telemetry?.issues ?? []).filter { dpiManager?.batteryReadouts[device.id] == nil || $0.field != "battery" }
    }
    private var batterySummary: MenuBatterySummary? {
        if let dpiManager { return dpiManager.batterySummary(for: device) }
        return MenuBatterySummary.choose(mouse: telemetry, system: systemBattery, keyboard: nil)
    }
    private var pages: [DevicePage] {
        var result: [DevicePage] = [.overview]
        if MouseReadService.canRead(device) || ReclusaBrightnessReadService.canRead(device) { result.append(.controls) }
        if ProfileDeviceTarget(device: device) != nil { result.append(.profiles) }
        result.append(.information)
        return result
    }
    private var selectedPage: DevicePage { pages.contains(state.page) ? state.page : .overview }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Text("设备").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                Text(device.presentation.name).fontWeight(.medium)
                    .lineLimit(1).truncationMode(.middle).layoutPriority(-1).help(device.product)
                Spacer()
                SmallBadge(title: device.isVirtual ? "虚拟设备" : summary.state.title,
                           color: summary.state == .unconfirmed || summary.state == .partial ? .orange
                            : summary.state == .deviceResponse || summary.state == .systemMetadata ? theme.accent : .secondary,
                           dot: true)
                    .help(summary.state.detail).accessibilityHint(summary.state.detail)
                    .fixedSize(horizontal: true, vertical: false)
                if let dpiManager, !DeviceReadRegistry.backends(for: device).isEmpty, !SystemBatteryService.canRead(device) {
                    Button { Task { await dpiManager.readBattery(for: device.id) } } label: {
                        Label("读取电量", systemImage: "battery.100")
                    }
                    .accessibilityLabel("读取电量").help("只读取电量，不查询 DPI；读数不表示持续在线")
                    .disabled(dpiManager.isSuspended || dpiManager.isDeviceBusy(device.id))
                }
                if MouseReadService.canRead(device) {
                    Button(action: onRead) {
                        Label(isReading ? "正在读取…" : "读取状态", systemImage: "arrow.down.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isReading ? Color.secondary : scheme == .dark ? Color(white: 0.08) : .white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(isReading ? theme.elevated : theme.accent, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(isReading || isReadingPolling || isReadingCharging || (dpiManager?.isSuspended == true || dpiManager?.drainingOperationIDs.contains(device.id) == true || dpiManager?.readingBatteryIDs.contains(device.id) == true)
                              || dpiManager?.isDeviceBusy(device.id) == true)
                    .help("手动读取电量与 DPI，不修改设备设置")
                } else if SystemBatteryService.canRead(device) {
                    Button(action: onReadSystemBattery) {
                        Label(isReadingSystemBattery ? "正在读取…" : "读取系统电量", systemImage: "battery.100")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .disabled(isReadingSystemBattery || (dpiManager?.isSuspended == true || dpiManager?.drainingOperationIDs.contains(device.id) == true || dpiManager?.readingBatteryIDs.contains(device.id) == true))
                    .help("按需读取 macOS 发布的电量，显示系统缓存；不修改设备设置")
                } else if let dpiManager, DeviceReadRegistry.backends(for: device).isEmpty {
                    Button { dpiManager.refresh() } label: {
                        Label("刷新信息", systemImage: "arrow.clockwise").font(.system(size: 11))
                    }.help("读取系统发布的 VID/PID、连接方式与 HID 接口；不发送厂商命令")
                }
            }.font(.system(size: 12))
            HStack(spacing: 5) {
                ForEach(pages, id: \.self) { page in
                    Button {
                        state.profileLoadRequest = nil
                        state.page = page
                    } label: {
                        Text(page.title(for: device)).font(.system(size: 12, weight: selectedPage == page ? .semibold : .regular))
                            .foregroundStyle(selectedPage == page ? Color.primary : Color.secondary)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(selectedPage == page ? theme.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selectedPage == page ? theme.line : .clear) }
                    }.buttonStyle(.plain).accessibilityAddTraits(selectedPage == page ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }.padding(4).background(theme.line.opacity(0.5), in: RoundedRectangle(cornerRadius: 11))
            if let time = summary.lastResultAt {
                Text("更新于 \(time.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("最近一次查询完成或失败的时间；各项读数保留自己的取得时间")
            }
            if summary.state == .waiting {
                Label(summary.state.detail, systemImage: "hourglass")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let dpiManager {
                PreviousReadingsView(assessment: dpiManager.adapterAssessment(for: device))
            }
            if let issue = dpiManager?.batteryReadouts[device.id]?.issue {
                Label(issue.message, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if isReading || !visibleMouseIssues.isEmpty { readStatus }
            if isReadingSystemBattery || (systemBattery?.issue != nil && dpiManager?.batteryReadouts[device.id] == nil) { systemBatteryStatus }
            switch selectedPage {
            case .overview: overview
            case .controls:
                if ReclusaBrightnessReadService.canRead(device), let dpiManager {
                    VStack(alignment: .leading, spacing: 18) {
                        KeyboardLightingPanel(device: device, manager: dpiManager)
                        KeyboardPollingPanel(device: device, manager: dpiManager)
                    }
                    .task(id: "\(device.id)-\(dpiManager.isSuspended)") {
                        guard await dpiManager.waitUntilAvailable(for: device.id) else { return }
                        if dpiManager.keyboardBrightnessReadouts[device.id] == nil {
                            await dpiManager.readKeyboardBrightness(for: device.id)
                        }
                        if !Task.isCancelled, dpiManager.pollingReadouts[device.id] == nil {
                            await dpiManager.readPollingRate(for: device.id)
                        }
                    }
                }
                else if device.presentation.isKeyboard {
                    Text("此型号的灯光设置尚未适配。").font(.callout).foregroundStyle(.secondary)
                }
                else {
                    PerformancePanel(device: device, telemetry: telemetry, polling: polling, manager: dpiManager,
                                     isReadingPolling: isReadingPolling,
                                     pollingDisabled: isReading || isReadingCharging || (dpiManager?.isSuspended == true || dpiManager?.drainingOperationIDs.contains(device.id) == true || dpiManager?.readingBatteryIDs.contains(device.id) == true)
                                        || dpiManager?.isDeviceBusy(device.id) == true,
                                     onReadPolling: onReadPolling)
                    if let dpiManager, MouseReadService.canRead(device) {
                        DPIEditorView(device: device, manager: dpiManager, selectedProfile: profiles.selectedProfile(for: device),
                                      profileLoadRequest: state.profileLoadRequest)
                    }
                }
            case .buttons: ButtonMappingPanel()
            case .profiles:
                if ProfileDeviceTarget(device: device) != nil {
                    ProfileLibraryView(device: device, telemetry: telemetry, profiles: profiles, onOpenLibrary: onOpenProfileLibrary,
                                       canLoadIntoEditor: dpiManager?.isSuspended != true && dpiManager?.isDeviceBusy(device.id) != true) {
                        if let profile = profiles.selectedProfile(for: device) {
                            state.profileLoadRequest = DPIProfileLoadRequest(profile: profile)
                        }
                        state.page = .controls
                    }
                } else {
                    ProfileUnavailableView(device: device)
                }
            case .information: DeviceInformationView(device: device, logs: logs,
                assessment: dpiManager?.adapterAssessment(for: device)
                    ?? AdapterCatalog.assess(device, telemetry: telemetry, systemBattery: systemBattery, polling: polling,
                        charging: charging, activity: .init(reading: isReading ? ["battery", "dpi", "stages"] : [])))
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 13) {
                    Text(device.isVirtual ? "系统设备" : device.kind.title)
                        .font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(theme.accent)
                    Text(device.presentation.name).font(.system(size: 28, weight: .semibold))
                        .tracking(-0.8).lineLimit(2).minimumScaleFactor(0.8)
                    Text(device.presentation.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                    HStack(spacing: 7) {
                        SmallBadge(title: device.transport)
                    }.padding(.top, 4)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 0) {
                    if device.isVirtual {
                        Image(systemName: "cpu").font(.system(size: 66, weight: .ultraLight))
                            .foregroundStyle(.secondary).frame(width: 230, height: 174)
                    } else if device.kind == .mouse || device.kind == .keyboard {
                        DeviceArtwork(keyboard: device.presentation.isKeyboard)
                            .scaleEffect(0.72).frame(width: 214, height: 138)
                    } else {
                        Image(systemName: device.kind.symbol).font(.system(size: 66, weight: .ultraLight))
                            .foregroundStyle(.secondary).frame(width: 230, height: 174)
                    }
                    Text("设备示意").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 26).padding(.vertical, 20)
            .frame(maxWidth: .infinity, minHeight: 172)
            .background {
                RoundedRectangle(cornerRadius: 18).fill(theme.surface)
                RoundedRectangle(cornerRadius: 18)
                    .fill(LinearGradient(colors: [theme.accent.opacity(0.025), theme.accent.opacity(0.065)], startPoint: .leading, endPoint: .trailing))
            }
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(theme.line) }
            HStack(spacing: 0) {
                metric("连接方式", value: device.transport, detail: device.isVirtual ? "系统发布的属性" : "系统已识别", icon: "cable.connector")
                Rectangle().fill(theme.line).frame(width: 1, height: 50)
                metric("电池电量", value: batterySummary.map { "\($0.percent)%" } ?? "—",
                       detail: batterySummary?.source ?? (dpiManager?.capabilityActivity(for: device.id).reading.contains("battery") == true ? "正在读取" : "未取得"),
                       icon: "battery.100", acquiredAt: batterySummary?.acquiredAt)
            }
            .padding(.vertical, 18).background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(theme.line) }
            if ChargingReadService.canRead(device) {
                ChargingStatusPanel(reading: charging, isReading: isReadingCharging,
                                    disabled: isReading || isReadingPolling || (dpiManager?.isSuspended == true || dpiManager?.drainingOperationIDs.contains(device.id) == true || dpiManager?.readingBatteryIDs.contains(device.id) == true)
                                        || dpiManager?.isDeviceBusy(device.id) == true,
                                    onRead: onReadCharging)
            }
            if let manager = dpiManager, KeyboardPowerReadService.canRead(device) {
                KeyboardPowerPanel(device: device, manager: manager)
            }
            if MouseReadService.canRead(device) {
                HStack(alignment: .top, spacing: 15) {
                    FeatureTile(title: "性能", icon: "speedometer", headline: "DPI 与回报率",
                                detail: "查看与调整鼠标灵敏度",
                                badge: telemetry?.dpi != nil ? "已读取" : "未读取") { state.page = .controls }
                    if ProfileDeviceTarget(device: device) != nil {
                        FeatureTile(title: "档案", icon: "rectangle.stack", headline: "DPI 预设",
                                    detail: profiles.selectedProfile(for: device)?.name ?? "保存常用灵敏度",
                                    badge: "本地") { state.page = .profiles }
                    }
                }
            } else if ReclusaBrightnessReadService.canRead(device) {
                FeatureTile(title: "灯光", icon: "sun.max", headline: "键盘亮度",
                            detail: "拖动亮度条即可调整", badge: dpiManager?.keyboardBrightnessReadouts[device.id]?.hasValue == true ? "已读取" : "未读取") {
                    state.page = .controls
                }
            } else if DeviceReadRegistry.backends(for: device).isEmpty && !device.isVirtual {
                Text("已识别设备，设置功能尚未适配。")
                    .font(.callout).foregroundStyle(.secondary)
            }

        }
    }

    private var systemBatteryStatus: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: isReadingSystemBattery ? "arrow.triangle.2.circlepath" : systemBattery?.percent != nil ? "battery.100" : "exclamationmark.circle")
                .font(.system(size: 16)).foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 6) {
                if isReadingSystemBattery {
                    Text("正在读取 macOS 电量信息").font(.system(size: 12, weight: .medium))
                } else if let reading = systemBattery {
                    HStack {
                        Text(reading.percent.map { "系统电量 · \($0)%" } ?? "系统电量未取得")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(reading.acquiredAt.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    if let issue = reading.issue {
                        if let kind = reading.failureKind { SmallBadge(title: kind.title, color: .orange) }
                        Text(issue).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let source = reading.source {
                        Text("系统缓存 · \(source.title)")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .help("时间为应用取得时间，设备测量时间未知；不自动轮询")
                    }
                }
            }
        }
        .padding(15).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(theme.accent.opacity(0.16)) }
    }

    private var readStatus: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: isReading ? "arrow.triangle.2.circlepath" : telemetry?.issues.isEmpty == true ? "checkmark.circle" : "exclamationmark.circle")
                .font(.system(size: 16)).foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 6) {
                if isReading {
                    Text("正在读取电量与 DPI").font(.system(size: 12, weight: .medium))
                    Text("查询在后台执行，请等待设备响应。").font(.system(size: 10)).foregroundStyle(.secondary)
                } else if let telemetry {
                    HStack {
                        Text(dpiManager?.batteryReadouts[device.id] != nil ? "上次 DPI 查询" : telemetry.isComplete ? "读取完成" : telemetry.dpi != nil && telemetry.issues.isEmpty ? "DPI 读取完成" : telemetry.batteryPercent != nil || telemetry.dpi != nil ? "部分读取完成" : "读取未完成")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(telemetry.readAt.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    ForEach(Array(visibleMouseIssues.enumerated()), id: \.offset) { _, issue in
                        if let kind = issue.kind { SmallBadge(title: kind.title, color: .orange) }
                        Text(issue.message).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(15).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(theme.accent.opacity(0.16)) }
    }

    private func metric(_ title: String, value: String, detail: String, icon: String, acquiredAt: Date? = nil) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon).font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(value).font(.system(size: 21, weight: .medium, design: .rounded))
            }
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            if let acquiredAt {
                Text("取得于 \(acquiredAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
    }
}

private struct FeatureTile: View {
    let title: String
    let icon: String
    let headline: String
    let detail: String
    let badge: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Image(systemName: icon).font(.system(size: 19, weight: .light))
                            .foregroundStyle(RazerTheme(scheme: scheme).accent)
                        Text(title).font(.system(size: 12, weight: .medium))
                        Spacer()
                        SmallBadge(title: badge)
                    }
                    Text(headline).font(.system(size: 16, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                    HStack {
                        Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
}
