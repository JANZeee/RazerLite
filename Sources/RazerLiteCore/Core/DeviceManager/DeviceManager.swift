import Combine
import Foundation
import OSLog

public struct DiagnosticLog: Identifiable, Sendable {
    public let id = UUID()
    public let time = Date()
    public let message: String
    public let isError: Bool
}

@MainActor
public final class DeviceManager: ObservableObject {
    public let isSimulation: Bool
    public let batteryObservations = PassthroughSubject<BatteryObservation, Never>()
    @Published public private(set) var batteryReadouts: [String: BatteryReading] = [:]
    @Published public private(set) var readingBatteryIDs: Set<String> = []
    private let batteryReader: any BatteryReadingService
    @Published public private(set) var devices: [DeviceInfo] = []
    @Published public private(set) var logs: [DiagnosticLog] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var isMonitoring = false
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var mouseReadouts: [String: MouseTelemetry] = [:]
    @Published public private(set) var pollingReadouts: [String: MousePollingReading] = [:]
    @Published public private(set) var readingPollingDeviceIDs: Set<String> = []
    @Published public private(set) var chargingReadouts: [String: MouseChargingReading] = [:]
    @Published public private(set) var readingChargingDeviceIDs: Set<String> = []
    @Published public private(set) var keyboardBatteryReadouts: [String: KeyboardPowerReading] = [:]
    @Published public private(set) var keyboardChargingReadouts: [String: KeyboardPowerReading] = [:]
    @Published public private(set) var readingKeyboardPowerIDs: Set<String> = []
    @Published public private(set) var systemBatteryReadings: [String: SystemBatteryReading] = [:]
    @Published public private(set) var readingSystemBatteryIDs: Set<String> = []
    @Published public private(set) var isSuspended = false
    @Published public private(set) var readingDeviceIDs: Set<String> = []
    @Published public private(set) var pendingDPIChanges: [String: MouseDPIPlan] = [:]
    @Published public private(set) var dpiBusyIDs: Set<String> = []
    @Published public private(set) var dpiErrors: [String: String] = [:]
    @Published public private(set) var dpiWriteResults: [String: MouseDPIWriteResult] = [:]
    public private(set) var discoveryReadyMilliseconds: Double?
    private let discovery: any HIDDiscovering
    private let mouseReader: any MouseStatusReading
    private let dpiController: any MouseDPIControlling
    private let systemBatteryReader: any SystemBatteryReadingService
    private let pollingReader: any MousePollingReadingService
    private let chargingReader: any MouseChargingReadingService
    private let keyboardPowerReader: any KeyboardPowerReadingService
    private let logger = Logger(subsystem: "local.RazerLite", category: "Discovery")
    private var interfaces: [HIDInterface] = []
    private let operations = DeviceOperationCoordinator()
    @Published public private(set) var drainingOperationIDs: Set<String> = []
    private var cancelledReadFields: [String: Set<String>] = [:]
    @Published public private(set) var lastSuccessfulReadings: [String: [String: CapabilitySample]] = [:]
    private var mouseReadingInterfaces: [String: HIDInterface] = [:]
    private var pollingReadingInterfaces: [String: HIDInterface] = [:]
    private var chargingReadingInterfaces: [String: HIDInterface] = [:]
    private var keyboardReadingInterfaces: [String: HIDInterface] = [:]
    private var dpiResultInterfaces: [String: HIDInterface] = [:]
    private var dpiRequests: [String: (token: UUID, interface: HIDInterface)] = [:]
    private var batteryReadingDevices: [String: DeviceInfo] = [:]
    private var activeDPIPlans: [String: MouseDPIPlan] = [:]
    private var hasRequestedQueries = false
    private var hasRequestedSystemMetadata = false
    private var hasRequestedAutomaticBattery = false
    private var hasConfirmedDPIWrite = false
    public var physicalDevices: [DeviceInfo] { devices.filter { !$0.isVirtual } }
    public var virtualDevices: [DeviceInfo] { devices.filter(\.isVirtual) }
    public var interfaceCount: Int { interfaces.count }

