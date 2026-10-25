import Foundation

public enum CapabilitySessionState: String, Codable, Sendable {
    case notRead, notRequested, reading, waiting, cancelled, working, awaitingConfirmation, succeeded, failed, unconfirmed, unavailable, suspended, localOnly
    public var title: String {
        switch self {
        case .notRead: "尚未读取"
        case .notRequested: "尚未应用"
        case .reading: "正在读取"
        case .waiting: "等待上次操作结束"
        case .cancelled: "读取已取消"
        case .working: "操作进行中"
        case .awaitingConfirmation: "等待确认"
        case .succeeded: "本次已取得结果"
        case .failed: "本次读取失败"
        case .unconfirmed: "写入结果未确认"
        case .unavailable: "当前不可用"
        case .suspended: "读取已暂停"
        case .localOnly: "本地可用"
        }
    }
}

/// A previous successful value from this connection only; never used as a current reading.
public struct CapabilitySample: Codable, Equatable, Sendable {
    public let value: String
    public let at: Date
    public let source: String
}

public struct CapabilitySession: Codable, Equatable, Sendable {
    public let state: CapabilitySessionState
    public let at: Date?
    public let source: String?
    public let failureKind: ReadFailureKind?
    public let detail: String
    public let value: String?
    public let previous: CapabilitySample?

    var sample: CapabilitySample? {
        guard state == .succeeded, let value, let at, let source else { return nil }
        return .init(value: value, at: at, source: source)
    }

    init(_ state: CapabilitySessionState, at: Date? = nil, source: String? = nil,
         failureKind: ReadFailureKind? = nil, detail: String, value: String? = nil, previous: CapabilitySample? = nil) {
        self.state = state; self.at = at; self.source = source; self.failureKind = failureKind; self.detail = detail
        self.value = value; self.previous = previous
    }
}

/// Transient activity only, no write permit or device parameters are retained here.
public struct CapabilityActivity: Sendable {
    public var reading: Set<String>
    public var isSuspended: Bool
    public var dpiBusy: Bool
    public var dpiAwaitingConfirmation: Bool
    public var isDraining: Bool
    public var cancelled: Set<String>
    public var previousReadings: [String: CapabilitySample]
    public init(reading: Set<String> = [], isSuspended: Bool = false, dpiBusy: Bool = false, dpiAwaitingConfirmation: Bool = false,
                isDraining: Bool = false, cancelled: Set<String> = [], previousReadings: [String: CapabilitySample] = [:]) {
        self.reading = reading; self.isSuspended = isSuspended
        self.dpiBusy = dpiBusy; self.dpiAwaitingConfirmation = dpiAwaitingConfirmation
        self.isDraining = isDraining; self.cancelled = cancelled; self.previousReadings = previousReadings
    }
}

public struct DeviceCapability: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let implementation: CapabilityImplementation
    public let evidence: AdapterFeatureEvidence
    /// Availability is descriptive. Services still enforce their own adapter/confirmation gates.
    public let routeAvailable: Bool
    public let session: CapabilitySession
}

public struct AdapterAssessment: Codable, Equatable, Sendable {
    public let adapterID: String?
    public let adapterName: String
    public let connectionEvidence: String
    public let sourceURL: URL?
    public let interfaceMatched: Bool
    public let firmwareScope: String
    public let dataOrigin: String
    public let capabilities: [DeviceCapability]

    public func capability(_ id: String) -> DeviceCapability? { capabilities.first { $0.id == id } }
    public var readingSummary: String {
        let values = capabilities.filter { $0.implementation == .implemented && $0.id != "discovery" && $0.id != "localProfiles" && $0.id != "dpiWrite" }
        if values.contains(where: { $0.session.state == .suspended }) { return "读取已暂停" }
        if values.contains(where: { $0.session.state == .waiting }) { return "等待上次操作结束" }
        if values.contains(where: { $0.session.state == .reading }) { return "正在读取" }
        let hasValue = values.contains { $0.session.state == .succeeded }
        let hasFailure = values.contains { $0.session.state == .failed }
        if hasValue && hasFailure { return "部分状态已取得" }
        if hasFailure { return "本次读取失败" }
        if hasValue { return "状态已取得" }
        if values.contains(where: { $0.session.state == .cancelled }) { return "读取已取消" }
        return interfaceMatched ? "尚未读取" : "仅读取系统属性"
    }
}

