import Foundation

public enum CapabilityImplementation: String, Codable, Sendable {
    case implemented, notImplemented
    public var title: String { self == .implemented ? "已实现" : "未实现" }
}

/// Historical evidence is independent of a result in the current connection.
public enum CapabilityEvidenceLevel: String, Codable, Sendable {
    case notAssessed, sourceReviewed, softwareTested, simulationTested, hardwareValidated
    public var title: String {
        switch self {
        case .notAssessed: "尚无适配证据"
        case .sourceReviewed: "公开实现已审查"
        case .softwareTested: "软件测试通过"
        case .simulationTested: "模拟协议通过"
        case .hardwareValidated: "有指定环境真机记录"
        }
    }
}

public struct AdapterSource: Codable, Equatable, Sendable {
    public let url: URL
    public let revision: String?
    public let scope: String
}

public struct AdapterFeatureEvidence: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let implementation: CapabilityImplementation
    public let level: CapabilityEvidenceLevel
    public let scope: String
    /// Repository-relative evidence documents, never samples used as live readings.
    public let records: [String]
    public let samples: [String]
}

public struct AdapterInterfaceFingerprint: Codable, Equatable, Sendable {
    public let interfaceNumber: Int
    public let usagePage: Int
    public let usage: Int
    public let inputBytes: Int
    public let outputBytes: Int
    public let featureBytes: Int

    func matches(_ interface: HIDInterface) -> Bool {
        !interface.isVirtual && interface.usbDeviceID != nil
            && interface.usbInterfaceNumber == interfaceNumber
            && interface.primaryUsagePage == usagePage && interface.primaryUsage == usage
            && interface.maxInputReportSize == inputBytes && interface.maxOutputReportSize == outputBytes
            && interface.maxFeatureReportSize == featureBytes
    }

    public var title: String {
        "interface \(interfaceNumber) · Usage \(hexID(usagePage))/\(hexID(usage)) · I/O/F \(inputBytes)/\(outputBytes)/\(featureBytes)"
    }
}

/// Built-in reviewed descriptions only. No packet templates, scripts or imported executable adapters.
/// Finding a manifest does not open a device or authorize a write.
public struct DeviceAdapterManifest: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let deviceKind: RazerDeviceKind
    public let vendorIDs: [Int]
    public let productIDs: [Int]
    public let transports: [String]
    public let transportPrefix: String?
    public let fingerprint: AdapterInterfaceFingerprint?
    public let firmwareScope: String
    public let sources: [AdapterSource]
    public let features: [AdapterFeatureEvidence]

    public func matchesIdentity(_ device: DeviceInfo) -> Bool {
        if id == "reclusa-mini65-usb-lighting" {
            return ReclusaLightingAdapter.controlInterface(in: device) != nil
        }
        guard device.isRazer, !device.isVirtual, !device.interfaces.isEmpty else { return false }
        return device.interfaces.allSatisfy { interface in
            vendorIDs.contains(interface.vendorID ?? -1) && (productIDs.isEmpty || productIDs.contains(interface.productID ?? -1))
                && (transports.contains(interface.transport ?? "")
                    || transportPrefix.map { interface.transport?.hasPrefix($0) == true } == true)
        }
    }

    func controlInterface(in device: DeviceInfo) -> HIDInterface? {
        guard matchesIdentity(device), let fingerprint else { return nil }
        let candidates = device.interfaces.filter { fingerprint.matches($0) }
        return candidates.count == 1 ? candidates[0] : nil
    }

    public func feature(_ id: String) -> AdapterFeatureEvidence? { features.first { $0.id == id } }
}

public enum AdapterManifestCatalog {
    private static func feature(_ id: String, _ level: CapabilityEvidenceLevel, _ scope: String,
                                _ records: [String], samples: [String] = [], implemented: Bool = true) -> AdapterFeatureEvidence {
        .init(id: id, implementation: implemented ? .implemented : .notImplemented,
              level: level, scope: scope, records: records, samples: samples)
    }