    public init(discovery: any HIDDiscovering = HIDDiscovery(), mouseReader: any MouseStatusReading = MouseReadService(),
                dpiController: any MouseDPIControlling = MouseDPIService(),
                systemBatteryReader: any SystemBatteryReadingService = SystemBatteryService(),
                pollingReader: any MousePollingReadingService = PollingRateReadService(),
                chargingReader: any MouseChargingReadingService = ChargingReadService(),
                keyboardPowerReader: any KeyboardPowerReadingService = KeyboardPowerReadService(),
                batteryReader: any BatteryReadingService = ViperBatteryReadService(), isSimulation: Bool = false) {
        if isSimulation {
            precondition(!(discovery is HIDDiscovery) && !(mouseReader is MouseReadService)
                && !(dpiController is MouseDPIService) && !(systemBatteryReader is SystemBatteryService)
                && !(pollingReader is PollingRateReadService) && !(chargingReader is ChargingReadService)
                && !(keyboardPowerReader is KeyboardPowerReadService) && !(batteryReader is ViperBatteryReadService), "模拟模式必须替换全部真实设备服务")
        }
        self.isSimulation = isSimulation
        self.batteryReader = batteryReader
        self.discovery = discovery
        self.mouseReader = mouseReader
        self.dpiController = dpiController
        self.systemBatteryReader = systemBatteryReader
        self.pollingReader = pollingReader
        self.chargingReader = chargingReader
        self.keyboardPowerReader = keyboardPowerReader
    }

    public func start() {
        guard !isMonitoring else { return }
        let start = ContinuousClock.now
        discovery.onChange = { [weak self] interfaces, reason in
            guard let self else { return }
            self.interfaces = interfaces
            self.devices = DeviceInfo.group(interfaces)
            self.invalidateDisconnectedReads()
            self.lastUpdated = Date()
            self.record(reason)
        }
        discovery.onError = { [weak self] in self?.record($0, isError: true) }
        isMonitoring = true
        discovery.start()
        let duration = start.duration(to: .now).components
        discoveryReadyMilliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        record("发现服务就绪（\(String(format: "%.2f", discoveryReadyMilliseconds ?? 0)) ms）；枚举仅读取系统属性，状态查询需手动触发。")
    }

    public func refresh() { if !isSuspended { discovery.refresh() } }
    public func stop() {
        guard isMonitoring else { return }
        discovery.stop()
        discovery.onChange = nil
        discovery.onError = nil
        isMonitoring = false
        isSuspended = false
        operations.invalidateSessions()
        cancelledReadFields.removeAll()
        lastSuccessfulReadings.removeAll()
        batteryReadouts.removeAll()
        readingDeviceIDs.removeAll()
        mouseReadouts.removeAll()
        mouseReadingInterfaces.removeAll()
        clearPollingReads()
        clearChargingReads()
        clearKeyboardReads()
        readingSystemBatteryIDs.removeAll()
        systemBatteryReadings.removeAll()
        batteryReadingDevices.removeAll()
        invalidateDPIPlans()
        dpiWriteResults.removeAll()
        dpiResultInterfaces.removeAll()
        dpiErrors.removeAll()
        if !operations.hasReservations {
            hasRequestedQueries = false
            hasRequestedSystemMetadata = false
            hasRequestedAutomaticBattery = false
            hasConfirmedDPIWrite = false
        }
        syncOperationActivity()
    }

    /// No startup, refresh or hotplug path calls this method. Only an explicit user action does.
    public func readMouseState(for deviceID: String) async {
        guard let device = devices.first(where: { $0.id == deviceID }),
              let interface = ViperV4Adapter.controlInterface(in: device),
              let ticket = beginRead(.mouse, for: deviceID) else { return }
        defer { finishOperation(ticket) }
        batteryReadouts.removeValue(forKey: deviceID)
        mouseReadouts.removeValue(forKey: deviceID)
        mouseReadingInterfaces.removeValue(forKey: deviceID)
        hasRequestedQueries = true
        record("手动读取 \(device.product) 的电量与 DPI；不发送设置命令。")
        let result = await performRead(ticket) { await self.mouseReader.read(device) }
        guard !Task.isCancelled, operations.isCurrent(ticket) else { return }
        guard let current = devices.first(where: { $0.id == deviceID }),
              let currentInterface = ViperV4Adapter.controlInterface(in: current),
              ViperV4Adapter.isSameInterface(currentInterface, expected: interface),
              result.deviceID == deviceID, result.interfaceID == interface.id else { return }
        mouseReadouts[deviceID] = result
        mouseReadingInterfaces[deviceID] = currentInterface
        publishBattery(device, ticket: ticket, percent: result.batteryPercent, at: result.readAt, source: .device,
            issue: result.issues.first { $0.field == "battery" || $0.field == "interface" })
        rememberSuccessfulReadings(for: device, fields: ticket.operation.fields)
        if result.issues.isEmpty {
            record("\(device.product) 状态读取完成。")
        } else {
            for issue in result.issues {
                record("\(device.product) · \(issue.field)：\(issue.message)", isError: true, presentError: false)
            }
        }
    }

