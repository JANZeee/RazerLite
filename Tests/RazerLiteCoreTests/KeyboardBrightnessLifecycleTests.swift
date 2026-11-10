import Foundation
import Testing
@testable import RazerLiteCore

private enum BrightnessLifecycleFixture {
    static func interfaces() -> [HIDInterface] {
        [1, 3].map { number in
            HIDInterface(id: UInt64(400 + number), vendorID: 0x1532, productID: 0x02F5,
                product: "Razer Reclusa Mini 65%", manufacturer: "Fixture", transport: "USB",
                locationID: 100, versionNumber: 512, usbDeviceID: 400, usbInterfaceNumber: number,
                usbDeviceRelease: 512, primaryUsagePage: number == 3 ? 12 : 1,
                primaryUsage: number == 3 ? 1 : 6, usages: [], maxInputReportSize: number == 3 ? 0 : 8,
                maxOutputReportSize: 0, maxFeatureReportSize: number == 3 ? 90 : 0,
                registryClass: "Fixture", observedDrivers: [], isVirtual: false)
        }
    }
    static func reading(_ device: DeviceInfo, raw: UInt8 = 255, region: UInt8 = 5) -> KeyboardBrightnessReading {
        .init(deviceID: device.id, interfaceID: ReclusaLightingAdapter.controlInterface(in: device)?.id,
            profileID: 1, regionID: region, rawBrightness: raw,
            percent: ReclusaBrightnessProtocol.percent(raw), issue: nil, readAt: .now)
    }
}

@MainActor private final class BrightnessLifecycleDiscovery: HIDDiscovering {
    var onChange: (([HIDInterface], String) -> Void)?
    var onError: ((String) -> Void)?
    var interfaces = BrightnessLifecycleFixture.interfaces()
    func start() { refresh() }
    func refresh() { onChange?(interfaces, "模拟属性") }
    func stop() {}
}

private actor HeldBrightnessReader: KeyboardBrightnessReadingService {
    private var continuation: CheckedContinuation<KeyboardBrightnessReading, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var device: DeviceInfo?
    private(set) var count = 0
    func read(_ device: DeviceInfo) async -> KeyboardBrightnessReading {
        count += 1; self.device = device
        return await withCheckedContinuation {
            continuation = $0; waiter?.resume(); waiter = nil
        }
    }
    func waitForRead() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() {
        guard let device else { return }
        continuation?.resume(returning: BrightnessLifecycleFixture.reading(device))
        continuation = nil
    }
}

private struct InvalidBrightnessReader: KeyboardBrightnessReadingService {
    let foreign: Bool
    func read(_ device: DeviceInfo) async -> KeyboardBrightnessReading {
        .init(deviceID: foreign ? "foreign" : device.id,
            interfaceID: ReclusaLightingAdapter.controlInterface(in: device)?.id,
            profileID: 1, regionID: 5, rawBrightness: foreign ? 255 : nil,
            percent: foreign ? 100 : nil, issue: nil, readAt: .now)
    }
}

private actor HeldBrightnessController: KeyboardBrightnessControlling {
    private var continuation: CheckedContinuation<KeyboardBrightnessWriteResult, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var plan: KeyboardBrightnessPlan?
    private(set) var prepares = 0
    private(set) var applies = 0
    func prepare(_ device: DeviceInfo, percent: Int) throws -> KeyboardBrightnessPlan {
        prepares += 1
        return .init(deviceID: device.id, deviceName: device.product, before: BrightnessLifecycleFixture.reading(device),
            afterPercent: percent, afterRaw: try ReclusaBrightnessProtocol.raw(forPercent: percent),
            interface: ReclusaLightingAdapter.controlInterface(in: device)!, issuedAt: .now)
    }
    func apply(_ plan: KeyboardBrightnessPlan) async -> KeyboardBrightnessWriteResult {
        applies += 1; self.plan = plan
        return await withCheckedContinuation {
            continuation = $0; waiter?.resume(); waiter = nil
        }
    }
    func waitForApply() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(foreignResult: Bool = false, wrongReadback: Bool = false) {
        guard let plan else { return }
        let reading = KeyboardBrightnessReading(deviceID: plan.deviceID, interfaceID: plan.interface.id,
            profileID: 1, regionID: wrongReadback ? 6 : 5, rawBrightness: plan.afterRaw,
            percent: ReclusaBrightnessProtocol.percent(plan.afterRaw), issue: nil, readAt: .now)
        continuation?.resume(returning: .init(deviceID: foreignResult ? "foreign" : plan.deviceID,
            interfaceID: plan.interface.id, completedAt: .now, outcome: .verified,
            attemptedWrite: true, readback: reading, message: "模拟迟到或错误结果"))
        continuation = nil
    }
}

