#if DEBUG
import Combine
import Foundation

/// Development fixtures only. Every dependency is explicitly replaced; no live fallback.
public enum OfflineScenario: String, CaseIterable, Identifiable, Sendable {
    case empty, mouse, keyboard, bluetooth, unknown, twinMice, unread, reading
    case partial, timeout, permissionDenied, receiverOnly, retryFailed
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .empty: "无设备"
        case .mouse: "鼠标 · 完整读数"
        case .keyboard: "键盘 · 0% 电量"
        case .bluetooth: "蓝牙 · 系统缓存"
        case .unknown: "未知型号 · 长名称"
        case .twinMice: "两台同型号鼠标"
        case .unread: "鼠标 · 尚未读取"
        case .reading: "鼠标 · 等待响应"
        case .partial: "鼠标 · 部分成功"
        case .timeout: "鼠标 · 超时"
        case .permissionDenied: "鼠标 · 权限失败"
        case .receiverOnly: "仅接收器 · 状态未知"
        case .retryFailed: "鼠标 · 刷新失败与历史值"
        }
    }
}

public enum OfflineDPIOutcome: String, CaseIterable, Identifiable, Sendable {
    case verified, notSent, mismatch, expired
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .verified: "模拟成功"
        case .notSent: "模拟未发送"
        case .mismatch: "模拟读回不一致"
        case .expired: "模拟计划过期"
        }
    }
}

@MainActor
private final class OfflineDiscovery: HIDDiscovering {
    var onChange: (([HIDInterface], String) -> Void)?
    var onError: ((String) -> Void)?
    var interfaces: [HIDInterface] = []
    func start() { refresh() }
    func refresh() { onChange?(interfaces, "模拟场景：属性刷新") }
    func stop() {}
}

/// Used by both the native developer app and regression tests. Synthetic values are
/// model-level fixtures, not captured reports or evidence of hardware compatibility.
@MainActor
public final class OfflineScenarioSession: ObservableObject {
    public let manager: DeviceManager
    public let profiles: ProfileService
    public let storageDirectory: URL
    @Published public private(set) var scenario: OfflineScenario = .empty
    @Published public private(set) var isDisconnected = false
    private let discovery: OfflineDiscovery
    let services: OfflineServices
    private var generation = 0
    private var connectionRevision: UInt64 = 0

    public init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RazerLite-Scenarios-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        storageDirectory = directory
        let discovery = OfflineDiscovery()
        let services = OfflineServices()
        self.discovery = discovery
        self.services = services
        manager = DeviceManager(discovery: discovery, mouseReader: OfflineMouseReader(services: services),
            dpiController: OfflineDPIController(services: services),
            systemBatteryReader: OfflineSystemReader(services: services),
            pollingReader: OfflinePollingReader(services: services),
            chargingReader: OfflineChargingReader(services: services),
            keyboardPowerReader: OfflineKeyboardReader(services: services), batteryReader: OfflineBatteryReader(services: services), isSimulation: true)
        profiles = ProfileService(storageURL: directory.appendingPathComponent("profiles.json"))
    }

    isolated deinit {
        manager.stop()
        try? FileManager.default.removeItem(at: storageDirectory)
    }

    public func load(_ next: OfflineScenario) async {
        generation += 1
        let token = generation
        manager.stop()
        manager.clearError()
        await services.configure(next == .retryFailed ? .mouse : next)
        guard token == generation else { return }
        scenario = next
        isDisconnected = false
        connectionRevision += 1
        discovery.interfaces = Self.interfaces(for: next, revision: connectionRevision)
        manager.start()
        if let mouse = manager.devices.first(where: { MouseReadService.canRead($0) }), profiles.profiles.isEmpty {
            do { _ = try profiles.save(name: "模拟 · 办公", for: mouse, x: 1600, y: 1600) }
            catch { manager.reportError("模拟档案创建失败：\(error.localizedDescription)") }
        }
        guard next != .unread && next != .empty && next != .unknown else { return }
        // Publish through the same manager lifecycle as ordinary user reads.
        for device in manager.devices {
            guard token == generation else { return }
            if MouseReadService.canRead(device) {
                await manager.readMouseState(for: device.id)
                guard token == generation else { return }
                if next == .mouse || next == .twinMice || next == .retryFailed {
                    await manager.readPollingRate(for: device.id)
                    guard token == generation else { return }
                    await manager.readChargingState(for: device.id)
                }
            } else if BlackWidowLowProfileAdapter.controlInterface(in: device) != nil {
                await manager.readKeyboardPower(for: device.id, field: .battery)
                guard token == generation else { return }
                await manager.readKeyboardPower(for: device.id, field: .charging)
            } else if SystemBatteryService.canRead(device) {
                await manager.readSystemBattery(for: device.id)
            }
        }
        if next == .retryFailed, token == generation, let device = manager.devices.first {
            await services.configure(.timeout)
            await manager.readChargingState(for: device.id)
        }
    }

    public func finishReads() async { await services.releaseReads() }
    public func setDPIOutcome(_ value: OfflineDPIOutcome) async { await services.setDPIOutcome(value) }

    public func disconnect() {
        generation += 1
        isDisconnected = true
        discovery.interfaces = []
        discovery.refresh()
    }

    /// A new session identity; reconnect never reapplies settings or cached readings.
    public func reconnect() {
        generation += 1
        connectionRevision += 1
        isDisconnected = false
        discovery.interfaces = Self.interfaces(for: scenario, revision: connectionRevision)
        discovery.refresh()
    }

    private static func interfaces(for scenario: OfflineScenario, revision: UInt64) -> [HIDInterface] {
        let base: UInt64 = 9_000_000 + revision * 100
        func interface(_ offset: UInt64, pid: Int, name: String, number: Int, page: Int, usage: Int,
                       input: Int, feature: Int, bluetooth: Bool = false) -> HIDInterface {
            HIDInterface(id: base + offset, vendorID: bluetooth ? 0x068E : 0x1532, productID: pid,
                product: name, manufacturer: "模拟 Razer", transport: bluetooth ? "Bluetooth Low Energy" : "USB",
                locationID: nil, versionNumber: nil, usbDeviceID: bluetooth ? nil : base + offset / 10,
                usbInterfaceNumber: bluetooth ? nil : number, usbDeviceRelease: nil,
                primaryUsagePage: page, primaryUsage: usage, usages: [HIDUsage(page: page, usage: usage)],
                maxInputReportSize: input, maxOutputReportSize: 0, maxFeatureReportSize: feature,
                registryClass: "OfflineFixture", observedDrivers: [], isVirtual: false)
        }
        func mouse(_ offset: UInt64) -> HIDInterface {
            interface(offset, pid: 0x00E6, name: "Razer Viper V4 Pro", number: 3, page: 12, usage: 1, input: 0, feature: 90)
        }
        switch scenario {
        case .empty: return []
        case .keyboard:
            return [interface(10, pid: 0x02D2, name: "Razer BlackWidow V4 Low-profile TKL HyperSpeed",
                              number: 2, page: 1, usage: 2, input: 8, feature: 90)]
        case .bluetooth:
            return [interface(10, pid: 0x00D5, name: "BSK MOBILE", number: 0, page: 1, usage: 2, input: 8, feature: 0, bluetooth: true)]
        case .unknown:
            return [interface(10, pid: 0xFFFF,
                name: "Razer Unknown Peripheral — A deliberately long device name for layout and accessibility checks",
                number: 0, page: 0xFF00, usage: 1, input: 8, feature: 0)]
        case .twinMice: return [mouse(10), mouse(20)]
        default: return [mouse(10)]
        }
    }
}