    public func readPollingRate(for deviceID: String) async {
        guard let device = devices.first(where: { $0.id == deviceID }),
              let interface = ViperV4Adapter.controlInterface(in: device),
              let ticket = beginRead(.polling, for: deviceID) else { return }
        defer { finishOperation(ticket) }
        pollingReadouts.removeValue(forKey: deviceID)
        pollingReadingInterfaces.removeValue(forKey: deviceID)
        hasRequestedQueries = true
        record("手动读取 \(device.product) 的回报率配置；不修改频率。")
        let result = await performRead(ticket) { await self.pollingReader.read(device) }
        guard !Task.isCancelled, operations.isCurrent(ticket) else { return }
        guard let current = devices.first(where: { $0.id == deviceID }),
              let currentInterface = ViperV4Adapter.controlInterface(in: current),
              ViperV4Adapter.isSameInterface(currentInterface, expected: interface),
              result.deviceID == deviceID, result.interfaceID == interface.id else { return }
        pollingReadouts[deviceID] = result
        pollingReadingInterfaces[deviceID] = currentInterface
        rememberSuccessfulReadings(for: device, fields: ticket.operation.fields)
        if let issue = result.issue {
            record("\(device.product) · 回报率：\(issue.message)", isError: true, presentError: false)
        } else {
            record("\(device.product) 回报率配置读取完成；该数值不是实测输入频率。")
        }
    }

    public func readChargingState(for deviceID: String) async {
        guard let device = devices.first(where: { $0.id == deviceID }),
              let interface = ViperV4Adapter.controlInterface(in: device),
              let ticket = beginRead(.charging, for: deviceID) else { return }
        defer { finishOperation(ticket) }
        chargingReadouts.removeValue(forKey: deviceID)
        chargingReadingInterfaces.removeValue(forKey: deviceID)
        hasRequestedQueries = true
        record("手动读取 \(device.product) 的充电状态；不修改设备设置。")
        let result = await performRead(ticket) { await self.chargingReader.read(device) }
        guard !Task.isCancelled, operations.isCurrent(ticket) else { return }
        guard let current = devices.first(where: { $0.id == deviceID }),
              let currentInterface = ViperV4Adapter.controlInterface(in: current),
              ViperV4Adapter.isSameInterface(currentInterface, expected: interface),
              result.deviceID == deviceID, result.interfaceID == interface.id else { return }
        chargingReadouts[deviceID] = result
        chargingReadingInterfaces[deviceID] = currentInterface
        rememberSuccessfulReadings(for: device, fields: ticket.operation.fields)
        if let issue = result.issue {
            record("\(device.product) · 充电状态：\(issue.message)", isError: true, presentError: false)
        } else {
            record("\(device.product) 充电状态读取完成。")
        }
    }

    public func readKeyboardPower(for deviceID: String, field: KeyboardPowerField) async {
        guard let device = devices.first(where: { $0.id == deviceID }),
              let interface = BlackWidowLowProfileAdapter.controlInterface(in: device),
              let ticket = beginRead(field == .battery ? .keyboardBattery : .keyboardCharging, for: deviceID) else { return }
        defer { finishOperation(ticket) }
        if field == .battery { batteryReadouts.removeValue(forKey: deviceID) }
        if field == .battery { keyboardBatteryReadouts.removeValue(forKey: deviceID) }
        else { keyboardChargingReadouts.removeValue(forKey: deviceID) }
        hasRequestedQueries = true
        record("手动试读 \(device.product) 的\(field.title)；不切换设备模式、不修改设置。")
        let result = await performRead(ticket) { await self.keyboardPowerReader.read(device, field: field) }
        guard !Task.isCancelled, operations.isCurrent(ticket) else { return }
        guard let current = devices.first(where: { $0.id == deviceID }),
              let currentInterface = BlackWidowLowProfileAdapter.controlInterface(in: current),
              currentInterface.matchesSession(interface), result.matches(current, field: field) else { return }
        keyboardReadingInterfaces[deviceID] = currentInterface
        if field == .battery {
            keyboardBatteryReadouts[deviceID] = result
            publishBattery(device, ticket: ticket, percent: result.batteryPercent, at: result.readAt, source: .device, issue: result.issue)
        }
        else { keyboardChargingReadouts[deviceID] = result }
        rememberSuccessfulReadings(for: device, fields: ticket.operation.fields)
        if let issue = result.issue {
            record("\(device.product) · \(field.title)：\(issue.message)", isError: true, presentError: false)
        } else {
            record("\(device.product) \(field.title)试读完成。")
        }
    }

