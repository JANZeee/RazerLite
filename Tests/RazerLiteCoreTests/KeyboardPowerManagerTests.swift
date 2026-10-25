import Foundation
import Testing
@testable import RazerLiteCore

@MainActor private final class KeyboardDiscovery: HIDDiscovering {
    var onChange: (([HIDInterface], String) -> Void)?
    var onError: ((String) -> Void)?
    var interfaces = [KeyboardPowerFixtures().interface()]
    func start() { refresh() }
    func refresh() { onChange?(interfaces, "模拟键盘属性刷新") }
    func stop() {}
    func publish(_ value: [HIDInterface]) { interfaces = value; refresh() }
}

private actor DeferredKeyboardReader: KeyboardPowerReadingService {
    private var pending: CheckedContinuation<KeyboardPowerReading, Never>?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var fields: [KeyboardPowerField] = []
    func read(_ device: DeviceInfo, field: KeyboardPowerField) async -> KeyboardPowerReading {
        fields.append(field)
        return await withCheckedContinuation {
            pending = $0
            let ready = waiters.filter { $0.0 <= fields.count }
            waiters.removeAll { $0.0 <= fields.count }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForCall(_ count: Int) async {
        if fields.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func finish(_ value: KeyboardPowerReading) { pending?.resume(returning: value); pending = nil }
}

struct KeyboardPowerManagerTests {
    private func reading(_ device: DeviceInfo, field: KeyboardPowerField, fail: Bool = false) -> KeyboardPowerReading {
        KeyboardPowerReading(deviceID: device.id, interfaceID: device.interfaces[0].id, field: field, readAt: Date(),
            batteryPercent: field == .battery && !fail ? 0 : nil,
            chargingState: field == .charging && !fail ? .notCharging : nil,
            issue: fail ? MouseReadIssue(field: field.rawValue, message: "模拟超时", kind: .timeout) : nil)
    }

    @Test @MainActor func explicitIndependentFieldsPreservePartialFailureAndExportTheirOwnTimes() async throws {
        let discovery = KeyboardDiscovery(), reader = DeferredKeyboardReader()
        let manager = DeviceManager(discovery: discovery, keyboardPowerReader: reader)
        manager.start(); manager.refresh()
        let device = try #require(manager.devices.first)
        #expect(await reader.fields.isEmpty)
        let battery = Task { await manager.readKeyboardPower(for: device.id, field: .battery) }
        await reader.waitForCall(1)
        #expect(manager.adapterAssessment(for: device).capability("battery")?.session.state == .reading)
        #expect(manager.adapterAssessment(for: device).capability("charging")?.session.state == .notRead)
        await manager.readKeyboardPower(for: device.id, field: .battery)
        await manager.readKeyboardPower(for: device.id, field: .charging)
        #expect(await reader.fields == [.battery])
        #expect(manager.readSummary(for: device.id).state == .reading)
        await reader.finish(reading(device, field: .battery, fail: true)); await battery.value
        #expect(manager.readSummary(for: device.id).state == .unconfirmed)
        let charging = Task { await manager.readKeyboardPower(for: device.id, field: .charging) }
        await reader.waitForCall(2)
        #expect(manager.adapterAssessment(for: device).capability("charging")?.session.state == .reading)
        #expect(manager.adapterAssessment(for: device).capability("battery")?.session.state == .failed)
        await reader.finish(reading(device, field: .charging)); await charging.value
        #expect(manager.keyboardBatteryReadouts[device.id]?.issue?.kind == .timeout)
        #expect(manager.keyboardChargingReadouts[device.id]?.chargingState == .notCharging)
        #expect(manager.readSummary(for: device.id).state == .partial)
        #expect(manager.lastError == nil)
        let retry = Task { await manager.readKeyboardPower(for: device.id, field: .battery) }
        await reader.waitForCall(3)
        #expect(manager.keyboardBatteryReadouts.isEmpty && !manager.keyboardChargingReadouts.isEmpty)
        await reader.finish(reading(device, field: .battery)); await retry.value
        #expect(manager.keyboardBatteryReadouts[device.id]?.batteryPercent == 0)
        #expect(manager.readSummary(for: device.id).state == .deviceResponse)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(DiagnosticSnapshot.self, from: manager.snapshotData())
        #expect(snapshot.schemaVersion == 9 && snapshot.mode == "manual-status-queries; no setting commands")
        #expect(snapshot.keyboardBatteryReadouts?[device.id]?.batteryPercent == 0)
        #expect(snapshot.keyboardChargingReadouts?[device.id]?.chargingState == .notCharging)
        let assessment = AdapterCatalog.assess(device, keyboardBattery: manager.keyboardBatteryReadouts[device.id],
                                               keyboardCharging: manager.keyboardChargingReadouts[device.id])
        #expect(assessment.capabilities.first { $0.id == "battery" }?.session.state == .succeeded)
        #expect(assessment.capabilities.first { $0.id == "charging" }?.session.state == .succeeded)
        #expect(assessment.capability("rgb")?.implementation == .notImplemented)
        manager.stop()
        #expect(manager.keyboardBatteryReadouts.isEmpty && manager.keyboardChargingReadouts.isEmpty)
    }

    @Test @MainActor func reconnectSleepAndStopInvalidateLateKeyboardResults() async throws {
        for event in 0..<3 {
            let discovery = KeyboardDiscovery(), reader = DeferredKeyboardReader()
            let manager = DeviceManager(discovery: discovery, keyboardPowerReader: reader)
            manager.start()
            let device = try #require(manager.devices.first)
            let task = Task { await manager.readKeyboardPower(for: device.id, field: .charging) }
            await reader.waitForCall(1)
            if event == 0 { discovery.publish([]); discovery.publish(device.interfaces) }
            if event == 1 { manager.suspend(); manager.resume() }
            if event == 2 { manager.stop() }
            await reader.finish(reading(device, field: .charging)); await task.value
            #expect(manager.keyboardChargingReadouts.isEmpty && manager.readingKeyboardPowerIDs.isEmpty)
            #expect(await reader.fields.count == 1)
            manager.stop()
        }
    }

    @Test @MainActor func fingerprintChangesClearBothFieldsAndRejectPriorCapabilities() async throws {
        let discovery = KeyboardDiscovery(), reader = DeferredKeyboardReader()
        let manager = DeviceManager(discovery: discovery, keyboardPowerReader: reader)
        manager.start()
        let device = try #require(manager.devices.first)
        for (index, field) in KeyboardPowerField.allCases.enumerated() {
            let task = Task { await manager.readKeyboardPower(for: device.id, field: field) }
            await reader.waitForCall(index + 1)
            await reader.finish(reading(device, field: field)); await task.value
        }
        #expect(manager.keyboardBatteryReadouts.count == 1 && manager.keyboardChargingReadouts.count == 1)
        discovery.publish([try KeyboardPowerFixtures().modified(["versionNumber": 0x0101])])
        #expect(manager.keyboardBatteryReadouts.isEmpty && manager.keyboardChargingReadouts.isEmpty)
        #expect(manager.readSummary(for: device.id).state == .discovered)
        discovery.publish([])
        #expect(AdapterCatalog.assess(KeyboardPowerFixtures().device()).capabilities.first { $0.id == "battery" }?.session.state == .notRead)
        manager.stop()
    }

    @Test @MainActor func anotherFieldCannotPublishAResult() async throws {
        let discovery = KeyboardDiscovery(), reader = DeferredKeyboardReader()
        let manager = DeviceManager(discovery: discovery, keyboardPowerReader: reader)
        manager.start()
        let device = try #require(manager.devices.first)
        let task = Task { await manager.readKeyboardPower(for: device.id, field: .battery) }
        await reader.waitForCall(1)
        await reader.finish(reading(device, field: .charging)); await task.value
        #expect(manager.keyboardBatteryReadouts.isEmpty && manager.keyboardChargingReadouts.isEmpty)
        #expect(manager.readingKeyboardPowerIDs.isEmpty)
        manager.stop()
    }
}