/// A pure evidence/status projection shared by UI, menu, CLI and diagnostic export.
/// It never discovers devices, executes reports or promotes synthetic results to hardware evidence.
public enum AdapterCatalog {
    /// UI reference list includes reviewed adapters absent from the pinned upstream model table.
    /// RazerModelCatalog remains unchanged and neither list grants device access.
    public static let modelEntries: [RazerModelReference] = {
        var entries = RazerModelCatalog.entries
        for manifest in AdapterManifestCatalog.all where manifest.vendorIDs == [0x1532] && manifest.transports.contains("USB") {
            for pid in manifest.productIDs where !entries.contains(where: { $0.productID == pid }) {
                entries.append(.init(productID: pid, name: "Razer \(manifest.name)", kind: manifest.deviceKind))
            }
        }
        return entries.sorted { $0.productID < $1.productID }
    }()

    public static let featureTitles = [
        ("discovery", "设备信息与接口枚举"), ("firmware", "固件查询"),
        ("dpi", "DPI 读取"), ("dpiWrite", "当前 DPI 设置"), ("stages", "DPI 档位读取"),
        ("polling", "回报率配置读取"), ("pollingWrite", "回报率设置"), ("rgb", "RGB 亮度 / 灯效"),
        ("battery", "电池电量"), ("charging", "充电状态"),
        ("hardwareMapping", "硬件按键映射 / Fn"), ("systemMapping", "系统重映射 / 宏"),
        ("localProfiles", "本地 DPI 档案"), ("onboardProfiles", "板载配置 / 自动恢复")
    ]