    public func readSummary(for deviceID: String) -> DeviceReadSummary {
        DeviceReadSummary.assess(battery: batteryReadouts[deviceID], mouse: mouseReadouts[deviceID], systemBattery: systemBatteryReadings[deviceID],
                                 polling: pollingReadouts[deviceID], charging: chargingReadouts[deviceID],
                                 keyboardBattery: keyboardBatteryReadouts[deviceID], keyboardCharging: keyboardChargingReadouts[deviceID],
                                 isReading: readingBatteryIDs.contains(deviceID) || readingDeviceIDs.contains(deviceID) || readingPollingDeviceIDs.contains(deviceID)
                                    || readingSystemBatteryIDs.contains(deviceID) || readingChargingDeviceIDs.contains(deviceID)
                                    || readingKeyboardPowerIDs.contains(deviceID),
                                 isSuspended: isSuspended, isDraining: drainingOperationIDs.contains(deviceID),
                                 hasCancelledRead: cancelledReadFields[deviceID]?.isEmpty == false)
    }

    public func capabilityActivity(for deviceID: String) -> CapabilityActivity {
        let reading = operations.activeOperation(for: deviceID)?.fields ?? []
        return .init(reading: reading, isSuspended: isSuspended, dpiBusy: dpiBusyIDs.contains(deviceID),
                     dpiAwaitingConfirmation: pendingDPIChanges[deviceID] != nil,
                     isDraining: drainingOperationIDs.contains(deviceID), cancelled: cancelledReadFields[deviceID] ?? [],
                     previousReadings: lastSuccessfulReadings[deviceID] ?? [:])
    }

    public func adapterAssessment(for device: DeviceInfo) -> AdapterAssessment {
        AdapterCatalog.assess(device, battery: batteryReadouts[device.id], telemetry: mouseReadouts[device.id], systemBattery: systemBatteryReadings[device.id],
            polling: pollingReadouts[device.id], charging: chargingReadouts[device.id],
            keyboardBattery: keyboardBatteryReadouts[device.id], keyboardCharging: keyboardChargingReadouts[device.id],
            activity: capabilityActivity(for: device.id), dpiWrite: dpiWriteResults[device.id], simulation: isSimulation)
    }

    public func connectionCheck() -> ConnectionCheckReport {
        .assess(devices: devices, assessments: Dictionary(uniqueKeysWithValues: devices.map { ($0.id, adapterAssessment(for: $0)) }),
                isMonitoring: isMonitoring, isSuspended: isSuspended)
    }

    /// Explicit OS metadata refresh. It never invokes a vendor protocol or scans Bluetooth.
    public func readSystemBattery(for deviceID: String) async {
        guard let device = devices.first(where: { $0.id == deviceID }), SystemBatteryService.canRead(device),
              let ticket = beginRead(.systemBattery, for: deviceID) else { return }
        defer { finishOperation(ticket) }
        batteryReadouts.removeValue(forKey: deviceID)
        systemBatteryReadings.removeValue(forKey: deviceID)
        batteryReadingDevices.removeValue(forKey: deviceID)
        hasRequestedSystemMetadata = true
        record("按需读取 \(device.product) 的 macOS 电量信息。")
        let result = await performRead(ticket) { await self.systemBatteryReader.read(device) }
        guard !Task.isCancelled, operations.isCurrent(ticket) else { return }
        guard let current = devices.first(where: { $0.id == deviceID }), current == device, result.matches(current) else { return }
        systemBatteryReadings[deviceID] = result
        batteryReadingDevices[deviceID] = current
        publishBattery(device, ticket: ticket, percent: result.percent, at: result.acquiredAt, source: .systemCache,
            issue: result.issue.map { .init(field: "battery", message: $0, kind: result.failureKind) }
                ?? result.failureKind.map { .init(field: "battery", message: $0.title, kind: $0) })
        rememberSuccessfulReadings(for: device, fields: ticket.operation.fields)
        if let issue = result.issue {
            record("\(device.product) · \(issue)", isError: true, presentError: false)
        } else {
            record("\(device.product) 系统电量读取完成；来源：\(result.source?.title ?? "未知")。")
        }
    }

    public func suspend() {
        guard isMonitoring else { return }
        isSuspended = true
        operations.invalidateSessions()
        cancelledReadFields.removeAll()
        lastSuccessfulReadings.removeAll()
        batteryReadouts.removeAll()
        readingDeviceIDs.removeAll()
        mouseReadouts.removeAll()
        mouseReadingInterfaces.removeAll()
        clearPollingReads()
        clearChargingReads()
        clearKeyboardReads()
        readingSystemBatteryIDs.removeAll()
        systemBatteryReadings.removeAll()
        batteryReadingDevices.removeAll()
        invalidateDPIPlans()
        dpiWriteResults.removeAll()
        dpiResultInterfaces.removeAll()
        dpiErrors.removeAll()
        syncOperationActivity()
        record("系统即将睡眠：清除读取状态并使待确认变更失效。")
    }

    public func resume() {
        guard isMonitoring, isSuspended else { return }
        isSuspended = false
        discovery.refresh()
        record("系统已唤醒：重新枚举设备；电量与 DPI 等候手动刷新。")
    }

