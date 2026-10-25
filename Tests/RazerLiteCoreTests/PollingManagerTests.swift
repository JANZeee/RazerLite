import Foundation
import Testing
@testable import RazerLiteCore

@MainActor private final class PollingDiscovery: HIDDiscovering {
    var onChange: (([HIDInterface], String) -> Void)?
    var onError: ((String) -> Void)?
    var interfaces: [HIDInterface] = []
    func start() { refresh() }
    func refresh() { onChange?(interfaces, "模拟属性刷新") }
    func stop() {}
    func publish(_ interfaces: [HIDInterface]) { self.interfaces = interfaces; refresh() }
}

private actor DeferredPollingReader: MousePollingReadingService {
    private var pending: [CheckedContinuation<MousePollingReading, Never>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var calls = 0
    func read(_ device: DeviceInfo) async -> MousePollingReading {
        calls += 1
        return await withCheckedContinuation {
            pending.append($0)
            let ready = waiters.filter { $0.0 <= calls }
            waiters.removeAll { $0.0 <= calls }
            for (_, waiter) in ready { waiter.resume() }
        }
    }
    func waitForCall(_ count: Int = 1) async {
        if calls >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func finish(_ value: MousePollingReading) { pending.removeFirst().resume(returning: value) }
}

private actor PollingForbiddenMouseReader: MouseStatusReading {
    private(set) var calls = 0
    func read(_ device: DeviceInfo) async -> MouseTelemetry {
        calls += 1
        return MouseTelemetry(deviceID: device.id, interfaceID: 3, readAt: Date(), batteryPercent: nil, dpi: nil, issues: [])
    }
}

struct PollingManagerTests {
    private func reading(_ device: DeviceInfo, hertz: Int? = 2000, issue: MouseReadIssue? = nil) -> MousePollingReading {
        MousePollingReading(deviceID: device.id, interfaceID: MouseReadService.interfaceID(for: device),
                            readAt: Date(), configuredHertz: hertz, issue: issue)
    }

    @Test @MainActor func manualReadsDeduplicateAndExcludeOtherMouseQueries() async throws {
        let discovery = PollingDiscovery()
        let reader = DeferredPollingReader()
        let mouseReader = PollingForbiddenMouseReader()
        let manager = DeviceManager(discovery: discovery, mouseReader: mouseReader, pollingReader: reader)
        manager.start()
        discovery.publish([MouseReadServiceTests().controlInterface()])
        manager.refresh()
        let device = try #require(manager.devices.first)
        #expect(await reader.calls == 0)
        #expect(manager.readSummary(for: device.id).state == .discovered)
        let first = Task { await manager.readPollingRate(for: device.id) }
        await reader.waitForCall()
        #expect(manager.readSummary(for: device.id).state == .reading)
        await manager.readPollingRate(for: device.id)
        await manager.readMouseState(for: device.id)
        #expect(await reader.calls == 1)
        #expect(await mouseReader.calls == 0)
        await reader.finish(reading(device))
        await first.value
        #expect(manager.pollingReadouts[device.id]?.configuredHertz == 2000)
        #expect(manager.readingPollingDeviceIDs.isEmpty)
        #expect(manager.readSummary(for: device.id).state == .deviceResponse)
        #expect(String(decoding: try manager.snapshotData(), as: UTF8.self).contains("configuredHertz"))
        let second = Task { await manager.readPollingRate(for: device.id) }
        await reader.waitForCall(2)
        #expect(manager.pollingReadouts.isEmpty)
        await reader.finish(reading(device, hertz: nil, issue: MouseReadIssue(field: "pollingRate", message: "模拟失败", kind: .timeout)))
        await second.value
        #expect(manager.pollingReadouts[device.id]?.configuredHertz == nil)
        #expect(manager.readSummary(for: device.id).state == .unconfirmed)
        #expect(manager.lastError == nil)
        manager.stop()
    }

    @Test @MainActor func lateResponseAfterSameIDReconnectOrSleepCannotUpdateNewSession() async throws {
        let discovery = PollingDiscovery()
        let reader = DeferredPollingReader()
        let manager = DeviceManager(discovery: discovery, pollingReader: reader)
        let interface = MouseReadServiceTests().controlInterface()
        manager.start()
        discovery.publish([interface])
        let device = try #require(manager.devices.first)
        let first = Task { await manager.readPollingRate(for: device.id) }
        await reader.waitForCall()
        discovery.publish([])
        discovery.publish([interface])
        await reader.finish(reading(device))
        await first.value
        #expect(manager.pollingReadouts.isEmpty)
        let second = Task { await manager.readPollingRate(for: device.id) }
        await reader.waitForCall(2)
        manager.suspend()
        #expect(manager.readSummary(for: device.id).state == .suspended)
        manager.resume()
        await reader.finish(reading(device))
        await second.value
        #expect(manager.pollingReadouts.isEmpty)
        #expect(await reader.calls == 2)
        let third = Task { await manager.readPollingRate(for: device.id) }
        await reader.waitForCall(3)
        manager.stop()
        await reader.finish(reading(device))
        await third.value
        #expect(manager.pollingReadouts.isEmpty && manager.readingPollingDeviceIDs.isEmpty)
    }

    @Test @MainActor func fingerprintChangeClearsCompletedPollingEvenWithSameRegistryID() async throws {
        let discovery = PollingDiscovery()
        let reader = DeferredPollingReader()
        let manager = DeviceManager(discovery: discovery, pollingReader: reader)
        let original = MouseReadServiceTests().controlInterface()
        manager.start()
        discovery.publish([original])
        let device = try #require(manager.devices.first)
        let task = Task { await manager.readPollingRate(for: device.id) }
        await reader.waitForCall()
        await reader.finish(reading(device))
        await task.value
        #expect(manager.pollingReadouts.count == 1)
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        fields["versionNumber"] = 0x0102
        let changed = try JSONDecoder().decode(HIDInterface.self, from: JSONSerialization.data(withJSONObject: fields))
        discovery.publish([changed])
        #expect(manager.pollingReadouts.isEmpty)
        manager.stop()
    }
}

struct DeviceReadSummaryTests {
    @Test func systemCacheNeverClaimsDeviceResponseAndErrorsNeverClaimSleepOrOffline() {
        let system = SystemBatteryReading(deviceID: "test", interfaceIDs: [1], acquiredAt: Date(),
                                          percent: 0, source: .macOSBluetoothSnapshot, issue: nil)
        #expect(DeviceReadSummary.assess(systemBattery: system).state == .systemMetadata)
        let failed = MouseTelemetry(deviceID: "test", interfaceID: 1, readAt: Date(), batteryPercent: nil, dpi: nil,
                                    issues: [MouseReadIssue(field: "battery", message: "模拟超时", kind: .timeout)])
        #expect(DeviceReadSummary.assess(mouse: failed).state == .unconfirmed)
        #expect(DeviceReadSummary.assess(mouse: failed, systemBattery: system).state == .partial)
        #expect(DeviceReadSummary.assess(systemBattery: system, isReading: true).state == .reading)
        #expect(DeviceReadSummary.assess(systemBattery: system, isSuspended: true).state == .suspended)
        let withoutSource = SystemBatteryReading(deviceID: "test", interfaceIDs: [1], acquiredAt: Date(),
                                                 percent: 50, source: nil, issue: nil)
        #expect(DeviceReadSummary.assess(systemBattery: withoutSource).state == .unconfirmed)
        let withFailure = SystemBatteryReading(deviceID: "test", interfaceIDs: [1], acquiredAt: Date(),
                                               percent: 50, source: .macOSBluetoothSnapshot, issue: nil, failureKind: .unknown)
        #expect(DeviceReadSummary.assess(systemBattery: withFailure).state == .partial)
    }
}
