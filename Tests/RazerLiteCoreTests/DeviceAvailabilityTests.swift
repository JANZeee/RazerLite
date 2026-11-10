import Foundation
import Testing
@testable import RazerLiteCore

private enum AvailabilityFixture {
    static var interfaces: [HIDInterface] {
        [1, 3].map { number in
            HIDInterface(id: UInt64(800 + number), vendorID: 0x1532, productID: 0x02F5,
                product: "Razer Reclusa Mini 65%", manufacturer: "Fixture", transport: "USB",
                locationID: 300, versionNumber: 512, usbDeviceID: 800, usbInterfaceNumber: number,
                usbDeviceRelease: 512, primaryUsagePage: number == 3 ? 12 : 1,
                primaryUsage: number == 3 ? 1 : 6, usages: [], maxInputReportSize: number == 3 ? 0 : 8,
                maxOutputReportSize: 0, maxFeatureReportSize: number == 3 ? 90 : 0,
                registryClass: "Fixture", observedDrivers: [], isVirtual: false)
        }
    }
    static func reading(_ device: DeviceInfo, percent: Int = 100) -> KeyboardBrightnessReading {
        .init(deviceID: device.id, interfaceID: ReclusaLightingAdapter.controlInterface(in: device)?.id,
            profileID: 1, regionID: 5, rawBrightness: UInt8(percent * 255 / 100),
            percent: percent, issue: nil, readAt: .now)
    }
}

@MainActor private final class AvailabilityDiscovery: HIDDiscovering {
    var onChange: (([HIDInterface], String) -> Void)?
    var onError: ((String) -> Void)?
    var interfaces = AvailabilityFixture.interfaces
    func start() { refresh() }
    func refresh() { onChange?(interfaces, "模拟设备可用性") }
    func stop() {}
}

private actor AvailabilityReader: KeyboardBrightnessReadingService {
    private var pending: (DeviceInfo, CheckedContinuation<KeyboardBrightnessReading, Never>)?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func read(_ device: DeviceInfo) async -> KeyboardBrightnessReading {
        calls += 1
        return await withCheckedContinuation {
            pending = (device, $0); waiter?.resume(); waiter = nil
        }
    }
    func waitForRead() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() {
        guard let (device, continuation) = pending else { return }
        pending = nil
        continuation.resume(returning: AvailabilityFixture.reading(device))
    }
}

private actor AvailabilityLiveWriter: KeyboardBrightnessLiveControlling {
    private(set) var values: [Int] = []
    func set(_ device: DeviceInfo, percent: Int, permit: LiveBrightnessPermit) async -> KeyboardBrightnessWriteResult {
        values.append(percent)
        return .init(deviceID: device.id, interfaceID: ReclusaLightingAdapter.controlInterface(in: device)!.id,
            completedAt: .now, outcome: .verified, attemptedWrite: true,
            readback: AvailabilityFixture.reading(device, percent: percent), message: "模拟已验证")
    }
}

private struct AvailabilityPlanController: KeyboardBrightnessControlling {
    func prepare(_ device: DeviceInfo, percent: Int) throws -> KeyboardBrightnessPlan {
        .init(deviceID: device.id, deviceName: device.product, before: AvailabilityFixture.reading(device),
            afterPercent: percent, afterRaw: try ReclusaBrightnessProtocol.raw(forPercent: percent),
            interface: ReclusaLightingAdapter.controlInterface(in: device)!, issuedAt: .now)
    }
    func apply(_ plan: KeyboardBrightnessPlan) async -> KeyboardBrightnessWriteResult {
        Issue.record("等待设备可用性不应触发写入")
        return .init(deviceID: plan.deviceID, interfaceID: plan.interface.id, completedAt: .now,
                     outcome: .notSent, attemptedWrite: false, readback: nil, message: "意外调用")
    }
}

@MainActor private final class AvailabilityWaitProbe {
    var entered = false
    var result: Bool?
}

@MainActor struct DeviceAvailabilityTests {
    private func beginWait(_ manager: DeviceManager, for deviceID: String) async -> (Task<Bool, Never>, AvailabilityWaitProbe) {
        let probe = AvailabilityWaitProbe()
        let task = Task {
            probe.entered = true
            let result = await manager.waitUntilAvailable(for: deviceID)
            probe.result = result
            return result
        }
        while !probe.entered { await Task.yield() }
        await Task.yield()
        return (task, probe)
    }