    public func prepareDPIChange(for deviceID: String, x: Int, y: Int) async {
        guard isMonitoring, !isSuspended, !operations.isBusy(deviceID),
              dpiRequests[deviceID] == nil, pendingDPIChanges[deviceID] == nil,
              let device = devices.first(where: { $0.id == deviceID }),
              let interface = ViperV4Adapter.controlInterface(in: device),
              let ticket = operations.begin(.dpiPrepare, for: deviceID) else { return }
        defer { finishOperation(ticket) }
        let token = UUID()
        dpiRequests[deviceID] = (token, interface)
        dpiBusyIDs.insert(deviceID)
        dpiErrors.removeValue(forKey: deviceID)
        dpiWriteResults.removeValue(forKey: deviceID)
        dpiResultInterfaces.removeValue(forKey: deviceID)
        hasRequestedQueries = true
        mouseReadouts.removeValue(forKey: deviceID)
        mouseReadingInterfaces.removeValue(forKey: deviceID)
        do {
            let plan = try await dpiController.prepare(device, x: x, y: y)
            guard isMonitoring, !Task.isCancelled, operations.isCurrent(ticket), dpiRequests[deviceID]?.token == token else {
                plan.invalidate()
                if dpiRequests[deviceID]?.token == token { dpiRequests.removeValue(forKey: deviceID); dpiBusyIDs.remove(deviceID) }
                return
            }
            guard plan.deviceID == deviceID, ViperV4Adapter.isSameInterface(plan.interface, expected: interface) else {
                plan.invalidate()
                throw MouseQueryError.deviceChanged
            }
            pendingDPIChanges[deviceID] = plan
            mouseReadouts[deviceID] = MouseTelemetry(deviceID: deviceID, interfaceID: interface.id, readAt: plan.createdAt,
                                                    batteryPercent: nil, dpi: plan.before, issues: [])
            mouseReadingInterfaces[deviceID] = plan.interface
            rememberSuccessfulReadings(for: device, fields: ["dpi", "stages"])
            record("\(device.product) DPI 变更已准备；等候用户确认，尚未写入。")
        } catch {
            guard dpiRequests[deviceID]?.token == token else { return }
            dpiErrors[deviceID] = error.localizedDescription
            record("DPI 准备失败：\(error.localizedDescription)", isError: true, presentError: false)
        }
        dpiRequests.removeValue(forKey: deviceID)
        dpiBusyIDs.remove(deviceID)
    }

    public func cancelDPIChange(for deviceID: String) {
        pendingDPIChanges.removeValue(forKey: deviceID)?.invalidate()
    }

    /// Called only by the confirmation sheet's explicit write button, with the displayed plan ID.
    public func confirmDPIChange(for deviceID: String, planID: UUID) async {
        guard isMonitoring, !isSuspended, dpiRequests[deviceID] == nil, !operations.isBusy(deviceID),
              let plan = pendingDPIChanges[deviceID], plan.id == planID,
              let ticket = operations.begin(.dpiApply, for: deviceID) else { return }
        defer { finishOperation(ticket) }
        pendingDPIChanges.removeValue(forKey: deviceID)
        let token = UUID()
        dpiRequests[deviceID] = (token, plan.interface)
        activeDPIPlans[deviceID] = plan
        dpiBusyIDs.insert(deviceID)
        mouseReadouts.removeValue(forKey: deviceID)
        mouseReadingInterfaces.removeValue(forKey: deviceID)
        pollingReadouts.removeValue(forKey: deviceID)
        pollingReadingInterfaces.removeValue(forKey: deviceID)
        chargingReadouts.removeValue(forKey: deviceID)
        chargingReadingInterfaces.removeValue(forKey: deviceID)
        hasConfirmedDPIWrite = true
        record("用户确认 \(plan.deviceName) 第 \(plan.before.activeStage) 档 DPI → X \(plan.after.current.x) / Y \(plan.after.current.y)。")
        let result = await dpiController.apply(plan)
        guard isMonitoring, operations.isCurrent(ticket), dpiRequests[deviceID]?.token == token else { return }
        dpiRequests.removeValue(forKey: deviceID)
        activeDPIPlans.removeValue(forKey: deviceID)
        dpiBusyIDs.remove(deviceID)
        dpiWriteResults[deviceID] = result
        dpiResultInterfaces[deviceID] = plan.interface
        if result.outcome == .verified, let dpi = result.readback {
            mouseReadouts[deviceID] = MouseTelemetry(deviceID: deviceID, interfaceID: plan.interface.id, readAt: result.completedAt,
                                                    batteryPercent: nil, dpi: dpi, issues: [])
            mouseReadingInterfaces[deviceID] = plan.interface
            if let device = devices.first(where: { $0.id == deviceID }) {
                rememberSuccessfulReadings(for: device, fields: ["dpi", "stages"])
            }
        }
        record(result.message, isError: result.outcome != .verified, presentError: false)
    }