@MainActor struct KeyboardBrightnessLifecycleTests {
    @Test func malformedOrForeignReadPublishesFailureWithoutSuccessLog() async throws {
        for foreign in [true, false] {
            let manager = DeviceManager(discovery: BrightnessLifecycleDiscovery(),
                                        brightnessReader: InvalidBrightnessReader(foreign: foreign))
            manager.start()
            let device = try #require(manager.devices.first)
            await manager.readKeyboardBrightness(for: device.id)
            let reading = try #require(manager.keyboardBrightnessReadouts[device.id])
            #expect(reading.issue?.kind == (foreign ? .protocolMismatch : .invalidData))
            #expect(reading.rawBrightness == nil && reading.percent == nil && !reading.hasValue)
            #expect(manager.logs.last?.isError == true)
            #expect(manager.adapterAssessment(for: device).capability("brightness")?.session.state == .failed)
            #expect(manager.readSummary(for: device.id).state == .unconfirmed)
            manager.stop()
        }
    }

    @Test func lateReadCannotRepopulateAfterSleepReconnectStopOrCancellation() async throws {
        for event in 0..<4 {
            let discovery = BrightnessLifecycleDiscovery()
            let reader = HeldBrightnessReader()
            let manager = DeviceManager(discovery: discovery, brightnessReader: reader)
            manager.start()
            let device = try #require(manager.devices.first)
            let task = Task { await manager.readKeyboardBrightness(for: device.id) }
            await reader.waitForRead()
            switch event {
            case 0: manager.suspend(); manager.resume()
            case 1:
                discovery.interfaces = []; discovery.refresh()
                discovery.interfaces = device.interfaces; discovery.refresh()
            case 2: manager.stop(); manager.start()
            default: task.cancel()
            }
            #expect(manager.isDeviceBusy(device.id))
            await manager.readKeyboardBrightness(for: device.id)
            #expect(await reader.count == 1)
            await reader.finish(); await task.value
            #expect(manager.keyboardBrightnessReadouts.isEmpty)
            #expect(!manager.isDeviceBusy(device.id))
            #expect(manager.batteryTargets.isEmpty)
            manager.stop()
        }
    }

    @Test func lateApplyKeepsReservationAndCannotPublishAfterInvalidation() async throws {
        for event in 0..<5 {
            let discovery = BrightnessLifecycleDiscovery()
            let controller = HeldBrightnessController()
            let manager = DeviceManager(discovery: discovery, brightnessController: controller)
            manager.start()
            let device = try #require(manager.devices.first)
            await manager.prepareBrightnessChange(for: device.id, percent: 40)
            let plan = try #require(manager.pendingBrightnessChanges[device.id])
            let task = Task { await manager.confirmBrightnessChange(for: device.id, planID: plan.id) }
            await controller.waitForApply()
            switch event {
            case 0: manager.suspend(); manager.resume()
            case 1:
                discovery.interfaces = []; discovery.refresh()
                discovery.interfaces = device.interfaces; discovery.refresh()
            case 2: manager.stop(); manager.start()
            case 3: manager.invalidateControlPlans()
            default: task.cancel()
            }
            #expect(!plan.isUsable)
            #expect(manager.isDeviceBusy(device.id))
            await manager.prepareBrightnessChange(for: device.id, percent: 50)
            #expect(await controller.prepares == 1)
            await controller.finish(); await task.value
            #expect(manager.keyboardBrightnessReadouts.isEmpty && manager.brightnessWriteResults.isEmpty)
            #expect(!manager.isDeviceBusy(device.id) && manager.pendingBrightnessChanges.isEmpty)
            manager.stop()
        }
    }