struct OfflineReadContext: Sendable {
    let scenario: OfflineScenario
    let dpi: MouseDPIState
    var issue: MouseReadIssue? {
        switch scenario {
        case .timeout, .receiverOnly:
            MouseReadIssue(field: "battery", message: "模拟：未取得响应；不能据此判断外设是否在线。", kind: .timeout)
        case .permissionDenied:
            MouseReadIssue(field: "battery", message: "模拟：系统拒绝访问查询接口。", kind: .permissionDenied)
        case .partial:
            MouseReadIssue(field: "dpi", message: "模拟：电量已取得，DPI 响应校验失败。", kind: .protocolMismatch)
        default: nil
        }
    }
}

/// All fake I/O terminates here. No transport, process, registry or network APIs.
actor OfflineServices {
    private var scenario: OfflineScenario = .empty
    private var outcome: OfflineDPIOutcome = .verified
    private var dpiByDevice: [String: MouseDPIState] = [:]
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var operations: [String] = []
    private static var baseline: MouseDPIState {
        MouseDPIState(activeStage: 3, stages: [MouseDPIStage(x: 400, y: 400), MouseDPIStage(x: 800, y: 800),
            MouseDPIStage(x: 2800, y: 3000), MouseDPIStage(x: 6400, y: 6400), MouseDPIStage(x: 12800, y: 12800)])
    }
    func configure(_ value: OfflineScenario) {
        releaseReads()
        scenario = value
        dpiByDevice.removeAll()
    }
    func releaseReads() {
        let waiting = pending
        pending.removeAll()
        waiting.forEach { $0.resume() }
    }
    func setDPIOutcome(_ value: OfflineDPIOutcome) { outcome = value }
    func waitForPendingRead() async {
        if !pending.isEmpty { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }
    func read(_ device: DeviceInfo, operation: String) async -> OfflineReadContext {
        let context = OfflineReadContext(scenario: scenario, dpi: dpiByDevice[device.id] ?? Self.baseline)
        operations.append("\(operation):\(device.id)")
        if scenario == .reading {
            await withCheckedContinuation {
                pending.append($0)
                let waiters = readWaiters
                readWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        return context
    }
    func prepare(_ device: DeviceInfo, x: Int, y: Int) throws -> MouseDPIPlan {
        operations.append("prepare:\(device.id)")
        guard let interface = ViperV4Adapter.controlInterface(in: device) else { throw DeviceQueryError.unavailableInterface }
        let before = dpiByDevice[device.id] ?? Self.baseline
        let after = try ViperV4DPIProtocol.replacingCurrent(in: before, x: x, y: y)
        guard before != after else { throw DeviceQueryError.malformed("模拟：目标未变化。") }
        return MouseDPIPlan(deviceID: device.id, deviceName: "模拟 · \(device.product)", before: before, after: after,
            interface: interface, issuedAt: outcome == .expired ? .now.advanced(by: .seconds(-61)) : .now)
    }
    func apply(_ plan: MouseDPIPlan) -> MouseDPIWriteResult {
        operations.append("apply:\(plan.deviceID)")
        guard plan.isUsable, outcome != .notSent, plan.permit.consume() else {
            plan.invalidate()
            return MouseDPIWriteResult(deviceID: plan.deviceID, interfaceID: plan.interface.id, completedAt: Date(),
                outcome: .notSent, attemptedWrite: false, readback: nil, message: "模拟：计划失效或请求未发送。没有设备通信。")
        }
        if outcome == .mismatch {
            return MouseDPIWriteResult(deviceID: plan.deviceID, interfaceID: plan.interface.id, completedAt: Date(),
                outcome: .uncertain, attemptedWrite: true, readback: plan.before, message: "模拟：读回不一致，不自动重试。没有设备通信。")
        }
        dpiByDevice[plan.deviceID] = plan.after
        return MouseDPIWriteResult(deviceID: plan.deviceID, interfaceID: plan.interface.id, completedAt: Date(),
            outcome: .verified, attemptedWrite: true, readback: plan.after, message: "模拟：目标与假读回一致。没有设备通信。")
    }
}

private struct OfflineBatteryReader: BatteryReadingService {
    let services: OfflineServices
    func read(_ device: DeviceInfo) async -> BatteryReading {
        let value = await services.read(device, operation: "battery-only")
        return .init(deviceID: device.id, interfaceIDs: device.interfaces.map(\.id).sorted(), backend: .viperV4USB,
            percent: value.issue == nil ? 15 : nil, acquiredAt: .now, source: .device, issue: value.issue)
    }
}
private struct OfflineMouseReader: MouseStatusReading {
    let services: OfflineServices
    func read(_ device: DeviceInfo) async -> MouseTelemetry {
        let value = await services.read(device, operation: "mouse")
        return MouseTelemetry(deviceID: device.id, interfaceID: MouseReadService.interfaceID(for: device), readAt: Date(),
            batteryPercent: value.issue == nil ? (device.interfaces[0].id % 100 == 20 ? 38 : 76) : value.scenario == .partial ? 76 : nil,
            dpi: value.issue == nil ? value.dpi : nil, issues: value.issue.map { [$0] } ?? [])
    }
}
private struct OfflinePollingReader: MousePollingReadingService {
    let services: OfflineServices
    func read(_ device: DeviceInfo) async -> MousePollingReading {
        let value = await services.read(device, operation: "polling")
        return MousePollingReading(deviceID: device.id, interfaceID: MouseReadService.interfaceID(for: device),
            readAt: Date(), configuredHertz: value.issue == nil ? 1000 : nil, issue: value.issue)
    }
}
private struct OfflineChargingReader: MouseChargingReadingService {
    let services: OfflineServices
    func read(_ device: DeviceInfo) async -> MouseChargingReading {
        let value = await services.read(device, operation: "charging")
        return MouseChargingReading(deviceID: device.id, interfaceID: MouseReadService.interfaceID(for: device),
            readAt: Date(), state: value.issue == nil ? .notCharging : nil, issue: value.issue)
    }
}
private struct OfflineKeyboardReader: KeyboardPowerReadingService {
    let services: OfflineServices
    func read(_ device: DeviceInfo, field: KeyboardPowerField) async -> KeyboardPowerReading {
        _ = await services.read(device, operation: "keyboard-\(field.rawValue)")
        return KeyboardPowerReading(deviceID: device.id, interfaceID: BlackWidowLowProfileAdapter.controlInterface(in: device)?.id,
            field: field, readAt: Date(), batteryPercent: field == .battery ? 0 : nil,
            chargingState: field == .charging ? .charging : nil, issue: nil)
    }
}
private struct OfflineSystemReader: SystemBatteryReadingService {
    let services: OfflineServices
    func read(_ device: DeviceInfo) async -> SystemBatteryReading {
        _ = await services.read(device, operation: "system-battery")
        return SystemBatteryReading(deviceID: device.id, interfaceIDs: device.interfaces.map(\.id).sorted(), acquiredAt: Date(),
            percent: 0, source: .macOSBluetoothSnapshot, issue: nil)
    }
}
private struct OfflineDPIController: MouseDPIControlling {
    let services: OfflineServices
    func prepare(_ device: DeviceInfo, x: Int, y: Int) async throws -> MouseDPIPlan {
        try await services.prepare(device, x: x, y: y)
    }
    func apply(_ plan: MouseDPIPlan) async -> MouseDPIWriteResult { await services.apply(plan) }
}
#endif