    /// Also called before system sleep. An already submitted USB request cannot be recalled.
    public func invalidateDPIPlans() {
        for plan in pendingDPIChanges.values { plan.invalidate() }
        for plan in activeDPIPlans.values { plan.invalidate() }
        pendingDPIChanges.removeAll()
        activeDPIPlans.removeAll()
        for id in dpiRequests.keys { operations.cancelActive(for: id) }
        dpiRequests.removeAll()
        dpiBusyIDs.removeAll()
        syncOperationActivity()
    }

    public func clearError() { lastError = nil }
    public func snapshotData() throws -> Data {
        try DiagnosticSnapshot(interfaces: interfaces, batteryReadouts: batteryReadouts, mouseReadouts: mouseReadouts, dpiWriteResults: dpiWriteResults,
                               systemBatteryReadings: systemBatteryReadings,
                               pollingReadouts: pollingReadouts,
                               chargingReadouts: chargingReadouts,
                               keyboardBatteryReadouts: keyboardBatteryReadouts, keyboardChargingReadouts: keyboardChargingReadouts,
                               readSummaries: Dictionary(uniqueKeysWithValues: devices.map { ($0.id, readSummary(for: $0.id)) }),
                               activities: Dictionary(uniqueKeysWithValues: devices.map { ($0.id, capabilityActivity(for: $0.id)) }),
                               isMonitoring: isMonitoring, isSuspended: isSuspended,
                               queriesRequested: hasRequestedQueries, systemMetadataRequested: hasRequestedSystemMetadata,
                               automaticBatteryRequested: hasRequestedAutomaticBattery,
                               settingRequested: hasConfirmedDPIWrite,
                               simulation: isSimulation).jsonData()
    }
    public func reportError(_ message: String) { record(message, isError: true) }

    private func invalidateDisconnectedReads() {
        let changed = operations.reconcile(isSuspended ? [] : devices)
        for id in changed { lastSuccessfulReadings.removeValue(forKey: id); cancelledReadFields.removeValue(forKey: id); batteryReadouts.removeValue(forKey: id) }
        syncOperationActivity()
        let connected = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        let keyboard = Dictionary(uniqueKeysWithValues: devices.compactMap { device in
            BlackWidowLowProfileAdapter.controlInterface(in: device).map { (device.id, $0) }
        })
        keyboardBatteryReadouts = keyboardBatteryReadouts.filter { id, result in
            guard let current = keyboard[id], let expected = keyboardReadingInterfaces[id] else { return false }
            return result.interfaceID == current.id && current.matchesSession(expected)
        }
        keyboardChargingReadouts = keyboardChargingReadouts.filter { id, result in
            guard let current = keyboard[id], let expected = keyboardReadingInterfaces[id] else { return false }
            return result.interfaceID == current.id && current.matchesSession(expected)
        }
        keyboardReadingInterfaces = keyboardReadingInterfaces.filter { keyboardBatteryReadouts[$0.key] != nil || keyboardChargingReadouts[$0.key] != nil }
        systemBatteryReadings = systemBatteryReadings.filter { id, value in
            connected[id].map { value.matches($0) && batteryReadingDevices[id] == $0 } ?? false
        }
        batteryReadingDevices = batteryReadingDevices.filter { systemBatteryReadings[$0.key] != nil }
        let current = Dictionary(uniqueKeysWithValues: devices.compactMap { device in
            ViperV4Adapter.controlInterface(in: device).map { (device.id, $0) }
        })
        mouseReadouts = mouseReadouts.filter { id, value in
            guard let current = current[id], let expected = mouseReadingInterfaces[id] else { return false }
            return value.interfaceID == current.id && ViperV4Adapter.isSameInterface(current, expected: expected)
        }
        mouseReadingInterfaces = mouseReadingInterfaces.filter { mouseReadouts[$0.key] != nil }
        pollingReadouts = pollingReadouts.filter { id, value in
            guard let current = current[id], let expected = pollingReadingInterfaces[id] else { return false }
            return value.interfaceID == current.id && ViperV4Adapter.isSameInterface(current, expected: expected)
        }
        pollingReadingInterfaces = pollingReadingInterfaces.filter { pollingReadouts[$0.key] != nil }
        chargingReadouts = chargingReadouts.filter { id, value in
            guard let current = current[id], let expected = chargingReadingInterfaces[id] else { return false }
            return value.interfaceID == current.id && ViperV4Adapter.isSameInterface(current, expected: expected)
        }
        chargingReadingInterfaces = chargingReadingInterfaces.filter { chargingReadouts[$0.key] != nil }
        for (id, plan) in pendingDPIChanges where current[id].map({ ViperV4Adapter.isSameInterface($0, expected: plan.interface) }) != true {
            cancelDPIChange(for: id)
        }
        for (id, request) in dpiRequests where current[id].map({ ViperV4Adapter.isSameInterface($0, expected: request.interface) }) != true {
            activeDPIPlans.removeValue(forKey: id)?.invalidate()
            dpiRequests.removeValue(forKey: id)
        }
        dpiBusyIDs = Set(dpiRequests.keys)
        dpiErrors = dpiErrors.filter { current[$0.key] != nil }
        dpiWriteResults = dpiWriteResults.filter { id, result in
            guard let current = current[id], let expected = dpiResultInterfaces[id] else { return false }
            return current.id == result.interfaceID && ViperV4Adapter.isSameInterface(current, expected: expected)
        }
        dpiResultInterfaces = dpiResultInterfaces.filter { dpiWriteResults[$0.key] != nil }
    }