    @Test func foreignOrMismatchedVerifiedResultNeverBecomesCurrent() async throws {
        for foreign in [true, false] {
            let discovery = BrightnessLifecycleDiscovery()
            let controller = HeldBrightnessController()
            let manager = DeviceManager(discovery: discovery, brightnessController: controller)
            manager.start()
            let device = try #require(manager.devices.first)
            await manager.prepareBrightnessChange(for: device.id, percent: 50)
            let plan = try #require(manager.pendingBrightnessChanges[device.id])
            await manager.confirmBrightnessChange(for: device.id, planID: UUID())
            #expect(await controller.applies == 0)
            let task = Task { await manager.confirmBrightnessChange(for: device.id, planID: plan.id) }
            await controller.waitForApply()
            await controller.finish(foreignResult: foreign, wrongReadback: !foreign)
            await task.value
            #expect(manager.keyboardBrightnessReadouts.isEmpty && manager.brightnessWriteResults.isEmpty)
            #expect(manager.brightnessWriteErrors[device.id] != nil)
            #expect(manager.adapterAssessment(for: device).capability("brightness")?.session.state != .succeeded)
            manager.stop()
        }
    }

    @Test func cancellationBeforeConfirmationNeverCallsControllerApply() async throws {
        let discovery = BrightnessLifecycleDiscovery()
        let controller = HeldBrightnessController()
        let manager = DeviceManager(discovery: discovery, brightnessController: controller)
        manager.start()
        let device = try #require(manager.devices.first)
        await manager.prepareBrightnessChange(for: device.id, percent: 50)
        let plan = try #require(manager.pendingBrightnessChanges[device.id])
        manager.cancelBrightnessChange(for: device.id)
        await manager.confirmBrightnessChange(for: device.id, planID: plan.id)
        #expect(!plan.isUsable && manager.pendingBrightnessChanges.isEmpty)
        #expect(await controller.applies == 0)
        manager.stop()
    }

    #if DEBUG
    @Test func offlineLightingUsesFakeServicesAndNeverAddsBatteryCapability() async throws {
        let session = try OfflineScenarioSession()
        await session.load(.keyboardLighting)
        let device = try #require(session.manager.devices.first)
        #expect(session.manager.keyboardBrightnessReadouts[device.id]?.percent == 60)
        #expect(session.manager.readSummary(for: device.id).state == .deviceResponse)
        #expect(session.manager.batteryTargets.isEmpty && DeviceReadRegistry.backends(for: device).isEmpty)
        let assessment = session.manager.adapterAssessment(for: device)
        #expect(assessment.capability("brightness")?.session.state == .succeeded)
        #expect(assessment.capability("brightnessWrite")?.evidence.level == .simulationTested)
        #expect(assessment.capability("rgb")?.implementation == .notImplemented)
        await session.manager.prepareBrightnessChange(for: device.id, percent: 25)
        let plan = try #require(session.manager.pendingBrightnessChanges[device.id])
        await session.manager.confirmBrightnessChange(for: device.id, planID: plan.id)
        #expect(session.manager.brightnessWriteResults[device.id]?.outcome == .verified)
        #expect(session.manager.keyboardBrightnessReadouts[device.id]?.percent == 25)
        #expect(await session.services.operations.contains("apply-brightness:\(device.id)"))
        session.disconnect(); session.reconnect()
        #expect(session.manager.keyboardBrightnessReadouts.isEmpty && session.manager.brightnessWriteResults.isEmpty)
        session.manager.stop()
    }
    #endif
}