    @Test func existingPhysicalWorkMustDrainBeforeAWaiterCanStartItsRead() async throws {
        let reader = AvailabilityReader()
        let manager = DeviceManager(discovery: AvailabilityDiscovery(), brightnessReader: reader)
        manager.start()
        let device = try #require(manager.devices.first)
        #expect(await manager.waitUntilAvailable(for: device.id))
        #expect(!(await manager.waitUntilAvailable(for: "missing")))
        let read = Task { await manager.readKeyboardBrightness(for: device.id) }
        await reader.waitForRead()
        read.cancel()
        let (waiting, probe) = await beginWait(manager, for: device.id)
        #expect(probe.result == nil && manager.isDeviceBusy(device.id))
        #expect(await reader.calls == 1)
        await reader.finish(); await read.value
        #expect(await waiting.value)
        #expect(!manager.isDeviceBusy(device.id))
        #expect(await reader.calls == 1) // Waiting itself never invokes a device service.
        manager.stop()
    }

    @Test func cancellingThePageWaitReturnsFalseWithoutCancellingThePhysicalOperation() async throws {
        let reader = AvailabilityReader()
        let manager = DeviceManager(discovery: AvailabilityDiscovery(), brightnessReader: reader)
        manager.start()
        let device = try #require(manager.devices.first)
        let read = Task { await manager.readKeyboardBrightness(for: device.id) }
        await reader.waitForRead()
        let (waiting, probe) = await beginWait(manager, for: device.id)
        #expect(probe.result == nil)
        waiting.cancel()
        #expect(!(await waiting.value))
        #expect(manager.isDeviceBusy(device.id))
        await reader.finish(); await read.value
        #expect(manager.keyboardBrightnessReadouts[device.id]?.percent == 100)
        // A cancellation already present when the async method starts also cannot register a waiter.
        let cancelled = Task { await manager.waitUntilAvailable(for: device.id) }
        cancelled.cancel()
        #expect(!(await cancelled.value))
        manager.stop()
    }

    @Test func sleepDisconnectAndStopTerminateTheOldSessionWaitEvenIfHardwareIsStillBusy() async throws {
        for event in 0..<3 {
            let discovery = AvailabilityDiscovery(), reader = AvailabilityReader()
            let manager = DeviceManager(discovery: discovery, brightnessReader: reader)
            manager.start()
            let device = try #require(manager.devices.first)
            let read = Task { await manager.readKeyboardBrightness(for: device.id) }
            await reader.waitForRead()
            let (waiting, probe) = await beginWait(manager, for: device.id)
            #expect(probe.result == nil)
            switch event {
            case 0: manager.suspend(); manager.resume()
            case 1:
                discovery.interfaces = []; discovery.refresh()
                discovery.interfaces = device.interfaces; discovery.refresh()
            default: manager.stop(); manager.start()
            }
            #expect(!(await waiting.value))
            #expect(manager.isDeviceBusy(device.id))
            await reader.finish(); await read.value
            #expect(manager.keyboardBrightnessReadouts.isEmpty)
            manager.stop()
        }
    }

    @Test func completingTheLiveCoalescingWorkerWakesWaitersAfterItsFinalReadback() async throws {
        let writer = AvailabilityLiveWriter()
        let manager = DeviceManager(discovery: AvailabilityDiscovery(), liveBrightnessService: writer)
        manager.start()
        let device = try #require(manager.devices.first)
        manager.setKeyboardBrightness(for: device.id, percent: 40)
        manager.setKeyboardBrightness(for: device.id, percent: 60)
        let (waiting, probe) = await beginWait(manager, for: device.id)
        #expect(probe.result == nil && manager.liveBrightnessTargets[device.id] == 60)
        #expect(await waiting.value)
        #expect(await writer.values == [60])
        #expect(manager.keyboardBrightnessReadouts[device.id]?.percent == 60)
        #expect(manager.liveBrightnessTargets.isEmpty && !manager.isDeviceBusy(device.id))
        manager.stop()
    }

    @Test func pendingConfirmationBlocksWaitersUntilItsCancellation() async throws {
        let manager = DeviceManager(discovery: AvailabilityDiscovery(), brightnessController: AvailabilityPlanController())
        manager.start()
        let device = try #require(manager.devices.first)
        await manager.prepareBrightnessChange(for: device.id, percent: 50)
        #expect(manager.pendingBrightnessChanges[device.id] != nil)
        let (waiting, probe) = await beginWait(manager, for: device.id)
        #expect(probe.result == nil)
        manager.cancelBrightnessChange(for: device.id)
        #expect(await waiting.value)
        #expect(manager.pendingBrightnessChanges.isEmpty && manager.brightnessWriteResults.isEmpty)
        manager.stop()
    }
}
