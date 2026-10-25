import Foundation
import Testing
@testable import RazerLiteCore

@MainActor
private final class BatteryDiscovery: HIDDiscovering {
    var onChange: (([HIDInterface], String) -> Void)?
    var onError: ((String) -> Void)?
    var interfaces: [HIDInterface] = []
    func start() { refresh() }
    func refresh() { onChange?(interfaces, "属性刷新") }
    func stop() {}
    func publish(_ device: DeviceInfo?) { interfaces = device?.interfaces ?? []; refresh() }
}

private actor DeferredBatteryReader: SystemBatteryReadingService {
    private var pending: [CheckedContinuation<SystemBatteryReading, Never>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var calls = 0
    func read(_ device: DeviceInfo) async -> SystemBatteryReading {
        calls += 1
        return await withCheckedContinuation {
            pending.append($0)
            let ready = waiters.filter { $0.0 <= calls }
            waiters.removeAll { $0.0 <= calls }
            for (_, continuation) in ready { continuation.resume() }
        }
    }
    func waitForCall(_ count: Int = 1) async {
        if calls >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func finish(_ reading: SystemBatteryReading) { pending.removeFirst().resume(returning: reading) }
}

struct SystemBatteryManagerTests {
    private func reading(_ device: DeviceInfo, percent: Int? = 73, issue: String? = nil) -> SystemBatteryReading {
        SystemBatteryReading(deviceID: device.id, interfaceIDs: device.interfaces.map(\.id).sorted(), acquiredAt: Date(),
                             percent: percent, source: percent != nil ? .macOSBluetoothSnapshot : nil, issue: issue)
    }

    @Test @MainActor func readsAreExplicitDeduplicatedAndFailedRefreshClearsPreviousValue() async throws {
        let discovery = BatteryDiscovery()
        let reader = DeferredBatteryReader()
        let device = SystemBatteryTests.device()
        let manager = DeviceManager(discovery: discovery, systemBatteryReader: reader)
        manager.start()
        discovery.publish(device)
        manager.refresh()
        #expect(await reader.calls == 0)
        let first = Task { await manager.readSystemBattery(for: device.id) }
        await reader.waitForCall()
        #expect(manager.readingSystemBatteryIDs.contains(device.id))
        await manager.readSystemBattery(for: device.id)
        #expect(await reader.calls == 1)
        await reader.finish(reading(device))
        await first.value
        #expect(manager.systemBatteryReadings[device.id]?.percent == 73)
        let second = Task { await manager.readSystemBattery(for: device.id) }
        await reader.waitForCall(2)
        #expect(manager.systemBatteryReadings[device.id] == nil)
        await reader.finish(reading(device, percent: nil, issue: "模拟未发布电量"))
        await second.value
        #expect(manager.systemBatteryReadings[device.id]?.percent == nil)
        #expect(manager.systemBatteryReadings[device.id]?.issue != nil)
        #expect(manager.readingSystemBatteryIDs.isEmpty && manager.lastError == nil)
        manager.stop()
        #expect(manager.systemBatteryReadings.isEmpty)
    }

    @Test @MainActor func disconnectedAndSameIDReconnectedSessionsRejectLateResult() async {
        let discovery = BatteryDiscovery()
        let reader = DeferredBatteryReader()
        let device = SystemBatteryTests.device()
        let manager = DeviceManager(discovery: discovery, systemBatteryReader: reader)
        manager.start()
        discovery.publish(device)
        let task = Task { await manager.readSystemBattery(for: device.id) }
        await reader.waitForCall()
        discovery.publish(nil)
        discovery.publish(device)
        await reader.finish(reading(device))
        await task.value
        #expect(manager.systemBatteryReadings.isEmpty && manager.readingSystemBatteryIDs.isEmpty)
        manager.stop()
    }

    @Test @MainActor func identityChangeClearsCompletedReadingEvenIfRegistryIDIsReused() async {
        let discovery = BatteryDiscovery()
        let reader = DeferredBatteryReader()
        let device = SystemBatteryTests.device()
        let manager = DeviceManager(discovery: discovery, systemBatteryReader: reader)
        manager.start()
        discovery.publish(device)
        let task = Task { await manager.readSystemBattery(for: device.id) }
        await reader.waitForCall()
        await reader.finish(reading(device))
        await task.value
        #expect(manager.systemBatteryReadings.count == 1)
        discovery.publish(SystemBatteryTests.device(pid: 0x00E6))
        #expect(manager.systemBatteryReadings.isEmpty)
        manager.stop()
    }

    @Test @MainActor func sleepInvalidatesInFlightReadsAndWakeDoesNotQueryAutomatically() async {
        let discovery = BatteryDiscovery()
        let reader = DeferredBatteryReader()
        let device = SystemBatteryTests.device()
        let manager = DeviceManager(discovery: discovery, systemBatteryReader: reader)
        manager.start()
        discovery.publish(device)
        let task = Task { await manager.readSystemBattery(for: device.id) }
        await reader.waitForCall()
        manager.suspend()
        #expect(manager.isSuspended && manager.systemBatteryReadings.isEmpty && manager.readingSystemBatteryIDs.isEmpty)
        await manager.readSystemBattery(for: device.id)
        #expect(await reader.calls == 1)
        manager.resume()
        await reader.finish(reading(device))
        await task.value
        #expect(!manager.isSuspended && manager.systemBatteryReadings.isEmpty)
        #expect(await reader.calls == 1)
        let second = Task { await manager.readSystemBattery(for: device.id) }
        await reader.waitForCall(2)
        manager.stop()
        await reader.finish(reading(device))
        await second.value
        #expect(manager.systemBatteryReadings.isEmpty)
    }
}
