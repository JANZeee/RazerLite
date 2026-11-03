import Combine
import Foundation
import Testing
@testable import RazerLiteCore

private final class BatteryFeatureFixture: HIDFeatureTransport, @unchecked Sendable {
    var frames: [[UInt8]] = []
    var closes = 0
    let reply: [UInt8]
    init(_ reply: [UInt8]) { self.reply = reply }
    func send(_ bytes: [UInt8], reportID: Int) throws { #expect(reportID == 0); frames.append(bytes) }
    func receive(reportID: Int, length: Int) throws -> [UInt8] { #expect(reportID == 0 && length == 90); return reply }
    func close() { closes += 1 }
}

@MainActor private final class BatteryTestDiscovery: HIDDiscovering {
    var onChange: (([HIDInterface], String) -> Void)?
    var onError: ((String) -> Void)?
    var interfaces = [MouseReadServiceTests().controlInterface()]
    func start() { refresh() }
    func refresh() { onChange?(interfaces, "测试电量接口") }
    func stop() {}
}
private actor BatteryGate: BatteryReadingService {
    private var pending: CheckedContinuation<BatteryReading, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func read(_ device: DeviceInfo) async -> BatteryReading {
        calls += 1
        return await withCheckedContinuation { pending = $0; started?.resume(); started = nil }
    }
    func waitForCall() async { if pending != nil { return }; await withCheckedContinuation { started = $0 } }
    func finish(_ value: BatteryReading) { pending?.resume(returning: value); pending = nil }
}

@Suite(.timeLimit(.minutes(1)))
struct BatteryReadingTests {
    @Test func standaloneBatteryDiagnosticsDescribeActualBackendEvenOnFailure() throws {
        for backend in [DeviceReadBackend.viperV4USB, .blackWidowLowProfileUSB, .macOSBluetoothBattery] {
            for failed in [false, true] {
                let reading = BatteryReading(deviceID: "fixture", interfaceIDs: [1], backend: backend,
                    percent: failed ? nil : 0, acquiredAt: Date(timeIntervalSince1970: 1000),
                    source: backend == .macOSBluetoothBattery ? .systemCache : .device,
                    issue: failed ? .init(field: "battery", message: "fixture timeout", kind: .timeout) : nil)
                let snapshot = DiagnosticSnapshot(interfaces: [], batteryReadouts: ["fixture": reading])
                let expected = backend == .macOSBluetoothBattery
                    ? "system-metadata-read; no feature queries requested" : "manual-status-queries; no setting commands"
                #expect(snapshot.mode == expected)
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let decoded = try decoder.decode(DiagnosticSnapshot.self, from: snapshot.jsonData())
                #expect(decoded.mode == expected)
                #expect(decoded.batteryReadouts?["fixture"] == reading)
            }
        }
    }

    @Test func batteryDiagnosticModesPreserveOperationPriorityAndEmptyDefaults() {
        func reading(_ backend: DeviceReadBackend) -> BatteryReading {
            .init(deviceID: "fixture", interfaceIDs: [], backend: backend, percent: 50,
                  acquiredAt: .now, source: backend == .macOSBluetoothBattery ? .systemCache : .device, issue: nil)
        }
        let values = ["usb": reading(.viperV4USB), "bluetooth": reading(.macOSBluetoothBattery)]
        #expect(DiagnosticSnapshot(interfaces: [], batteryReadouts: values).mode == "manual-status-queries; no setting commands")
        #expect(DiagnosticSnapshot(interfaces: [], batteryReadouts: values, automaticBatteryRequested: true).mode == "opt-in-battery-and-manual-reads; no setting commands")
        #expect(DiagnosticSnapshot(interfaces: [], batteryReadouts: values, settingRequested: true).mode.hasPrefix("manual-device-operations"))
        #expect(DiagnosticSnapshot(interfaces: [], batteryReadouts: values, simulation: true).mode == "simulation-only; no device communication")
        #expect(DiagnosticSnapshot(interfaces: []).mode == "discovery-only; no feature queries requested")
        #expect(DiagnosticSnapshot(interfaces: [], queriesRequested: true).mode == "manual-status-queries; no setting commands")
    }

    @Test func viperBatteryOnlySendsOneReviewedGetAndClosesWithoutDPIOrCharging() async {
        let device = DeviceInfo.group([MouseReadServiceTests().controlInterface()])[0]
        let transport = BatteryFeatureFixture(ViperReadProtocolTests().response(.battery, payload: [0, 0]))
        let value = await ViperBatteryReadService { _ in transport }.read(device)
        #expect(value.isValid && value.percent == 0 && value.source == .device)
        #expect(transport.frames == [ViperV4ReadProtocol.request(.battery)])
        #expect(transport.closes == 1)
    }
    @Test func timeoutClosesAndUnsupportedModelNeverOpensAFeatureTransport() async {
        let device = DeviceInfo.group([MouseReadServiceTests().controlInterface()])[0]
        let transport = BatteryFeatureFixture(ViperReadProtocolTests().response(.battery, payload: [0, 0], status: 4))
        let value = await ViperBatteryReadService { _ in transport }.read(device)
        #expect(!value.isValid && value.issue?.kind == .timeout && transport.closes == 1 && transport.frames.count == 1)
        let unsupported = DeviceInfo.group([MouseReadServiceTests().controlInterface(pid: 0x00E5)])[0]
        let rejected = await ViperBatteryReadService { _ in Issue.record("Unsupported PID opened transport"); return transport }.read(unsupported)
        #expect(!rejected.isValid && transport.frames.count == 1)
    }
    @Test @MainActor func dedicatedReadDeduplicatesPreservesDPIAndDoesNotBypassAutomaticAcceptance() async throws {
        let discovery = BatteryTestDiscovery(), gate = BatteryGate()
        let manager = DeviceManager(discovery: discovery, batteryReader: gate)
        manager.start()
        let device = try #require(manager.devices.first)
        #expect(await manager.readBattery(for: device.id, origin: .automatic) == nil)
        #expect(await gate.calls == 0)
        let task = Task { await manager.readBattery(for: device.id) }
        await gate.waitForCall()
        #expect(manager.readSummary(for: device.id).state == .reading)
        #expect(await manager.readBattery(for: device.id) == nil)
        #expect(await gate.calls == 1)
        let response = BatteryReading(deviceID: device.id, interfaceIDs: device.interfaces.map(\.id).sorted(), backend: .viperV4USB,
            percent: 0, acquiredAt: Date(timeIntervalSince1970: 2000), source: .device, issue: nil)
        await gate.finish(response); await task.value
        #expect(manager.batterySummary(for: device)?.percent == 0)
        #expect(manager.adapterAssessment(for: device).capability("battery")?.session.value == "0%")
        manager.stop()
    }
    @Test @MainActor func disconnectDiscardsLateBatteryAndCannotGenerateAnObservation() async throws {
        let discovery = BatteryTestDiscovery(), gate = BatteryGate()
        let manager = DeviceManager(discovery: discovery, batteryReader: gate)
        manager.start()
        let device = try #require(manager.devices.first)
        var events = 0
        let subscription = manager.batteryObservations.sink { _ in events += 1 }
        let task = Task { await manager.readBattery(for: device.id) }
        await gate.waitForCall()
        discovery.interfaces = []; discovery.refresh()
        await gate.finish(.init(deviceID: device.id, interfaceIDs: device.interfaces.map(\.id).sorted(), backend: .viperV4USB,
                               percent: 10, acquiredAt: .now, source: .device, issue: nil))
        await task.value
        #expect(events == 0 && manager.batteryReadouts.isEmpty)
        subscription.cancel(); manager.stop()
    }
    #if DEBUG
    @Test @MainActor func batteryOnlyRefreshKeepsDPITimestampAndDiagnosticsAgreeWithUI() async throws {
        let session = try OfflineScenarioSession()
        await session.load(.mouse)
        let manager = session.manager, device = try #require(session.manager.devices.first)
        let old = try #require(manager.mouseReadouts[device.id])
        await manager.readBattery(for: device.id)
        #expect(manager.mouseReadouts[device.id]?.dpi == old.dpi && manager.mouseReadouts[device.id]?.readAt == old.readAt)
        #expect(manager.batterySummary(for: device)?.percent == 15)
        #expect(manager.adapterAssessment(for: device).capability("battery")?.session.value == "15%")
        #expect(manager.readSummary(for: device.id).state == .deviceResponse)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(DiagnosticSnapshot.self, from: manager.snapshotData())
        #expect(snapshot.batteryReadouts?[device.id]?.percent == 15)
        #expect(snapshot.adapterAssessments?[device.id]?.capability("battery")?.session.value == "15%")
        manager.stop()
    }
    #endif
}