    public static let viper = DeviceAdapterManifest(
        id: DeviceReadBackend.viperV4USB.rawValue, name: "Viper V4 Pro · USB", deviceKind: .mouse, vendorIDs: [0x1532], productIDs: [0x00E6],
        transports: ["USB"], transportPrefix: nil, fingerprint: .init(interfaceNumber: 3, usagePage: 0x0C, usage: 1, inputBytes: 0, outputBytes: 0, featureBytes: 90),
        firmwareScope: "本机真实固件版本未查询；公开抓包标注 1.1.1.0，不能据此限制或保证本机固件兼容。",
        sources: [.init(url: URL(string: "https://github.com/OpenMouse-Project/mouse-protocol/blob/54c68c69bbd0bcd750cf10a4e439148e634c02db/src/drivers/razer/viper-v4-pro-hid.ts")!,
                        revision: "54c68c69bbd0bcd750cf10a4e439148e634c02db", scope: "00E6 查询、DPI 与充电协议依据；非其他连接方式的保证")],
        features: [
            feature("battery", .hardwareValidated, "本机 00E6 USB 电量及独立电量会话已有读回记录；自动刷新与长期稳定性未验收，其他设备及固件不继承结论。", ["docs/READ_ONLY_PROTOCOL.md", "docs/PHASE0102_BATTERY.md", "docs/PHASE0113_READ_VALIDATION.md"], samples: ["Tests/RazerLiteCoreTests/ViperReadProtocolTests.swift", "Tests/RazerLiteCoreTests/BatteryReadingTests.swift"]),
            feature("dpi", .hardwareValidated, "历史本机 X/Y DPI 读回。", ["docs/READ_ONLY_PROTOCOL.md"], samples: ["Tests/RazerLiteCoreTests/ViperReadProtocolTests.swift"]),
            feature("stages", .hardwareValidated, "历史本机全部 DPI 档位读回。", ["docs/READ_ONLY_PROTOCOL.md"], samples: ["Tests/RazerLiteCoreTests/ViperReadProtocolTests.swift"]),
            feature("dpiWrite", .hardwareValidated, "历史当前档位 X/Y 修改有一次明确授权写入与完整读回记录；0.11.0 多档修改仅模拟通过，待真机验收。跨重启持久性未确认。", ["docs/DPI_WRITE.md", "docs/PHASE011_DPI_STAGES.md"], samples: ["Tests/RazerLiteCoreTests/MouseDPIServiceTests.swift"]),
            feature("pollingWrite", .simulationTested, "00E6 USB 专用命令与模拟协议通过；设置尚未真机验证，RF 重配可能短暂影响连接。", ["docs/PHASE0111_POLLING_CONTROL.md"], samples: ["Tests/RazerLiteCoreTests/PollingRateControlTests.swift"]),
            feature("polling", .hardwareValidated, "历史本机回报率配置读回，不是实际输入频率。", ["docs/PHASE06_PROTOCOL_REVIEW.md"], samples: ["Tests/RazerLiteCoreTests/PollingRateReadServiceTests.swift"]),
            feature("charging", .hardwareValidated, "本机 00E6 USB 查询曾返回未充电；充电中、状态切换和断连重连未验收，不证明电缆连接或持续在线。", ["docs/PHASE07_CHARGING_READ.md", "docs/PHASE0113_READ_VALIDATION.md"], samples: ["Tests/RazerLiteCoreTests/ChargingReadServiceTests.swift"]),
            feature("localProfiles", .softwareTested, "本地 DPI 档案；选择不修改设备。", ["docs/PHASE091_LOCAL_LIBRARY.md"])
        ])

    public static let keyboard = DeviceAdapterManifest(
        id: DeviceReadBackend.blackWidowLowProfileUSB.rawValue, name: "BlackWidow Low-profile TKL · USB 试验适配", deviceKind: .keyboard,
        vendorIDs: [0x1532], productIDs: [0x02D2], transports: ["USB"], transportPrefix: nil,
        fingerprint: .init(interfaceNumber: 2, usagePage: 1, usage: 2, inputBytes: 8, outputBytes: 0, featureBytes: 90),
        firmwareScope: "本机固件未查询；固定补丁与模拟测试不等于 macOS 真机兼容。",
        sources: [.init(url: URL(string: "https://github.com/openrazer/openrazer/blob/54f9f686ba8c2162a1232c85f98486f4810a258e/driver/razerkbd_driver.c")!,
                        revision: "54f9f686ba8c2162a1232c85f98486f4810a258e", scope: "PR #2912 的 02D2 interface 2 / 9F；不移植模式设置")],
        features: [
            feature("battery", .simulationTested, "独立电量试读，待 macOS 真机验收。", ["docs/PHASE08_KEYBOARD_POWER.md"], samples: ["Tests/RazerLiteCoreTests/KeyboardPowerTests.swift"]),
            feature("charging", .simulationTested, "独立充电试读，待 macOS 真机验收。", ["docs/PHASE08_KEYBOARD_POWER.md"], samples: ["Tests/RazerLiteCoreTests/KeyboardPowerTests.swift"]),
            feature("rgb", .sourceReviewed, "公开驱动有型号线索；本应用未实现此键盘的灯光控制。", ["docs/PHASE08_KEYBOARD_POWER.md"], implemented: false),
            feature("polling", .sourceReviewed, "公开驱动有型号线索；本应用未实现此键盘的回报率查询。", ["docs/PHASE08_KEYBOARD_POWER.md"], implemented: false)
        ])

