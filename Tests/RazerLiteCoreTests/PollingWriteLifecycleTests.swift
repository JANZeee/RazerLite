import Foundation
import Testing
@testable import RazerLiteCore

@MainActor private final class WriteDiscovery: HIDDiscovering {
    var onChange: (([HIDInterface], String) -> Void)?
    var onError: ((String) -> Void)?
    var interfaces = [MouseReadServiceTests().controlInterface()]
    func start() { refresh() }
    func refresh() { onChange?(interfaces, "测试属性") }
    func stop() {}
}

private actor HeldRateController: PollingRateControlling {
    private var continuation: CheckedContinuation<PollingRateWriteResult, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var plan: PollingRatePlan?
    private(set) var prepares = 0
    func prepare(_ device: DeviceInfo, hertz: Int) throws -> PollingRatePlan {
        prepares += 1
        return PollingRatePlan(deviceID: device.id, deviceName: device.product, before: 1000, after: hertz,
            interface: device.interfaces[0], issuedAt: .now)
    }
    func apply(_ plan: PollingRatePlan) async -> PollingRateWriteResult {
        self.plan = plan
        return await withCheckedContinuation {
            continuation = $0
            waiter?.resume(); waiter = nil
        }
    }
    func waitForApply() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() {
        guard let plan else { return }
        // Deliberately returns a late success even when the manager invalidated the plan.
        continuation?.resume(returning: .init(deviceID: plan.deviceID, interfaceID: plan.interface.id,
            completedAt: .now, outcome: .verified, attemptedWrite: true, readback: plan.after, message: "模拟迟到结果"))
        continuation = nil
    }
}

@MainActor struct PollingWriteLifecycleTests {
    @Test func lateApplyCannotRepopulateAfterSleepReconnectStopOrTaskCancellation() async throws {
        for event in 0..<4 {
            let discovery = WriteDiscovery()
            let controller = HeldRateController()
            let manager = DeviceManager(discovery: discovery, pollingController: controller)
            manager.start()
            let device = try #require(manager.devices.first)
            await manager.preparePollingChange(for: device.id, hertz: 2000)
            let plan = try #require(manager.pendingPollingChanges[device.id])
            let task = Task { await manager.confirmPollingChange(for: device.id, planID: plan.id) }
            await controller.waitForApply()
            switch event {
            case 0: manager.suspend(); manager.resume()
            case 1:
                discovery.interfaces = []; discovery.refresh()
                discovery.interfaces = device.interfaces; discovery.refresh()
            case 2: manager.stop(); manager.start()
            default: task.cancel()
            }
            #expect(!plan.isUsable)
            #expect(manager.isDeviceBusy(device.id))
            await manager.preparePollingChange(for: device.id, hertz: 4000)
            #expect(await controller.prepares == 1)
            await controller.finish()
            await task.value
            #expect(manager.pollingReadouts.isEmpty && manager.pollingWriteResults.isEmpty)
            #expect(!manager.isDeviceBusy(device.id) && manager.pendingPollingChanges.isEmpty)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(DiagnosticSnapshot.self, from: manager.snapshotData())
            #expect(snapshot.mode.hasPrefix("manual-device-operations"))
            manager.stop()
        }
    }
}