    public static func assess(_ device: DeviceInfo, battery: BatteryReading? = nil, telemetry: MouseTelemetry? = nil,
                              systemBattery: SystemBatteryReading? = nil, polling: MousePollingReading? = nil,
                              charging: MouseChargingReading? = nil, keyboardBattery: KeyboardPowerReading? = nil,
                              keyboardCharging: KeyboardPowerReading? = nil, activity: CapabilityActivity = .init(),
                              dpiWrite: MouseDPIWriteResult? = nil, simulation: Bool = false) -> AdapterAssessment {
        let manifest = AdapterManifestCatalog.manifest(for: device)
        let backends = DeviceReadRegistry.backends(for: device)
        let matched = manifest.map { backends.map(\.rawValue).contains($0.id) } ?? false
        let battery = battery.flatMap { $0.matches(device) ? $0 : nil }
        let mouseInterface = MouseReadService.interfaceID(for: device)
        let mouse = telemetry.flatMap { $0.deviceID == device.id && $0.interfaceID != nil && $0.interfaceID == mouseInterface ? $0 : nil }
        let polling = polling.flatMap { $0.deviceID == device.id && $0.interfaceID != nil && $0.interfaceID == mouseInterface ? $0 : nil }
        let charging = charging.flatMap { $0.deviceID == device.id && $0.interfaceID != nil && $0.interfaceID == mouseInterface ? $0 : nil }
        let keyboardBattery = keyboardBattery.flatMap { $0.matches(device, field: .battery) ? $0 : nil }
        let keyboardCharging = keyboardCharging.flatMap { $0.matches(device, field: .charging) ? $0 : nil }
        let system = systemBattery.flatMap { $0.matches(device) ? $0 : nil }
        let write = dpiWrite.flatMap { $0.deviceID == device.id && $0.interfaceID == mouseInterface ? $0 : nil }
        let capabilities = featureTitles.map { id, title -> DeviceCapability in
            var evidence = manifest?.feature(id) ?? AdapterFeatureEvidence(id: id, implementation: .notImplemented,
                level: .notAssessed, scope: "此版本未实现；不能据此判断硬件本身不支持。", records: [], samples: [])
            if id == "discovery" {
                evidence = .init(id: id, implementation: .implemented, level: .softwareTested,
                    scope: "读取系统已发布属性并监听匹配/移除通知；不证明无线外设在线。", records: ["docs/VALIDATION.md"], samples: [])
            }
            if id == "battery", manifest?.id == DeviceReadBackend.macOSBluetoothBattery.rawValue,
               device.vendorID == 0x068E, device.productID == 0x00D5 {
                evidence = .init(id: id, implementation: .implemented, level: .hardwareValidated,
                    scope: "BSK MOBILE 此 VID/PID 曾取得系统缓存电量；不是直接设备测量，也不代表其他蓝牙型号。",
                    records: ["docs/SYSTEM_BATTERY.md"], samples: evidence.samples)
            }
            let implemented = evidence.implementation == .implemented
            let available = implemented && (id == "discovery" || id == "localProfiles" || matched)
            var session: CapabilitySession
            if id == "discovery" {
                session = .init(.succeeded, source: "macOS HID 属性", detail: "系统已发布 \(device.interfaces.count) 个 HID 接口；未执行私有查询。")
            } else if !implemented {
                session = .init(.unavailable, detail: evidence.scope)
            } else if id == "localProfiles" {
                session = .init(.localOnly, source: "本地 JSON", detail: "选择只填入编辑器；应用设备设置仍需明确确认。")
            } else if activity.isSuspended {
                session = .init(.suspended, detail: "睡眠后清理读数；唤醒后需要重新手动读取。")
            } else if !matched {
                session = .init(.unavailable, detail: "未找到唯一符合已审查指纹的接口；不会尝试其他接口或命令。")
            } else if activity.isDraining {
                session = .init(.waiting, detail: "上次操作已失效，底层请求尚未返回；结束后可手动重试。")
            } else if id == "dpiWrite" {
                if activity.dpiBusy { session = .init(.working, detail: "DPI 检查或应用进行中；以最终读回为准。") }
                else if activity.dpiAwaitingConfirmation { session = .init(.awaitingConfirmation, detail: "检查已完成，尚需用户确认；此状态不授予写入许可。") }
                else if let write {
                    session = .init(write.outcome == .verified ? .succeeded : write.outcome == .uncertain ? .unconfirmed : .notRequested,
                        at: write.completedAt, source: simulation ? "模拟控制服务" : "设备控制结果", detail: write.message)
                } else { session = .init(.notRequested, detail: "检查、明确确认、一次性许可和完整读回；不会自动写入。") }
            } else if activity.reading.contains(id) {
                session = .init(.reading, detail: "等待本次查询完成。")
            } else if activity.cancelled.contains(id) {
                session = .init(.cancelled, failureKind: .cancelled, detail: "本次结果已丢弃；可手动重新读取。")
            } else {
                let source = simulation ? "模拟服务 · 非硬件证据" : "设备 Feature Report"
                switch id {
                case "battery" where battery != nil:
                    let value = battery!
                    session = result(valid: value.isValid, at: value.acquiredAt,
                        source: simulation ? "模拟服务 · 非硬件证据" : value.source.title,
                        issue: value.issue?.message, kind: value.issue?.kind)
                case "battery" where system != nil:
                    let value = system!
                    let valid = value.percent.map { (0...100).contains($0) } == true && value.source != nil
                    session = result(valid: valid, at: value.acquiredAt, source: simulation ? source : value.source?.title,
                        issue: value.issue, kind: value.failureKind,
                        success: "系统缓存电量；这里记录应用取得时间，设备采样时间未知。")
                case "battery" where keyboardBattery != nil:
                    let value = keyboardBattery!
                    session = result(valid: value.hasValue, at: value.readAt, source: source, issue: value.issue?.message, kind: value.issue?.kind)
                case "charging" where keyboardCharging != nil:
                    let value = keyboardCharging!
                    session = result(valid: value.hasValue, at: value.readAt, source: source, issue: value.issue?.message, kind: value.issue?.kind)
                case "battery", "dpi", "stages":
                    if let mouse {
                        let field = id == "battery" ? "battery" : "dpi"
                        let issue = mouse.issues.first { $0.field == field || $0.field == "interface" }
                        let valid = id == "battery" ? mouse.batteryPercent.map { (0...100).contains($0) } == true : mouse.dpi != nil
                        if !valid, issue == nil, !mouse.issues.isEmpty {
                            session = .init(.notRead, at: mouse.readAt, detail: "前一字段查询失败，本字段未取得结果；不填入默认值。")
                        } else {
                            session = result(valid: valid, at: mouse.readAt, source: source, issue: issue?.message, kind: issue?.kind)
                        }
                    } else { session = unread() }
                case "polling":
                    if let polling {
                        session = result(valid: polling.configuredHertz != nil, at: polling.readAt, source: source,
                            issue: polling.issue?.message, kind: polling.issue?.kind, success: "配置值已取得，不是实际输入频率测量。")
                    } else { session = unread() }
                case "charging":
                    if let charging {
                        session = result(valid: charging.state != nil, at: charging.readAt, source: source, issue: charging.issue?.message, kind: charging.issue?.kind)
                    } else { session = unread() }
                default: session = unread()
                }
            }
            let value: String?
            switch id {
            case "battery": value = (battery?.percent ?? system?.percent ?? keyboardBattery?.batteryPercent ?? mouse?.batteryPercent).map { "\($0)%" }
            case "charging": value = (keyboardCharging?.chargingState ?? charging?.state)?.title
            case "polling": value = polling?.configuredHertz.map { "\($0) Hz" }
            case "dpi": value = mouse?.dpi.map { "X \($0.current.x) / Y \($0.current.y) DPI" }
            case "stages": value = mouse?.dpi.map { "\($0.stages.count) 档 · 当前第 \($0.activeStage) 档" }
            default: value = nil
            }
            let previous = implemented && matched && !activity.isSuspended && session.state != .succeeded
                ? activity.previousReadings[id] : nil
            session = .init(session.state, at: session.at, source: session.source, failureKind: session.failureKind,
                            detail: session.detail, value: session.state == .succeeded ? value : nil, previous: previous)
            return .init(id: id, title: title, implementation: evidence.implementation, evidence: evidence,
                         routeAvailable: available, session: session)
        }
        let connection: String
        if device.isVirtual { connection = "驱动发布的虚拟 HID；Transport 不代表物理连接，仅供诊断。" }
        else if let manifest, manifest.fingerprint != nil {
            connection = matched ? "控制接口符合已审查指纹；USB 接收器存在不保证无线外设在线。"
                : "型号与 USB 连接已识别，但控制接口不匹配或存在歧义；私有查询未启用。"
        } else if manifest != nil { connection = "使用系统蓝牙电量后端；按精确身份关联，不套用 USB 私有协议。" }
        else { connection = "仅显示系统属性与型号参考；此连接没有可执行私有查询适配器。" }
        return .init(adapterID: manifest?.id, adapterName: manifest?.name ?? (device.isVirtual ? "虚拟 HID · 仅诊断" : "通用 HID · 仅系统属性"),
            connectionEvidence: connection, sourceURL: manifest?.sources.first?.url ?? device.modelReference.map { _ in RazerModelCatalog.sourceURL },
            interfaceMatched: matched, firmwareScope: manifest?.firmwareScope ?? "真实固件未查询；版本属性不等同于固件版本。",
            dataOrigin: simulation ? "simulation-only; not hardware evidence" : "current-session; historical evidence is scoped separately",
            capabilities: capabilities)
    }

    private static func unread() -> CapabilitySession {
        .init(.notRead, detail: "手动查询后显示结果；启动、刷新与热插拔不会触发查询。")
    }

    private static func result(valid: Bool, at: Date, source: String?, issue: String?, kind: ReadFailureKind?,
                               success: String = "仅代表读取时的状态，不表示持续在线。") -> CapabilitySession {
        if let issue { return .init(.failed, at: at, failureKind: kind, detail: issue) }
        if let kind { return .init(.failed, at: at, failureKind: kind, detail: kind.title) }
        if valid { return .init(.succeeded, at: at, source: source, detail: success) }
        return .init(.failed, at: at, failureKind: .invalidData, detail: "本次没有有效值；未采用默认数据。")
    }
}