    public static let reclusaLighting = DeviceAdapterManifest(
        id: "reclusa-mini65-usb-lighting", name: "Reclusa Mini 65% · USB 接收器", deviceKind: .keyboard,
        vendorIDs: [0x1532], productIDs: [0x02F5], transports: ["USB"], transportPrefix: nil,
        fingerprint: .init(interfaceNumber: 3, usagePage: 0x0C, usage: 1, inputBytes: 0, outputBytes: 0, featureBytes: 90),
        firmwareScope: "本机固件未查询；02F5 的亮度读回及用户观察已验证。电源与回报率分别记录验证状态；其他连接、固件及跨重启持久性不继承。",
        sources: [
            .init(url: URL(string: "https://apps.razer.com/synapse/products/756/mw/main.4ac4b05541bb1859fa0e.js")!,
                  revision: "sha256:5e7adbd276b0da6a4a4f06c6dbc7d7b07400b3fd7fd17eb8eea54a7948b4923d", scope: "756/757/758 精确身份与 interface 3"),
            .init(url: URL(string: "https://apps.razer.com/synapse/products/756/mw/rzDevice25.40fe6f559bba152076d4.js")!,
                  revision: "sha256:9788a6b975de1b2eb771d167318b74f0d45359a6b0039ff7582af011e9632de3", scope: "灯区、亮度查询与设置的字段和响应"),
            .init(url: URL(string: "https://apps.razer.com/synapse/products/756/mw/rzDevice25DualLinkKeyboard.3b347518a00a88ca9641.js")!,
                  revision: "sha256:c0df14003004b0cd128aef0932667851c61e0f6bda7bdb4da77fddeadb33b1e8", scope: "02F5 接收器 DualLink 事务号"),
            .init(url: URL(string: "https://apps.razer.com/synapse/products/756/mw/6737.90f8e2e80827f3801f8e.js")!,
                  revision: "sha256:a8486d90275407cfc1c9e7b21b2017cc74a5720a5c7b6aa330c51bb3cd8d46db", scope: "连接工厂和 profile 1 亮度目标；不执行模式切换或板载同步")
        ], features: [
            feature("brightness", .hardwareValidated, "本机 02F5 在 2026-11-10T14:01:59Z 返回 region 5 / profile 1 / raw 255；只代表读取时的配置。", ["docs/KEYBOARD_LIGHTING.md"], samples: ["Tests/RazerLiteCoreTests/ReclusaBrightnessTests.swift"]),
            feature("brightnessWrite", .hardwareValidated, "本机 100%→50% 读回 raw127；用户确认实际灯光变化。实时滑块另经模拟测试，0%及断电保存待验收。", ["docs/KEYBOARD_LIGHTING.md", "docs/PHASE013_KEYBOARD_BASICS.md"], samples: ["Tests/RazerLiteCoreTests/LiveBrightnessTests.swift", "Tests/RazerLiteCoreTests/ManagerLiveBrightnessTests.swift"]),
            feature("battery", .hardwareValidated, "2026-11-10T14:53:52Z 本机02F5查询返回15%；只证明当时设备读数，不证明电量精度或其他固件。", ["docs/PHASE013_KEYBOARD_BASICS.md"], samples: ["Tests/RazerLiteCoreTests/ReclusaPowerTests.swift"]),
            feature("charging", .hardwareValidated, "2026-11-10T14:53:52Z 本机02F5返回未充电；充电中与状态切换尚待验收，其他码保留未知。", ["docs/PHASE013_KEYBOARD_BASICS.md"], samples: ["Tests/RazerLiteCoreTests/ReclusaPowerTests.swift"]),
            feature("polling", .hardwareValidated, "2026-11-10T14:53:52Z 本机02F5的profile1回报率配置返回1000Hz；不是实际输入频率测量，其他档位待验收。", ["docs/PHASE013_KEYBOARD_BASICS.md"], samples: ["Tests/RazerLiteCoreTests/ReclusaPollingTests.swift"]),
            feature("pollingWrite", .simulationTested, "明确确认后只修改profile1，单次00:40并读回；仅开放125/250/500/1000Hz，高档共享条件未适配。", ["docs/PHASE013_KEYBOARD_BASICS.md"], samples: ["Tests/RazerLiteCoreTests/ReclusaPollingTests.swift"])
        ])

    public static let bluetooth = DeviceAdapterManifest(
        id: DeviceReadBackend.macOSBluetoothBattery.rawValue, name: "Razer 蓝牙 HID · 系统电量", deviceKind: .unknown,
        vendorIDs: [0x1532, 0x068E], productIDs: [], transports: ["Bluetooth", "Bluetooth Low Energy"], transportPrefix: "Bluetooth", fingerprint: nil,
        firmwareScope: "仅使用 macOS 发布的属性，不查询设备固件或私有蓝牙协议。",
        sources: [.init(url: URL(string: "https://developer.apple.com/documentation/iokit/iohidmanager")!, revision: nil,
                        scope: "系统 HID 属性；电量缺失时按精确身份取得 macOS 蓝牙快照")],
        features: [feature("battery", .softwareTested, "系统属性与身份关联经过测试；是否发布电量由具体设备和 macOS 决定。", ["docs/SYSTEM_BATTERY.md"], samples: ["Tests/RazerLiteCoreTests/SystemBatteryTests.swift"])])

    public static let all: [DeviceAdapterManifest] = [viper, keyboard, reclusaLighting, bluetooth]

    public static func manifest(for device: DeviceInfo) -> DeviceAdapterManifest? {
        all.first { $0.matchesIdentity(device) }
    }
}
