import Foundation
import Testing
@testable import RazerLiteCore

private enum ManagerLiveBrightnessFixture {
    static var interfaces: [HIDInterface] {
        [1, 3].map { number in
            HIDInterface(id: UInt64(600 + number), vendorID: 0x1532, productID: 0x02F5,
                product: "Razer Reclusa Mini 65%", manufacturer: "Fixture", transport: "USB",
                locationID: 200, versionNumber: 512, usbDeviceID: 600, usbInterfaceNumber: number,
                usbDeviceRelease: 512, primaryUsagePage: number == 3 ? 12 : 1,
                primaryUsage: number == 3 ? 1 : 6, usages: [], maxInputReportSize: number == 3 ? 0 : 8,
                maxOutputReportSize: 0, maxFeatureReportSize: number == 3 ? 90 : 0,
                registryClass: "Fixture", observedDrivers: [], isVirtual: false)
        }
    }
    static func reading(_ device: DeviceInfo, raw: UInt8 = 255) -> KeyboardBrightnessReading {
        .init(deviceID: device.id, interfaceID: ReclusaLightingAdapter.controlInterface(in: device)?.id,
            profileID: 1, regionID: 5, rawBrightness: raw,
            percent: ReclusaBrightnessProtocol.percent(raw), issue: nil, readAt: .now)
    }
}

@MainActor private final class ManagerLiveBrightnessDiscovery: HIDDiscovering {
    var onChange: (([HIDInterface], String) -> Void)?
    var onError: ((String) -> Void)?
    var interfaces = ManagerLiveBrightnessFixture.interfaces
    func start() { refresh() }
    func refresh() { onChange?(interfaces, "模拟实时亮度设备") }
    func stop() {}
    func reconnect() {
        let previous = interfaces
        interfaces = []; refresh()
        interfaces = previous; refresh()
    }
}

private actor ManagerLiveBrightnessReader: KeyboardBrightnessReadingService {
    let holds: Bool
    private var pending: (DeviceInfo, CheckedContinuation<KeyboardBrightnessReading, Never>)?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    init(holds: Bool = false) { self.holds = holds }
    func read(_ device: DeviceInfo) async -> KeyboardBrightnessReading {
        calls += 1
        guard holds else { return ManagerLiveBrightnessFixture.reading(device) }
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
        continuation.resume(returning: ManagerLiveBrightnessFixture.reading(device))
    }
}