    public var batteryTargets: [BatteryRefreshTarget] {
        guard isMonitoring, !isSuspended else { return [] }
        return devices.compactMap { device in
            guard let session = operations.generation(for: device.id), let backend = DeviceReadRegistry.backends(for: device).first else { return nil }
            return .init(deviceID: device.id, sessionID: session, backend: backend)
        }
    }

    public func isDeviceBusy(_ id: String) -> Bool {
        operations.isBusy(id) || pendingDPIChanges[id] != nil
    }

    public func batterySummary(for device: DeviceInfo) -> MenuBatterySummary? {
        guard !capabilityActivity(for: device.id).reading.contains("battery"), !isSuspended else { return nil }
        if let reading = batteryReadouts[device.id] {
            guard reading.isValid, let percent = reading.percent else { return nil }
            return .init(percent: percent, source: isSimulation ? "模拟服务 · 非硬件证据" : reading.source.title, acquiredAt: reading.acquiredAt)
        }
        return MenuBatterySummary.choose(mouse: mouseReadouts[device.id], system: systemBatteryReadings[device.id], keyboard: keyboardBatteryReadouts[device.id])
    }

    /// An explicit action, or the opt-in scheduler after its separate hardware acceptance gate.
    @discardableResult public func readBattery(for deviceID: String, origin: BatteryReadingOrigin = .manual) async -> BatteryReading? {
        guard let target = batteryTargets.first(where: { $0.deviceID == deviceID }),
              origin == .manual || BatteryRefreshEligibility.allows(target.backend, simulation: isSimulation),
              let device = devices.first(where: { $0.id == deviceID }),
              let ticket = beginRead(.battery, for: deviceID) else { return nil }
        defer { finishOperation(ticket) }
        batteryReadouts.removeValue(forKey: deviceID)
        if origin == .automatic { hasRequestedAutomaticBattery = true }
        if target.backend == .macOSBluetoothBattery { hasRequestedSystemMetadata = true } else { hasRequestedQueries = true }
        record("\(origin == .manual ? "手动" : "定时")读取 \(device.product) 的电量；不查询 DPI 或修改设置。")
        let result: BatteryReading = await performRead(ticket) {
            switch target.backend {
            case .viperV4USB: return await self.batteryReader.read(device)
            case .blackWidowLowProfileUSB:
                let value = await self.keyboardPowerReader.read(device, field: .battery)
                return .init(deviceID: value.deviceID, interfaceIDs: device.interfaces.map(\.id).sorted(), backend: target.backend,
                    percent: value.matches(device, field: .battery) ? value.batteryPercent : nil, acquiredAt: value.readAt, source: .device,
                    issue: !value.matches(device, field: .battery) ? .init(field: "battery", message: "电量响应身份不匹配", kind: .protocolMismatch)
                        : value.issue ?? (value.hasValue ? nil : .init(field: "battery", message: "没有有效电量", kind: .invalidData)))
            case .macOSBluetoothBattery:
                let value = await self.systemBatteryReader.read(device)
                return .init(deviceID: value.deviceID, interfaceIDs: value.interfaceIDs, backend: target.backend,
                    percent: value.source != nil ? value.percent : nil, acquiredAt: value.acquiredAt, source: .systemCache,
                    issue: value.issue.map { .init(field: "battery", message: $0, kind: value.failureKind) }
                        ?? value.failureKind.map { .init(field: "battery", message: $0.title, kind: $0) })
            }
        }
        guard !Task.isCancelled, operations.isCurrent(ticket), let current = devices.first(where: { $0.id == deviceID }), result.matches(current) else { return nil }
        batteryReadouts[deviceID] = result
        rememberSuccessfulReadings(for: current, fields: ["battery"])
        batteryObservations.send(.init(target: target, deviceName: device.product, reading: result, origin: origin, simulation: isSimulation))
        if let issue = result.issue { record("\(device.product) · 电量：\(issue.message)", isError: true, presentError: false) }
        return result
    }

