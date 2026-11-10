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
    @Published public private(set) var pendingPollingChanges: [String: PollingRatePlan] = [:]
    @Published public private(set) var pollingWriteBusyIDs: Set<String> = []
    @Published public private(set) var pollingWriteErrors: [String: String] = [:]
    @Published public private(set) var pollingWriteResults: [String: PollingRateWriteResult] = [:]
    @Published public private(set) var keyboardBrightnessReadouts: [String: KeyboardBrightnessReading] = [:]
    @Published public private(set) var readingKeyboardBrightnessIDs: Set<String> = []
    @Published public private(set) var pendingBrightnessChanges: [String: KeyboardBrightnessPlan] = [:]
    @Published public private(set) var brightnessWriteBusyIDs: Set<String> = []
    @Published public private(set) var brightnessWriteErrors: [String: String] = [:]
    @Published public private(set) var brightnessWriteResults: [String: KeyboardBrightnessWriteResult] = [:]
    @Published public private(set) var liveBrightnessTargets: [String: Int] = [:]
    private let liveBrightnessService: any KeyboardBrightnessLiveControlling
    private var liveBrightnessControllers: [String: (generation: UUID, controller: LiveBrightnessController)] = [:]
    private let brightnessReader: any KeyboardBrightnessReadingService
    private let brightnessController: any KeyboardBrightnessControlling
    private var activeBrightnessPlans: [String: KeyboardBrightnessPlan] = [:]
    private var brightnessReadingInterfaces: [String: HIDInterface] = [:]
    private var brightnessResultInterfaces: [String: HIDInterface] = [:]
    private let pollingController: any PollingRateControlling
    private var activePollingPlans: [String: PollingRatePlan] = [:]
    private var pollingResultInterfaces: [String: HIDInterface] = [:]
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
    private struct AvailabilityWaiter {
        let deviceID: String
        let generation: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var availabilityWaiters: [UUID: AvailabilityWaiter] = [:]
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
    private var hasConfirmedDeviceWrite = false
    public var physicalDevices: [DeviceInfo] { devices.filter { !$0.isVirtual } }
    public var virtualDevices: [DeviceInfo] { devices.filter(\.isVirtual) }
    public var interfaceCount: Int { interfaces.count }

    public init(discovery: any HIDDiscovering = HIDDiscovery(), mouseReader: any MouseStatusReading = MouseReadService(),
                dpiController: any MouseDPIControlling = MouseDPIService(),
                systemBatteryReader: any SystemBatteryReadingService = SystemBatteryService(),
                pollingReader: any MousePollingReadingService = PollingRateReadService(),
                pollingController: any PollingRateControlling = PollingRateControlService(),
                brightnessReader: any KeyboardBrightnessReadingService = ReclusaBrightnessReadService(),
                brightnessController: any KeyboardBrightnessControlling = ReclusaBrightnessControlService(),
                liveBrightnessService: any KeyboardBrightnessLiveControlling = ReclusaLiveBrightnessService(),
                chargingReader: any MouseChargingReadingService = ChargingReadService(),
                keyboardPowerReader: any KeyboardPowerReadingService = KeyboardPowerReadService(),
                batteryReader: any BatteryReadingService = ViperBatteryReadService(), isSimulation: Bool = false) {
        if isSimulation {
            precondition(!(discovery is HIDDiscovery) && !(mouseReader is MouseReadService)
                && !(dpiController is MouseDPIService) && !(systemBatteryReader is SystemBatteryService)
                && !(pollingController is PollingRateControlService) && !(pollingReader is PollingRateReadService) && !(chargingReader is ChargingReadService)
                && !(brightnessReader is ReclusaBrightnessReadService) && !(brightnessController is ReclusaBrightnessControlService) && !(liveBrightnessService is ReclusaLiveBrightnessService)
                && !(keyboardPowerReader is KeyboardPowerReadService) && !(batteryReader is ViperBatteryReadService), "模拟模式必须替换全部真实设备服务")
        }
        self.isSimulation = isSimulation
        self.batteryReader = batteryReader
        self.discovery = discovery
        self.mouseReader = mouseReader
        self.dpiController = dpiController
        self.systemBatteryReader = systemBatteryReader
        self.liveBrightnessService = liveBrightnessService
        self.brightnessReader = brightnessReader
        self.brightnessController = brightnessController
        self.pollingReader = pollingReader
        self.pollingController = pollingController
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
        record("发现服务就绪（\(String(format: "%.2f", discoveryReadyMilliseconds ?? 0)) ms）；枚举仅读取系统属性，设备状态按页面或操作按需读取，无常驻轮询。")
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
        clearBrightnessReads()
        clearChargingReads()
        clearKeyboardReads()
        readingSystemBatteryIDs.removeAll()
        systemBatteryReadings.removeAll()
        batteryReadingDevices.removeAll()
        invalidateControlPlans()
        pollingWriteResults.removeAll()
        pollingResultInterfaces.removeAll()
        pollingWriteErrors.removeAll()
        brightnessWriteResults.removeAll()
        brightnessResultInterfaces.removeAll()
        brightnessWriteErrors.removeAll()
        dpiWriteResults.removeAll()
        dpiResultInterfaces.removeAll()
        dpiErrors.removeAll()
        if !operations.hasReservations {
            hasRequestedQueries = false
            hasRequestedSystemMetadata = false
            hasRequestedAutomaticBattery = false
            hasConfirmedDeviceWrite = false
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
              let interface = PollingRateReadService.controlInterface(in: device),
              let ticket = beginRead(.polling, for: deviceID) else { return }
        defer { finishOperation(ticket) }
        pollingReadouts.removeValue(forKey: deviceID)
        pollingReadingInterfaces.removeValue(forKey: deviceID)
        hasRequestedQueries = true
        record("手动读取 \(device.product) 的回报率配置；不修改频率。")
        let result = await performRead(ticket) { await self.pollingReader.read(device) }
        guard !Task.isCancelled, operations.isCurrent(ticket) else { return }
        guard let current = devices.first(where: { $0.id == deviceID }),
              let currentInterface = PollingRateReadService.controlInterface(in: current),
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

    public func readKeyboardBrightness(for deviceID: String) async {
        guard let device = devices.first(where: { $0.id == deviceID }),
              let interface = ReclusaLightingAdapter.controlInterface(in: device),
              let ticket = beginRead(.keyboardBrightness, for: deviceID) else { return }
        defer { finishOperation(ticket) }
        keyboardBrightnessReadouts.removeValue(forKey: deviceID)
        brightnessReadingInterfaces.removeValue(forKey: deviceID)
        hasRequestedQueries = true
        let result = await performRead(ticket) { await self.brightnessReader.read(device) }
        guard !Task.isCancelled, operations.isCurrent(ticket),
              let current = devices.first(where: { $0.id == deviceID }),
              let currentInterface = ReclusaLightingAdapter.controlInterface(in: current),
              currentInterface.matchesSession(interface) else { return }
        let reading: KeyboardBrightnessReading
        if result.deviceID != deviceID || result.interfaceID != interface.id {
            reading = .init(deviceID: deviceID, interfaceID: interface.id, profileID: 1,
                regionID: nil, rawBrightness: nil, percent: nil,
                issue: .init(field: "brightness", message: "亮度响应身份不匹配，已丢弃；请重新读取。", kind: .protocolMismatch), readAt: .now)
        } else if !result.hasValue {
            reading = .init(deviceID: deviceID, interfaceID: interface.id, profileID: 1,
                regionID: result.regionID, rawBrightness: nil, percent: nil,
                issue: result.issue ?? .init(field: "brightness", message: "本次没有取得有效亮度值。", kind: .invalidData), readAt: result.readAt)
        } else { reading = result }
        keyboardBrightnessReadouts[deviceID] = reading
        brightnessReadingInterfaces[deviceID] = currentInterface
        rememberSuccessfulReadings(for: device, fields: ["brightness"])
        record(reading.issue.map { "亮度读取失败：\($0.message)" } ?? "\(device.product) 亮度配置已读取。",
               isError: reading.issue != nil, presentError: false)
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
              let interface = KeyboardPowerReadService.controlInterface(in: device),
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
              let currentInterface = KeyboardPowerReadService.controlInterface(in: current),
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
                                 keyboardBattery: keyboardBatteryReadouts[deviceID], keyboardCharging: keyboardChargingReadouts[deviceID], keyboardBrightness: keyboardBrightnessReadouts[deviceID],
                                 isReading: readingBatteryIDs.contains(deviceID) || readingDeviceIDs.contains(deviceID) || readingPollingDeviceIDs.contains(deviceID)
                                    || readingSystemBatteryIDs.contains(deviceID) || readingChargingDeviceIDs.contains(deviceID)
                                    || readingKeyboardPowerIDs.contains(deviceID) || readingKeyboardBrightnessIDs.contains(deviceID),
                                 isSuspended: isSuspended, isDraining: drainingOperationIDs.contains(deviceID),
                                 hasCancelledRead: cancelledReadFields[deviceID]?.isEmpty == false)
    }

    public func capabilityActivity(for deviceID: String) -> CapabilityActivity {
        let reading = operations.activeOperation(for: deviceID)?.fields ?? []
        return .init(reading: reading, isSuspended: isSuspended, dpiBusy: dpiBusyIDs.contains(deviceID),
                     dpiAwaitingConfirmation: pendingDPIChanges[deviceID] != nil,
                     pollingWriteBusy: pollingWriteBusyIDs.contains(deviceID), pollingAwaitingConfirmation: pendingPollingChanges[deviceID] != nil,
                     brightnessWriteBusy: brightnessWriteBusyIDs.contains(deviceID), brightnessAwaitingConfirmation: pendingBrightnessChanges[deviceID] != nil,
                     isDraining: drainingOperationIDs.contains(deviceID), cancelled: cancelledReadFields[deviceID] ?? [],
                     previousReadings: lastSuccessfulReadings[deviceID] ?? [:])
    }

    public func adapterAssessment(for device: DeviceInfo) -> AdapterAssessment {
        AdapterCatalog.assess(device, battery: batteryReadouts[device.id], telemetry: mouseReadouts[device.id], systemBattery: systemBatteryReadings[device.id],
            polling: pollingReadouts[device.id], charging: chargingReadouts[device.id],
            keyboardBattery: keyboardBatteryReadouts[device.id], keyboardCharging: keyboardChargingReadouts[device.id], keyboardBrightness: keyboardBrightnessReadouts[device.id],
            activity: capabilityActivity(for: device.id), dpiWrite: dpiWriteResults[device.id], pollingWrite: pollingWriteResults[device.id], brightnessWrite: brightnessWriteResults[device.id], simulation: isSimulation)
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
        clearBrightnessReads()
        clearChargingReads()
        clearKeyboardReads()
        readingSystemBatteryIDs.removeAll()
        systemBatteryReadings.removeAll()
        batteryReadingDevices.removeAll()
        invalidateControlPlans()
        pollingWriteResults.removeAll()
        pollingResultInterfaces.removeAll()
        pollingWriteErrors.removeAll()
        brightnessWriteResults.removeAll()
        brightnessResultInterfaces.removeAll()
        brightnessWriteErrors.removeAll()
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
        record("系统已唤醒：重新枚举设备；打开的设备页面按需刷新，其余状态等待操作。")
    }

    public func prepareDPIChange(for deviceID: String, x: Int, y: Int) async {
        await prepareDPIChange(for: deviceID) { [dpiController] device in
            try await dpiController.prepare(device, x: x, y: y)
        }
    }

    public func prepareDPIStages(for deviceID: String, baseline: MouseDPIState, changes: [MouseDPIStageChange]) async {
        await prepareDPIChange(for: deviceID) { [dpiController] device in
            try await dpiController.prepareStages(device, baseline: baseline, changes: changes)
        }
    }

    public func prepareDPIStageSwitch(for deviceID: String, baseline: MouseDPIState, stage: Int) async {
        await prepareDPIChange(for: deviceID) { [dpiController] device in
            try await dpiController.prepareStageSwitch(device, baseline: baseline, stage: stage)
        }
    }

    private func prepareDPIChange(for deviceID: String, prepare: (DeviceInfo) async throws -> MouseDPIPlan) async {
        guard isMonitoring, !isSuspended, !Task.isCancelled, !operations.isBusy(deviceID),
              dpiRequests[deviceID] == nil, pendingDPIChanges[deviceID] == nil, pendingPollingChanges[deviceID] == nil, pendingBrightnessChanges[deviceID] == nil,
              let device = devices.first(where: { $0.id == deviceID }),
              let interface = ViperV4Adapter.controlInterface(in: device),
              let ticket = operations.begin(.dpiPrepare, for: deviceID) else { return }
        let token = UUID()
        defer {
            if dpiRequests[deviceID]?.token == token {
                dpiRequests.removeValue(forKey: deviceID)
                dpiBusyIDs.remove(deviceID)
            }
            finishOperation(ticket)
        }
        dpiRequests[deviceID] = (token, interface)
        dpiBusyIDs.insert(deviceID)
        dpiErrors.removeValue(forKey: deviceID)
        dpiWriteResults.removeValue(forKey: deviceID)
        dpiResultInterfaces.removeValue(forKey: deviceID)
        hasRequestedQueries = true
        mouseReadouts.removeValue(forKey: deviceID)
        mouseReadingInterfaces.removeValue(forKey: deviceID)
        do {
            let plan = try await withTaskCancellationHandler {
                try await prepare(device)
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, self.operations.isCurrent(ticket) else { return }
                    self.cancelDPIChange(for: deviceID)
                }
            }
            guard isMonitoring, !Task.isCancelled, operations.isCurrent(ticket), dpiRequests[deviceID]?.token == token else {
                plan.invalidate()
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
            guard !Task.isCancelled, operations.isCurrent(ticket), dpiRequests[deviceID]?.token == token else { return }
            dpiErrors[deviceID] = error.localizedDescription
            record("DPI 准备失败：\(error.localizedDescription)", isError: true, presentError: false)
        }
    }

    public func cancelDPIChange(for deviceID: String) {
        pendingDPIChanges.removeValue(forKey: deviceID)?.invalidate()
        if operations.activeOperation(for: deviceID) == .dpiPrepare {
            operations.cancelActive(for: deviceID)
            dpiRequests.removeValue(forKey: deviceID)
            dpiBusyIDs.remove(deviceID)
            syncOperationActivity()
        }
        resumeAvailabilityWaiters()
    }

    /// Called only by the confirmation sheet's explicit write button, with the displayed plan ID.
    public func confirmDPIChange(for deviceID: String, planID: UUID) async {
        guard isMonitoring, !isSuspended, !Task.isCancelled, dpiRequests[deviceID] == nil, !operations.isBusy(deviceID),
              let plan = pendingDPIChanges[deviceID], plan.id == planID,
              let ticket = operations.begin(.dpiApply, for: deviceID) else { return }
        pendingDPIChanges.removeValue(forKey: deviceID)
        let token = UUID()
        defer {
            if dpiRequests[deviceID]?.token == token {
                dpiRequests.removeValue(forKey: deviceID)
                dpiBusyIDs.remove(deviceID)
            }
            if activeDPIPlans[deviceID]?.id == plan.id { activeDPIPlans.removeValue(forKey: deviceID) }
            finishOperation(ticket)
        }
        dpiRequests[deviceID] = (token, plan.interface)
        activeDPIPlans[deviceID] = plan
        dpiBusyIDs.insert(deviceID)
        mouseReadouts.removeValue(forKey: deviceID)
        mouseReadingInterfaces.removeValue(forKey: deviceID)
        pollingReadouts.removeValue(forKey: deviceID)
        pollingReadingInterfaces.removeValue(forKey: deviceID)
        chargingReadouts.removeValue(forKey: deviceID)
        chargingReadingInterfaces.removeValue(forKey: deviceID)
        hasConfirmedDeviceWrite = true
        let change = plan.switchesStage
            ? "DPI 从第 \(plan.before.activeStage) 档切换至第 \(plan.after.activeStage) 档"
            : "第 \(plan.changedStages.map(String.init).joined(separator: "、")) 档 DPI 数值变更"
        record("用户确认 \(plan.deviceName) \(change)，提交完整表并读回。")
        let result = await withTaskCancellationHandler {
            await dpiController.apply(plan)
        } onCancel: { plan.invalidate() }
        guard isMonitoring, !Task.isCancelled, operations.isCurrent(ticket), dpiRequests[deviceID]?.token == token else { return }
        guard result.deviceID == deviceID, result.interfaceID == plan.interface.id,
              result.outcome != .verified || result.readback == plan.after else {
            dpiErrors[deviceID] = "DPI 响应与目标不一致，请重新读取设备。"
            return
        }
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

    /// Revokes every pending or not-yet-submitted setting when the window closes or a session ends.
    public func invalidateControlPlans() {
        for id in liveBrightnessControllers.keys { cancelLiveBrightness(for: id) }
        invalidateDPIPlans()
        for plan in pendingPollingChanges.values { plan.invalidate() }
        for plan in activePollingPlans.values { plan.invalidate() }
        pendingPollingChanges.removeAll()
        activePollingPlans.removeAll()
        for id in pollingWriteBusyIDs { operations.cancelActive(for: id) }
        for plan in pendingBrightnessChanges.values { plan.invalidate() }
        for plan in activeBrightnessPlans.values { plan.invalidate() }
        pendingBrightnessChanges.removeAll()
        activeBrightnessPlans.removeAll()
        for id in brightnessWriteBusyIDs { operations.cancelActive(for: id) }
        syncOperationActivity()
    }

    public func preparePollingChange(for deviceID: String, hertz: Int) async {
        guard isMonitoring, !isSuspended, !Task.isCancelled, !isDeviceBusy(deviceID),
              let device = devices.first(where: { $0.id == deviceID }),
              let interface = PollingRateReadService.controlInterface(in: device),
              let ticket = operations.begin(.pollingPrepare, for: deviceID) else { return }
        defer { finishOperation(ticket) }
        syncOperationActivity()
        pollingWriteErrors.removeValue(forKey: deviceID)
        pollingWriteResults.removeValue(forKey: deviceID)
        pollingResultInterfaces.removeValue(forKey: deviceID)
        pollingReadouts.removeValue(forKey: deviceID)
        pollingReadingInterfaces.removeValue(forKey: deviceID)
        hasRequestedQueries = true
        do {
            let plan = try await pollingController.prepare(device, hertz: hertz)
            guard !Task.isCancelled, operations.isCurrent(ticket), isMonitoring else { plan.invalidate(); return }
            guard plan.deviceID == deviceID, plan.interface.matchesSession(interface) else {
                plan.invalidate(); throw MouseQueryError.deviceChanged
            }
            pendingPollingChanges[deviceID] = plan
            pollingReadouts[deviceID] = .init(deviceID: deviceID, interfaceID: interface.id, readAt: plan.createdAt,
                configuredHertz: plan.before, issue: nil)
            pollingReadingInterfaces[deviceID] = interface
            rememberSuccessfulReadings(for: device, fields: ["polling"])
            record("\(device.product) 回报率变更已检查，等待明确确认；尚未写入。")
        } catch {
            guard !Task.isCancelled, operations.isCurrent(ticket) else { return }
            pollingWriteErrors[deviceID] = error.localizedDescription
            record("回报率检查失败：\(error.localizedDescription)", isError: true, presentError: false)
        }
    }

    public func cancelPollingChange(for deviceID: String) {
        pendingPollingChanges.removeValue(forKey: deviceID)?.invalidate()
        if operations.activeOperation(for: deviceID) == .pollingPrepare {
            operations.cancelActive(for: deviceID)
            syncOperationActivity()
        }
        resumeAvailabilityWaiters()
    }

    public func confirmPollingChange(for deviceID: String, planID: UUID) async {
        guard isMonitoring, !isSuspended, !Task.isCancelled, !operations.isBusy(deviceID),
              let plan = pendingPollingChanges[deviceID], plan.id == planID,
              let ticket = operations.begin(.pollingApply, for: deviceID) else { return }
        pendingPollingChanges.removeValue(forKey: deviceID)
        activePollingPlans[deviceID] = plan
        defer {
            if activePollingPlans[deviceID]?.id == plan.id { activePollingPlans.removeValue(forKey: deviceID) }
            finishOperation(ticket)
        }
        syncOperationActivity()
        // RF reconfiguration makes earlier status samples historical until explicitly queried again.
        pollingReadouts.removeValue(forKey: deviceID)
        pollingReadingInterfaces.removeValue(forKey: deviceID)
        batteryReadouts.removeValue(forKey: deviceID)
        mouseReadouts.removeValue(forKey: deviceID)
        mouseReadingInterfaces.removeValue(forKey: deviceID)
        chargingReadouts.removeValue(forKey: deviceID)
        chargingReadingInterfaces.removeValue(forKey: deviceID)
        keyboardBatteryReadouts.removeValue(forKey: deviceID)
        keyboardChargingReadouts.removeValue(forKey: deviceID)
        keyboardReadingInterfaces.removeValue(forKey: deviceID)
        hasConfirmedDeviceWrite = true
        record("用户确认 \(plan.deviceName) 回报率 \(plan.before) → \(plan.after) Hz；单次提交并读回。")
        let result = await withTaskCancellationHandler {
            await pollingController.apply(plan)
        } onCancel: { plan.invalidate() }
        guard !Task.isCancelled, operations.isCurrent(ticket), isMonitoring else { return }
        guard result.deviceID == deviceID, result.interfaceID == plan.interface.id else {
            pollingWriteErrors[deviceID] = "控制结果身份不匹配；操作结果不确定，请重新读取。"
            return
        }
        pollingWriteResults[deviceID] = result
        pollingResultInterfaces[deviceID] = plan.interface
        if result.outcome == .verified, let hertz = result.readback, hertz == plan.after {
            pollingReadouts[deviceID] = .init(deviceID: deviceID, interfaceID: plan.interface.id,
                readAt: result.completedAt, configuredHertz: hertz, issue: nil)
            pollingReadingInterfaces[deviceID] = plan.interface
            if let device = devices.first(where: { $0.id == deviceID }) { rememberSuccessfulReadings(for: device, fields: ["polling"]) }
        }
        record(result.message, isError: result.outcome != .verified, presentError: false)
    }

    public func canAdjustLiveBrightness(for deviceID: String) -> Bool {
        guard isMonitoring, !isSuspended, !drainingOperationIDs.contains(deviceID),
              pendingDPIChanges[deviceID] == nil, pendingPollingChanges[deviceID] == nil,
              pendingBrightnessChanges[deviceID] == nil else { return false }
        if operations.isBusy(deviceID) {
            return operations.activeOperation(for: deviceID) == .brightnessApply
                && liveBrightnessControllers[deviceID]?.controller.target != nil
        }
        return true
    }

    /// Only explicit slider/button edits enter this path. Discovery and reads never submit a value.
    public func setKeyboardBrightness(for deviceID: String, percent: Int) {
        guard (0...100).contains(percent), canAdjustLiveBrightness(for: deviceID),
              let device = devices.first(where: { $0.id == deviceID }),
              let interface = ReclusaLightingAdapter.controlInterface(in: device),
              let generation = operations.generation(for: deviceID) else { return }
        if liveBrightnessControllers[deviceID]?.generation != generation {
            guard liveBrightnessControllers[deviceID]?.controller.hasWork != true else { return }
            let controller = LiveBrightnessController(onStateChange: { [weak self] in
                guard let self else { return }
                self.liveBrightnessTargets[deviceID] = self.liveBrightnessControllers[deviceID]?.controller.target
                self.resumeAvailabilityWaiters()
            }, apply: { [weak self] percent, permit in
                guard let self else { return false }
                return await self.applyLiveBrightness(deviceID: deviceID, interface: interface,
                    generation: generation, percent: percent, permit: permit)
            })
            liveBrightnessControllers[deviceID] = (generation, controller)
        }
        brightnessWriteErrors.removeValue(forKey: deviceID)
        _ = liveBrightnessControllers[deviceID]?.controller.submit(percent: percent)
    }

    public func cancelLiveBrightness(for deviceID: String) {
        liveBrightnessControllers[deviceID]?.controller.cancel()
        if operations.activeOperation(for: deviceID) == .brightnessApply,
           activeBrightnessPlans[deviceID] == nil {
            operations.cancelActive(for: deviceID)
            syncOperationActivity()
        }
    }

    private func applyLiveBrightness(deviceID: String, interface: HIDInterface, generation: UUID,
                                     percent: Int, permit: LiveBrightnessPermit) async -> Bool {
        guard isMonitoring, !isSuspended, !Task.isCancelled, permit.isUsable,
              operations.generation(for: deviceID) == generation,
              let device = devices.first(where: { $0.id == deviceID }),
              ReclusaLightingAdapter.controlInterface(in: device)?.matchesSession(interface) == true,
              let ticket = operations.begin(.brightnessApply, for: deviceID) else { return false }
        defer { finishOperation(ticket) }
        syncOperationActivity()
        keyboardBrightnessReadouts.removeValue(forKey: deviceID)
        brightnessReadingInterfaces.removeValue(forKey: deviceID)
        brightnessWriteResults.removeValue(forKey: deviceID)
        brightnessResultInterfaces.removeValue(forKey: deviceID)
        hasRequestedQueries = true
        hasConfirmedDeviceWrite = true
        let result = await withTaskCancellationHandler {
            await liveBrightnessService.set(device, percent: percent, permit: permit)
        } onCancel: { permit.invalidate() }
        guard !Task.isCancelled, isMonitoring, operations.isCurrent(ticket) else { return false }
        guard result.deviceID == deviceID, result.interfaceID == interface.id else {
            brightnessWriteErrors[deviceID] = "亮度响应与当前设备不匹配，请重新读取。"
            return false
        }
        if result.outcome == .verified {
            guard let reading = result.readback, reading.hasValue, reading.deviceID == deviceID,
                  reading.interfaceID == interface.id, reading.profileID == 1,
                  reading.rawBrightness == (try? ReclusaBrightnessProtocol.raw(forPercent: percent)) else {
                brightnessWriteErrors[deviceID] = "亮度读回与目标不一致，请重新读取。"
                return false
            }
            keyboardBrightnessReadouts[deviceID] = reading
            brightnessReadingInterfaces[deviceID] = interface
            rememberSuccessfulReadings(for: device, fields: ["brightness"])
        }
        brightnessWriteResults[deviceID] = result
        brightnessResultInterfaces[deviceID] = interface
        record(result.message, isError: result.outcome != .verified, presentError: false)
        return result.outcome == .verified
    }

    public func prepareBrightnessChange(for deviceID: String, percent: Int) async {
        guard isMonitoring, !isSuspended, !Task.isCancelled, !isDeviceBusy(deviceID),
              let device = devices.first(where: { $0.id == deviceID }),
              let interface = ReclusaLightingAdapter.controlInterface(in: device),
              let ticket = operations.begin(.brightnessPrepare, for: deviceID) else { return }
        defer { finishOperation(ticket) }
        syncOperationActivity()
        brightnessWriteErrors.removeValue(forKey: deviceID)
        brightnessWriteResults.removeValue(forKey: deviceID)
        brightnessResultInterfaces.removeValue(forKey: deviceID)
        keyboardBrightnessReadouts.removeValue(forKey: deviceID)
        brightnessReadingInterfaces.removeValue(forKey: deviceID)
        hasRequestedQueries = true
        do {
            let plan = try await brightnessController.prepare(device, percent: percent)
            guard !Task.isCancelled, operations.isCurrent(ticket), isMonitoring else { plan.invalidate(); return }
            guard plan.deviceID == deviceID, plan.interface.matchesSession(interface),
                  plan.before.hasValue, plan.before.deviceID == deviceID, plan.before.interfaceID == interface.id,
                  plan.afterPercent == percent else {
                plan.invalidate(); throw DeviceQueryError.deviceChanged
            }
            pendingBrightnessChanges[deviceID] = plan
            keyboardBrightnessReadouts[deviceID] = plan.before
            brightnessReadingInterfaces[deviceID] = interface
            rememberSuccessfulReadings(for: device, fields: ["brightness"])
            record("\(device.product) 亮度变更已检查，等待明确确认；尚未写入。")
        } catch {
            guard !Task.isCancelled, operations.isCurrent(ticket) else { return }
            brightnessWriteErrors[deviceID] = error.localizedDescription
            record("亮度检查失败：\(error.localizedDescription)", isError: true, presentError: false)
        }
    }

    public func cancelBrightnessChange(for deviceID: String) {
        pendingBrightnessChanges.removeValue(forKey: deviceID)?.invalidate()
        if operations.activeOperation(for: deviceID) == .brightnessPrepare {
            operations.cancelActive(for: deviceID)
            syncOperationActivity()
        }
        resumeAvailabilityWaiters()
    }

    public func confirmBrightnessChange(for deviceID: String, planID: UUID) async {
        guard isMonitoring, !isSuspended, !Task.isCancelled, !operations.isBusy(deviceID),
              let plan = pendingBrightnessChanges[deviceID], plan.id == planID,
              let ticket = operations.begin(.brightnessApply, for: deviceID) else { return }
        pendingBrightnessChanges.removeValue(forKey: deviceID)
        activeBrightnessPlans[deviceID] = plan
        defer {
            if activeBrightnessPlans[deviceID]?.id == plan.id { activeBrightnessPlans.removeValue(forKey: deviceID) }
            finishOperation(ticket)
        }
        syncOperationActivity()
        keyboardBrightnessReadouts.removeValue(forKey: deviceID)
        brightnessReadingInterfaces.removeValue(forKey: deviceID)
        hasConfirmedDeviceWrite = true
        record("用户确认 \(plan.deviceName) 亮度配置 → \(plan.afterPercent)%；单次提交并读回。")
        let result = await withTaskCancellationHandler {
            await brightnessController.apply(plan)
        } onCancel: { plan.invalidate() }
        guard !Task.isCancelled, operations.isCurrent(ticket), isMonitoring else { return }
        guard result.deviceID == deviceID, result.interfaceID == plan.interface.id else {
            brightnessWriteErrors[deviceID] = "控制结果身份不匹配；结果不确定，请重新读取。"
            return
        }
        if result.outcome == .verified {
            guard let reading = result.readback, reading.hasValue,
                  reading.deviceID == deviceID, reading.interfaceID == plan.interface.id,
                  reading.profileID == plan.before.profileID, reading.regionID == plan.before.regionID,
                  reading.rawBrightness == plan.afterRaw else {
                brightnessWriteErrors[deviceID] = "亮度读回与确认目标不一致；结果不确定，请重新读取。"
                return
            }
            keyboardBrightnessReadouts[deviceID] = reading
            brightnessReadingInterfaces[deviceID] = plan.interface
            if let device = devices.first(where: { $0.id == deviceID }) { rememberSuccessfulReadings(for: device, fields: ["brightness"]) }
        }
        brightnessWriteResults[deviceID] = result
        brightnessResultInterfaces[deviceID] = plan.interface
        record(result.message, isError: result.outcome != .verified, presentError: false)
    }

    public func clearError() { lastError = nil }
    public func snapshotData() throws -> Data {
        try DiagnosticSnapshot(interfaces: interfaces, batteryReadouts: batteryReadouts, mouseReadouts: mouseReadouts, dpiWriteResults: dpiWriteResults, pollingWriteResults: pollingWriteResults,
                               systemBatteryReadings: systemBatteryReadings,
                               pollingReadouts: pollingReadouts,
                               chargingReadouts: chargingReadouts,
                               keyboardBatteryReadouts: keyboardBatteryReadouts, keyboardChargingReadouts: keyboardChargingReadouts,
                               keyboardBrightnessReadouts: keyboardBrightnessReadouts, brightnessWriteResults: brightnessWriteResults,
                               readSummaries: Dictionary(uniqueKeysWithValues: devices.map { ($0.id, readSummary(for: $0.id)) }),
                               activities: Dictionary(uniqueKeysWithValues: devices.map { ($0.id, capabilityActivity(for: $0.id)) }),
                               isMonitoring: isMonitoring, isSuspended: isSuspended,
                               queriesRequested: hasRequestedQueries, systemMetadataRequested: hasRequestedSystemMetadata,
                               automaticBatteryRequested: hasRequestedAutomaticBattery,
                               settingRequested: hasConfirmedDeviceWrite,
                               simulation: isSimulation).jsonData()
    }
    public func reportError(_ message: String) { record(message, isError: true) }

    private func invalidateDisconnectedReads() {
        let changed = operations.reconcile(isSuspended ? [] : devices)
        for id in changed { cancelLiveBrightness(for: id) }
        liveBrightnessControllers = liveBrightnessControllers.filter { !changed.contains($0.key) || $0.value.controller.hasWork }
        for id in changed { lastSuccessfulReadings.removeValue(forKey: id); cancelledReadFields.removeValue(forKey: id); batteryReadouts.removeValue(forKey: id) }
        syncOperationActivity()
        let connected = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        let lighting = Dictionary(uniqueKeysWithValues: devices.compactMap { device in
            ReclusaLightingAdapter.controlInterface(in: device).map { (device.id, $0) }
        })
        keyboardBrightnessReadouts = keyboardBrightnessReadouts.filter { id, reading in
            guard let current = lighting[id], let expected = brightnessReadingInterfaces[id] else { return false }
            return reading.interfaceID == current.id && current.matchesSession(expected)
        }
        brightnessReadingInterfaces = brightnessReadingInterfaces.filter { keyboardBrightnessReadouts[$0.key] != nil }
        for (id, plan) in pendingBrightnessChanges where lighting[id]?.matchesSession(plan.interface) != true {
            cancelBrightnessChange(for: id)
        }
        for (id, plan) in activeBrightnessPlans where lighting[id]?.matchesSession(plan.interface) != true {
            activeBrightnessPlans.removeValue(forKey: id)?.invalidate()
        }
        brightnessWriteErrors = brightnessWriteErrors.filter { lighting[$0.key] != nil }
        brightnessWriteResults = brightnessWriteResults.filter { id, result in
            guard let current = lighting[id], let expected = brightnessResultInterfaces[id] else { return false }
            return result.interfaceID == current.id && current.matchesSession(expected)
        }
        brightnessResultInterfaces = brightnessResultInterfaces.filter { brightnessWriteResults[$0.key] != nil }
        let keyboard = Dictionary(uniqueKeysWithValues: devices.compactMap { device in
            KeyboardPowerReadService.controlInterface(in: device).map { (device.id, $0) }
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
        let pollingRoutes = Dictionary(uniqueKeysWithValues: devices.compactMap { device in
            PollingRateReadService.controlInterface(in: device).map { (device.id, $0) }
        })
        pollingReadouts = pollingReadouts.filter { id, value in
            guard let current = pollingRoutes[id], let expected = pollingReadingInterfaces[id] else { return false }
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
        for (id, plan) in pendingPollingChanges where pollingRoutes[id]?.matchesSession(plan.interface) != true {
            cancelPollingChange(for: id)
        }
        for (id, plan) in activePollingPlans where pollingRoutes[id]?.matchesSession(plan.interface) != true {
            activePollingPlans.removeValue(forKey: id)?.invalidate()
        }
        pollingWriteErrors = pollingWriteErrors.filter { pollingRoutes[$0.key] != nil }
        pollingWriteResults = pollingWriteResults.filter { id, result in
            guard let current = pollingRoutes[id], let expected = pollingResultInterfaces[id] else { return false }
            return result.interfaceID == current.id && current.matchesSession(expected)
        }
        pollingResultInterfaces = pollingResultInterfaces.filter { pollingWriteResults[$0.key] != nil }
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
        liveBrightnessControllers[id]?.controller.hasWork == true || operations.isBusy(id) || pendingDPIChanges[id] != nil || pendingPollingChanges[id] != nil || pendingBrightnessChanges[id] != nil
    }

    /// Waits for the current session's existing work without polling or issuing a query.
    /// Callers still use the ordinary read methods, which recheck availability before I/O.
    public func waitUntilAvailable(for deviceID: String) async -> Bool {
        let id = UUID()
        let available = await withTaskCancellationHandler {
            guard !Task.isCancelled, isMonitoring, !isSuspended,
                  let generation = operations.generation(for: deviceID) else { return false }
            guard isDeviceBusy(deviceID) else { return true }
            return await withCheckedContinuation { continuation in
                // Cancellation may precede registration; its queued MainActor handler
                // cannot be relied on to find the continuation in that case.
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                availabilityWaiters[id] = .init(deviceID: deviceID, generation: generation,
                                                continuation: continuation)
                resumeAvailabilityWaiters()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.availabilityWaiters.removeValue(forKey: id)?.continuation.resume(returning: false)
            }
        }
        return available && !Task.isCancelled
    }

    private func resumeAvailabilityWaiters() {
        for (id, waiter) in availabilityWaiters {
            let valid = isMonitoring && !isSuspended
                && operations.generation(for: waiter.deviceID) == waiter.generation
            guard !valid || !isDeviceBusy(waiter.deviceID) else { continue }
            // Remove before resuming so cancellation and later notifications are idempotent.
            availabilityWaiters.removeValue(forKey: id)?.continuation.resume(returning: valid)
        }
    }

    public func batterySummary(for device: DeviceInfo) -> MenuBatterySummary? {
        guard adapterAssessment(for: device).capability("battery")?.session.state == .succeeded else { return nil }
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
        // This request supersedes every current battery source. Successful
        // samples remain in history; unrelated DPI/charging data stays intact.
        if let previous = mouseReadouts[deviceID] {
            mouseReadouts[deviceID] = .init(deviceID: previous.deviceID, interfaceID: previous.interfaceID,
                readAt: previous.readAt, batteryPercent: nil, dpi: previous.dpi,
                issues: previous.issues.filter { $0.field != "battery" })
        }
        keyboardBatteryReadouts.removeValue(forKey: deviceID)
        if keyboardChargingReadouts[deviceID] == nil { keyboardReadingInterfaces.removeValue(forKey: deviceID) }
        systemBatteryReadings.removeValue(forKey: deviceID)
        batteryReadingDevices.removeValue(forKey: deviceID)
        if origin == .automatic { hasRequestedAutomaticBattery = true }
        if target.backend == .macOSBluetoothBattery { hasRequestedSystemMetadata = true } else { hasRequestedQueries = true }
        record("\(origin == .manual ? "手动" : "定时")读取 \(device.product) 的电量；不查询 DPI 或修改设置。")
        let result: BatteryReading = await performRead(ticket) {
            switch target.backend {
            case .viperV4USB: return await self.batteryReader.read(device)
            case .blackWidowLowProfileUSB, .reclusaMini65USB:
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
        guard !Task.isCancelled, operations.isCurrent(ticket), let current = devices.first(where: { $0.id == deviceID }) else { return nil }
        let reading: BatteryReading
        if result.matches(current), result.backend == target.backend {
            reading = result
        } else {
            // The control session can survive a change to another HID interface.
            // Record the rejected attempt so an older combined battery reading
            // cannot become current again. Do not trust the result's value or time.
            reading = .init(deviceID: current.id, interfaceIDs: current.interfaces.map(\.id).sorted(), backend: target.backend,
                percent: nil, acquiredAt: Date(), source: target.backend == .macOSBluetoothBattery ? .systemCache : .device,
                issue: .init(field: "battery", message: "本次电量响应与当前设备或接口不匹配，已丢弃；请重新读取。", kind: .protocolMismatch))
        }
        batteryReadouts[deviceID] = reading
        rememberSuccessfulReadings(for: current, fields: ["battery"])
        batteryObservations.send(.init(target: target, deviceName: device.product, reading: reading, origin: origin, simulation: isSimulation))
        if let issue = reading.issue { record("\(device.product) · 电量：\(issue.message)", isError: true, presentError: false) }
        return reading
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
              liveBrightnessControllers[deviceID]?.controller.hasWork != true,
              pendingDPIChanges[deviceID] == nil, pendingPollingChanges[deviceID] == nil, pendingBrightnessChanges[deviceID] == nil,
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
        readingKeyboardBrightnessIDs = ids(.keyboardBrightness)
        brightnessWriteBusyIDs = ids(.brightnessPrepare).union(ids(.brightnessApply))
        readingPollingDeviceIDs = ids(.polling)
        pollingWriteBusyIDs = ids(.pollingPrepare).union(ids(.pollingApply))
        readingChargingDeviceIDs = ids(.charging)
        readingKeyboardPowerIDs = ids(.keyboardBattery).union(ids(.keyboardCharging))
        readingSystemBatteryIDs = ids(.systemBattery)
        drainingOperationIDs = Set(devices.filter { operations.isDraining($0.id) }.map(\.id))
        resumeAvailabilityWaiters()
    }

    private func rememberSuccessfulReadings(for device: DeviceInfo, fields: Set<String>) {
        let assessment = AdapterCatalog.assess(device, battery: batteryReadouts[device.id], telemetry: mouseReadouts[device.id],
            systemBattery: systemBatteryReadings[device.id], polling: pollingReadouts[device.id], charging: chargingReadouts[device.id],
            keyboardBattery: keyboardBatteryReadouts[device.id], keyboardCharging: keyboardChargingReadouts[device.id], keyboardBrightness: keyboardBrightnessReadouts[device.id], simulation: isSimulation)
        for capability in assessment.capabilities where fields.contains(capability.id) && capability.session.state == .succeeded {
            if let sample = capability.session.sample { lastSuccessfulReadings[device.id, default: [:]][capability.id] = sample }
        }
    }

    private func clearPollingReads() {
        readingPollingDeviceIDs.removeAll()
        pollingReadouts.removeAll()
        pollingReadingInterfaces.removeAll()
    }

    private func clearBrightnessReads() {
        readingKeyboardBrightnessIDs.removeAll()
        keyboardBrightnessReadouts.removeAll()
        brightnessReadingInterfaces.removeAll()
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
