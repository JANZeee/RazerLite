import Foundation
import Testing
@testable import RazerLiteCore

@MainActor private final class SummaryDiscovery: HIDDiscovering {
    var onChange: (([HIDInterface], String) -> Void)?
    var onError: ((String) -> Void)?
    func start() { refresh() }
    func refresh() { onChange?([MouseReadServiceTests().controlInterface()], "测试属性") }
    func stop() {}
}

private struct SummaryMouseReader: MouseStatusReading {
    func read(_ device: DeviceInfo) async -> MouseTelemetry {
        .init(deviceID: device.id, interfaceID: device.interfaces[0].id,
            readAt: Date(timeIntervalSince1970: 1000), batteryPercent: 35,
            dpi: try? ViperV4ReadProtocol.dpiState(ViperReadProtocolTests().dpiPayload()), issues: [])
    }
}

private actor SummaryBatteryReader: BatteryReadingService {
    private var continuation: CheckedContinuation<BatteryReading, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var calls = 0

    func read(_ device: DeviceInfo) async -> BatteryReading {
        calls += 1
        return await withCheckedContinuation {
            continuation = $0
            waiter?.resume(); waiter = nil
        }
    }

    func waitForCall(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func finish(_ reading: BatteryReading) {
        continuation?.resume(returning: reading)
        continuation = nil
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor
struct BatterySummaryLifecycleTests {
    @Test func cancelledOrFailedBatteryRefreshCannotRestoreAnOlderCombinedReading() async throws {
        for cancelled in [false, true] {
            let reader = SummaryBatteryReader()
            let manager = DeviceManager(discovery: SummaryDiscovery(), mouseReader: SummaryMouseReader(), batteryReader: reader)
            manager.start()
            let device = try #require(manager.devices.first)
            #expect(manager.batterySummary(for: device) == nil)
            await manager.readMouseState(for: device.id)
            #expect(manager.batterySummary(for: device)?.percent == 35)
            let old = try #require(manager.mouseReadouts[device.id])

            let refresh = Task { await manager.readBattery(for: device.id) }
            await reader.waitForCall(1)
            #expect(manager.batterySummary(for: device) == nil)
            if cancelled { refresh.cancel() }
            await reader.finish(.init(deviceID: device.id, interfaceIDs: device.interfaces.map(\.id).sorted(), backend: .viperV4USB,
                percent: cancelled ? 80 : nil, acquiredAt: Date(timeIntervalSince1970: 2000), source: .device,
                issue: cancelled ? nil : .init(field: "battery", message: "模拟超时", kind: .timeout)))
            await refresh.value

            #expect(manager.mouseReadouts[device.id]?.batteryPercent == 35)
            #expect(manager.mouseReadouts[device.id]?.dpi == old.dpi)
            #expect(manager.batterySummary(for: device) == nil)
            let session = try #require(manager.adapterAssessment(for: device).capability("battery")?.session)
            #expect(session.state == (cancelled ? .cancelled : .failed))
            #expect(session.value == nil && session.previous?.value == "35%")
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(DiagnosticSnapshot.self, from: manager.snapshotData())
            #expect(snapshot.adapterAssessments?[device.id]?.capability("battery")?.session == session)

            let retry = Task { await manager.readBattery(for: device.id) }
            await reader.waitForCall(2)
            await reader.finish(.init(deviceID: device.id, interfaceIDs: device.interfaces.map(\.id).sorted(), backend: .viperV4USB,
                percent: 0, acquiredAt: Date(timeIntervalSince1970: 3000), source: .device, issue: nil))
            await retry.value
            #expect(manager.batterySummary(for: device)?.percent == 0)
            #expect(manager.batterySummary(for: device)?.acquiredAt == Date(timeIntervalSince1970: 3000))
            #expect(manager.adapterAssessment(for: device).capability("battery")?.session.state == .succeeded)
            #expect(manager.mouseReadouts[device.id]?.dpi == old.dpi)
            manager.stop()
        }
    }
}