/// Deliberately ignores cancellation until the test releases it, like synchronous IOKit.
private actor ManagerLiveBrightnessWriter: KeyboardBrightnessLiveControlling {
    private struct Pending {
        let device: DeviceInfo
        let percent: Int
        let continuation: CheckedContinuation<KeyboardBrightnessWriteResult, Never>
    }
    private var pending: Pending?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var values: [Int] = []
    private(set) var permits: [LiveBrightnessPermit] = []
    private var active = 0
    private(set) var maximumActive = 0
    func set(_ device: DeviceInfo, percent: Int, permit: LiveBrightnessPermit) async -> KeyboardBrightnessWriteResult {
        values.append(percent); permits.append(permit)
        active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        return await withCheckedContinuation { continuation in
            pending = .init(device: device, percent: percent, continuation: continuation)
            let ready = waiters.filter { $0.0 <= values.count }
            waiters.removeAll { $0.0 <= values.count }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForCalls(_ count: Int) async {
        if values.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func finish(outcome: KeyboardBrightnessWriteOutcome = .verified,
                foreign: Bool = false, wrongRaw: Bool = false) {
        guard let request = pending else { return }
        pending = nil
        let raw = UInt8(request.percent * 255 / 100) + (wrongRaw ? 1 : 0)
        request.continuation.resume(returning: .init(deviceID: foreign ? "foreign" : request.device.id,
            interfaceID: ReclusaLightingAdapter.controlInterface(in: request.device)!.id,
            completedAt: .now, outcome: outcome, attemptedWrite: true,
            readback: outcome == .verified ? ManagerLiveBrightnessFixture.reading(request.device, raw: raw) : nil,
            message: "模拟实时亮度结果"))
    }
}

@MainActor
struct ManagerLiveBrightnessTests {
    private func idle(_ manager: DeviceManager, _ deviceID: String) async throws {
        for _ in 0..<1_000 {
            if !manager.isDeviceBusy(deviceID) { return }
            await Task.yield()
        }
        try #require(!manager.isDeviceBusy(deviceID))
    }
    private func invalidate(_ event: Int, manager: DeviceManager, discovery: ManagerLiveBrightnessDiscovery,
                            deviceID: String) {
        switch event {
        case 0: manager.suspend(); manager.resume()
        case 1: discovery.reconnect()
        case 2: manager.stop(); manager.start()
        case 3: manager.invalidateControlPlans()
        default: manager.cancelLiveBrightness(for: deviceID)
        }
    }

    @Test func discoveryRefreshResumeAndReadingNeverSubmitBrightness() async throws {
        let discovery = ManagerLiveBrightnessDiscovery(), writer = ManagerLiveBrightnessWriter()
        let reader = ManagerLiveBrightnessReader()
        let manager = DeviceManager(discovery: discovery, brightnessReader: reader, liveBrightnessService: writer)
        manager.start(); manager.refresh(); discovery.reconnect(); manager.suspend(); manager.resume()
        let device = try #require(manager.devices.first)
        await manager.readKeyboardBrightness(for: device.id)
        #expect(await reader.calls == 1)
        #expect(await writer.values.isEmpty)
        #expect(manager.keyboardBrightnessReadouts[device.id]?.percent == 100)
        #expect(manager.liveBrightnessTargets.isEmpty && manager.brightnessWriteResults.isEmpty)
        #expect(!manager.isDeviceBusy(device.id))
        manager.stop()
    }

    @Test func rapidSliderEditsKeepLatestTargetAndReserveTheDeviceAgainstReads() async throws {
        let discovery = ManagerLiveBrightnessDiscovery(), writer = ManagerLiveBrightnessWriter()
        let reader = ManagerLiveBrightnessReader()
        let manager = DeviceManager(discovery: discovery, brightnessReader: reader, liveBrightnessService: writer)
        manager.start()
        let device = try #require(manager.devices.first)
        manager.setKeyboardBrightness(for: device.id, percent: 20)
        manager.setKeyboardBrightness(for: device.id, percent: 40)
        manager.setKeyboardBrightness(for: device.id, percent: 60)
        #expect(manager.liveBrightnessTargets[device.id] == 60 && manager.isDeviceBusy(device.id))
        await manager.readKeyboardBrightness(for: device.id)
        #expect(await reader.calls == 0)
        await writer.waitForCalls(1)
        #expect(await writer.values == [60])
        #expect(manager.canAdjustLiveBrightness(for: device.id))
        #expect(manager.brightnessWriteBusyIDs.contains(device.id))
        manager.setKeyboardBrightness(for: device.id, percent: 70)
        manager.setKeyboardBrightness(for: device.id, percent: 80)
        await manager.readKeyboardBrightness(for: device.id)
        #expect(await reader.calls == 0)
        #expect(manager.liveBrightnessTargets[device.id] == 80)
        await writer.finish()
        await writer.waitForCalls(2)
        #expect(await writer.values == [60, 80])
        #expect(manager.liveBrightnessTargets[device.id] == 80)
        await writer.finish()
        try await idle(manager, device.id)
        #expect(await writer.maximumActive == 1)
        #expect(manager.keyboardBrightnessReadouts[device.id]?.percent == 80)
        #expect(manager.brightnessWriteResults[device.id]?.outcome == .verified)
        #expect(manager.liveBrightnessTargets.isEmpty && manager.brightnessWriteBusyIDs.isEmpty)
        manager.stop()
    }

    @Test func anExistingReadPreventsStartingASettingUntilANewExplicitEdit() async throws {
        let writer = ManagerLiveBrightnessWriter(), reader = ManagerLiveBrightnessReader(holds: true)
        let manager = DeviceManager(discovery: ManagerLiveBrightnessDiscovery(), brightnessReader: reader,
                                    liveBrightnessService: writer)
        manager.start()
        let device = try #require(manager.devices.first)
        let readTask = Task { await manager.readKeyboardBrightness(for: device.id) }
        await reader.waitForRead()
        #expect(!manager.canAdjustLiveBrightness(for: device.id))
        manager.setKeyboardBrightness(for: device.id, percent: 40)
        #expect(manager.liveBrightnessTargets.isEmpty)
        await reader.finish(); await readTask.value
        #expect(await writer.values.isEmpty)
        manager.setKeyboardBrightness(for: device.id, percent: 70)
        await writer.waitForCalls(1)
        await writer.finish()
        try await idle(manager, device.id)
        #expect(await writer.values == [70])
        manager.stop()
    }

    @Test func invalidationRevokesPendingEditsAndRejectsLateResultsWhileKeepingReservation() async throws {
        for event in 0..<5 {
            let discovery = ManagerLiveBrightnessDiscovery(), writer = ManagerLiveBrightnessWriter()
            let reader = ManagerLiveBrightnessReader()
            let manager = DeviceManager(discovery: discovery, brightnessReader: reader, liveBrightnessService: writer)
            manager.start()
            let device = try #require(manager.devices.first)
            manager.setKeyboardBrightness(for: device.id, percent: 40)
            await writer.waitForCalls(1)
            manager.setKeyboardBrightness(for: device.id, percent: 60)
            invalidate(event, manager: manager, discovery: discovery, deviceID: device.id)
            let permit = try #require(await writer.permits.first)
            #expect(!permit.isUsable && manager.liveBrightnessTargets.isEmpty)
            #expect(manager.isDeviceBusy(device.id) && manager.drainingOperationIDs.contains(device.id))
            #expect(!manager.canAdjustLiveBrightness(for: device.id))
            manager.setKeyboardBrightness(for: device.id, percent: 80)
            await manager.readKeyboardBrightness(for: device.id)
            #expect(await reader.calls == 0)
            await writer.finish()
            try await idle(manager, device.id)
            #expect(await writer.values == [40])
            #expect(manager.keyboardBrightnessReadouts.isEmpty && manager.brightnessWriteResults.isEmpty)
            #expect(manager.liveBrightnessTargets.isEmpty && manager.drainingOperationIDs.isEmpty)
            #expect(manager.lastSuccessfulReadings[device.id]?["brightness"] == nil)
            // A new explicit interaction may start, but the old queued 60/80 never replays.
            manager.setKeyboardBrightness(for: device.id, percent: 75)
            await writer.waitForCalls(2)
            await writer.finish()
            try await idle(manager, device.id)
            #expect(await writer.values == [40, 75])
            #expect(manager.keyboardBrightnessReadouts[device.id]?.percent == 75)
            manager.stop()
        }
    }

    @Test func invalidationBeforeTheWorkerStartsNeverCallsTheWriteService() async throws {
        for event in 0..<5 {
            let discovery = ManagerLiveBrightnessDiscovery(), writer = ManagerLiveBrightnessWriter()
            let manager = DeviceManager(discovery: discovery, liveBrightnessService: writer)
            manager.start()
            let device = try #require(manager.devices.first)
            manager.setKeyboardBrightness(for: device.id, percent: 40)
            invalidate(event, manager: manager, discovery: discovery, deviceID: device.id)
            try await idle(manager, device.id)
            #expect(await writer.values.isEmpty)
            #expect(manager.liveBrightnessTargets.isEmpty && manager.brightnessWriteResults.isEmpty)
            manager.stop()
        }
    }

    @Test func failuresAndMalformedSuccessClearQueuedTargetsWithoutPublishingSuccess() async throws {
        for mode in 0..<3 {
            let writer = ManagerLiveBrightnessWriter()
            let manager = DeviceManager(discovery: ManagerLiveBrightnessDiscovery(), liveBrightnessService: writer)
            manager.start()
            let device = try #require(manager.devices.first)
            manager.setKeyboardBrightness(for: device.id, percent: 40)
            await writer.waitForCalls(1)
            manager.setKeyboardBrightness(for: device.id, percent: 80)
            await writer.finish(outcome: mode == 0 ? .uncertain : .verified,
                                foreign: mode == 1, wrongRaw: mode == 2)
            try await idle(manager, device.id)
            #expect(await writer.values == [40])
            #expect(manager.keyboardBrightnessReadouts.isEmpty && manager.liveBrightnessTargets.isEmpty)
            #expect(manager.brightnessWriteResults[device.id]?.outcome != .verified)
            if mode != 0 { #expect(manager.brightnessWriteErrors[device.id] != nil) }
            #expect(manager.lastSuccessfulReadings[device.id]?["brightness"] == nil)
            manager.stop()
        }
    }
}