    private func publishBattery(_ device: DeviceInfo, ticket: DeviceOperationTicket, percent: Int?, at: Date,
                                source: BatteryValueSource, issue: MouseReadIssue?) {
        guard let backend = DeviceReadRegistry.backends(for: device).first else { return }
        let reading = BatteryReading(deviceID: device.id, interfaceIDs: device.interfaces.map(\.id).sorted(), backend: backend,
                                     percent: percent, acquiredAt: at, source: source, issue: issue)
        batteryObservations.send(.init(target: .init(deviceID: device.id, sessionID: ticket.generation, backend: backend),
            deviceName: device.product, reading: reading, origin: .manual, simulation: isSimulation))
    }

    private func beginRead(_ operation: DeviceOperation, for deviceID: String) -> DeviceOperationTicket? {
        guard isMonitoring, !isSuspended, !Task.isCancelled, !dpiBusyIDs.contains(deviceID),
              pendingDPIChanges[deviceID] == nil,
              let ticket = operations.begin(operation, for: deviceID) else { return nil }
        cancelledReadFields[deviceID]?.subtract(operation.fields)
        syncOperationActivity()
        return ticket
    }

    private func performRead<Value: Sendable>(_ ticket: DeviceOperationTicket,
                                              operation: () async -> Value) async -> Value {
        await withTaskCancellationHandler(operation: operation, onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.operations.isCurrent(ticket) else { return }
                self.operations.cancel(ticket)
                self.cancelledReadFields[ticket.deviceID, default: []].formUnion(ticket.operation.fields)
                self.syncOperationActivity()
            }
        })
    }

    private func finishOperation(_ ticket: DeviceOperationTicket) {
        // Also cover cancellation observed before its MainActor handler was scheduled.
        if Task.isCancelled, operations.isCurrent(ticket), !ticket.operation.fields.isEmpty {
            cancelledReadFields[ticket.deviceID, default: []].formUnion(ticket.operation.fields)
        }
        operations.finish(ticket)
        syncOperationActivity()
    }

    private func syncOperationActivity() {
        func ids(_ operation: DeviceOperation) -> Set<String> {
            Set(devices.filter { operations.activeOperation(for: $0.id) == operation }.map(\.id))
        }
        readingBatteryIDs = ids(.battery)
        readingDeviceIDs = ids(.mouse)
        readingPollingDeviceIDs = ids(.polling)
        readingChargingDeviceIDs = ids(.charging)
        readingKeyboardPowerIDs = ids(.keyboardBattery).union(ids(.keyboardCharging))
        readingSystemBatteryIDs = ids(.systemBattery)
        drainingOperationIDs = Set(devices.filter { operations.isDraining($0.id) }.map(\.id))
    }

    private func rememberSuccessfulReadings(for device: DeviceInfo, fields: Set<String>) {
        let assessment = AdapterCatalog.assess(device, battery: batteryReadouts[device.id], telemetry: mouseReadouts[device.id],
            systemBattery: systemBatteryReadings[device.id], polling: pollingReadouts[device.id], charging: chargingReadouts[device.id],
            keyboardBattery: keyboardBatteryReadouts[device.id], keyboardCharging: keyboardChargingReadouts[device.id], simulation: isSimulation)
        for capability in assessment.capabilities where fields.contains(capability.id) && capability.session.state == .succeeded {
            if let sample = capability.session.sample { lastSuccessfulReadings[device.id, default: [:]][capability.id] = sample }
        }
    }

    private func clearPollingReads() {
        readingPollingDeviceIDs.removeAll()
        pollingReadouts.removeAll()
        pollingReadingInterfaces.removeAll()
    }

    private func clearChargingReads() {
        readingChargingDeviceIDs.removeAll()
        chargingReadouts.removeAll()
        chargingReadingInterfaces.removeAll()
    }

    private func clearKeyboardReads() {
        readingKeyboardPowerIDs.removeAll()
        keyboardBatteryReadouts.removeAll()
        keyboardChargingReadouts.removeAll()
        keyboardReadingInterfaces.removeAll()
    }

    private func record(_ message: String, isError: Bool = false, presentError: Bool = true) {
        logs.append(DiagnosticLog(message: message, isError: isError))
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
        if isError {
            if presentError { lastError = message }
            logger.error("\(message, privacy: .public)")
        } else { logger.info("\(message, privacy: .public)") }
    }
}
