import Foundation
import Testing
@testable import RazerLiteCore

@MainActor private final class ChargingDiscovery: HIDDiscovering {
    var onChange: (([HIDInterface], String) -> Void)?
    var onError: ((String) -> Void)?
    var interfaces = [MouseReadServiceTests().controlInterface()]
    func start() { refresh() }
    func refresh() { onChange?(interfaces, "模拟属性刷新") }
    func stop() {}
    func publish(_ value: [HIDInterface]) { interfaces = value; refresh() }
}

private actor DeferredChargingReader: MouseChargingReadingService {
    var pending: CheckedContinuation<MouseChargingReading, Never>?
    var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var calls = 0
    func read(_ device: DeviceInfo) async -> MouseChargingReading {
        calls += 1
        return await withCheckedContinuation {
            pending = $0
            let ready = waiters.filter { $0.0 <= calls }
            waiters.removeAll { $0.0 <= calls }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForCall(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func finish(_ result: MouseChargingReading) { pending?.resume(returning: result); pending = nil }
}

private actor ChargingForbiddenReader: MouseStatusReading, MousePollingReadingService, MouseDPIControlling {
    private(set) var calls = 0
    func read(_ device: DeviceInfo) async -> MouseTelemetry {
        calls += 1
        return MouseTelemetry(deviceID: device.id, interfaceID: 3, readAt: Date(), batteryPercent: nil, dpi: nil, issues: [])
    }
    func read(_ device: DeviceInfo) async -> MousePollingReading {
        calls += 1
        return MousePollingReading(deviceID: device.id, interfaceID: 3, readAt: Date(), configuredHertz: nil, issue: nil)
    }
    func prepare(_ device: DeviceInfo, x: Int, y: Int) async throws -> MouseDPIPlan { calls += 1; throw MouseQueryError.unsupportedDevice }
    func apply(_ plan: MouseDPIPlan) async -> MouseDPIWriteResult { fatalError("No write is authorized by these tests") }
}

struct ChargingManagerTests {
    private func result(_ device: DeviceInfo, failure: Bool = false) -> MouseChargingReading {
        MouseChargingReading(deviceID: device.id, interfaceID: 3, readAt: Date(), state: failure ? nil : .notCharging,
                               issue: failure ? MouseReadIssue(field: "charging", message: "模拟超时", kind: .timeout) : nil)
    }

    @Test @MainActor func onlyExplicitReadsRunAndTheyExcludeOtherDeviceOperations() async throws {
        let discovery = ChargingDiscovery(), reader = DeferredChargingReader(), forbidden = ChargingForbiddenReader()
        let manager = DeviceManager(discovery: discovery, mouseReader: forbidden, dpiController: forbidden,
                                    pollingReader: forbidden, chargingReader: reader)
        manager.start(); manager.refresh()
        let device = try #require(manager.devices.first)
        #expect(await reader.calls == 0)
        let task = Task { await manager.readChargingState(for: device.id) }
        await reader.waitForCall(1)
        #expect(manager.readSummary(for: device.id).state == .reading)
        await manager.readChargingState(for: device.id)
        await manager.readMouseState(for: device.id)
        await manager.readPollingRate(for: device.id)
        await manager.prepareDPIChange(for: device.id, x: 800, y: 800)
        #expect(await forbidden.calls == 0)
        #expect(await reader.calls == 1)
        await reader.finish(result(device)); await task.value
        #expect(manager.chargingReadouts[device.id]?.state == .notCharging)
        #expect(manager.readSummary(for: device.id).state == .deviceResponse)
        let next = Task { await manager.readChargingState(for: device.id) }
        await reader.waitForCall(2)
        #expect(manager.chargingReadouts.isEmpty)
        await reader.finish(result(device, failure: true)); await next.value
        #expect(manager.readSummary(for: device.id).state == .unconfirmed)
        #expect(manager.lastError == nil)
        manager.stop()
    }

    @Test @MainActor func reconnectSleepAndStopDiscardLateResponses() async throws {
        for event in 0..<3 {
            let discovery = ChargingDiscovery(), reader = DeferredChargingReader()
            let manager = DeviceManager(discovery: discovery, chargingReader: reader)
            manager.start()
            let device = try #require(manager.devices.first)
            let task = Task { await manager.readChargingState(for: device.id) }
            await reader.waitForCall(1)
            if event == 0 { discovery.publish([]); discovery.publish(device.interfaces) }
            if event == 1 { manager.suspend(); manager.resume() }
            if event == 2 { manager.stop() }
            await reader.finish(result(device)); await task.value
            #expect(manager.chargingReadouts.isEmpty && manager.readingChargingDeviceIDs.isEmpty)
            #expect(await reader.calls == 1)
            manager.stop()
        }
    }

    @Test @MainActor func changedInterfaceFingerprintClearsPreviouslySuccessfulReading() async throws {
        let discovery = ChargingDiscovery(), reader = DeferredChargingReader()
        let manager = DeviceManager(discovery: discovery, chargingReader: reader)
        manager.start()
        let device = try #require(manager.devices.first)
        let task = Task { await manager.readChargingState(for: device.id) }
        await reader.waitForCall(1)
        await reader.finish(result(device)); await task.value
        #expect(manager.chargingReadouts.count == 1)
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(device.interfaces[0])) as? [String: Any])
        fields["versionNumber"] = 0x0102
        let changed = try JSONDecoder().decode(HIDInterface.self, from: JSONSerialization.data(withJSONObject: fields))
        discovery.publish([changed])
        #expect(manager.chargingReadouts.isEmpty)
        #expect(manager.readSummary(for: device.id).state == .discovered)
        manager.stop()
    }
}
