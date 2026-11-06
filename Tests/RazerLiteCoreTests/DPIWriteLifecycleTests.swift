import Combine
import Foundation
import Testing
@testable import RazerLiteCore

@MainActor private final class DPIWriteDiscovery: HIDDiscovering {
    var onChange: (([HIDInterface], String) -> Void)?
    var onError: ((String) -> Void)?
    var interfaces = [MouseReadServiceTests().controlInterface()]
    func start() { refresh() }
    func refresh() { onChange?(interfaces, "测试属性") }
    func stop() {}
}

private actor HeldDPIController: MouseDPIControlling {
    private var holdsPreparation: Bool
    private var preparation: CheckedContinuation<MouseDPIPlan, Error>?
    private var application: CheckedContinuation<MouseDPIWriteResult, Never>?
    private var preparationWaiter: CheckedContinuation<Void, Never>?
    private var applicationWaiter: CheckedContinuation<Void, Never>?
    private(set) var plan: MouseDPIPlan?
    private(set) var preparations = 0
    private(set) var applications = 0

    init(holdsPreparation: Bool = false) { self.holdsPreparation = holdsPreparation }

    func prepare(_ device: DeviceInfo, x: Int, y: Int) async throws -> MouseDPIPlan {
        preparations += 1
        let before = try ViperV4ReadProtocol.dpiState(ViperReadProtocolTests().dpiPayload())
        let plan = MouseDPIPlan(deviceID: device.id, deviceName: device.product, before: before,
            after: try ViperV4DPIProtocol.replacingCurrent(in: before, x: x, y: y),
            interface: device.interfaces[0], issuedAt: .now)
        self.plan = plan
        guard holdsPreparation else { return plan }
        return try await withCheckedThrowingContinuation {
            preparation = $0
            preparationWaiter?.resume(); preparationWaiter = nil
        }
    }

    func apply(_ plan: MouseDPIPlan) async -> MouseDPIWriteResult {
        applications += 1
        self.plan = plan
        return await withCheckedContinuation {
            application = $0
            applicationWaiter?.resume(); applicationWaiter = nil
        }
    }

    func waitForPreparation() async {
        if preparation != nil { return }
        await withCheckedContinuation { preparationWaiter = $0 }
    }

    func waitForApplication() async {
        if application != nil { return }
        await withCheckedContinuation { applicationWaiter = $0 }
    }

    func finishPreparation(failing: Bool) {
        guard let plan else { return }
        if failing { preparation?.resume(throwing: DeviceQueryError.malformed("模拟迟到错误")) }
        else { preparation?.resume(returning: plan) }
        preparation = nil
        holdsPreparation = false
    }

    func finishApplication() {
        guard let plan else { return }
        // Simulate an uncancellable physical operation returning after its logical session ended.
        application?.resume(returning: .init(deviceID: plan.deviceID, interfaceID: plan.interface.id,
            completedAt: .now, outcome: .verified, attemptedWrite: true, readback: plan.after, message: "模拟迟到结果"))
        application = nil
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor
struct DPIWriteLifecycleTests {
    @Test func cancelledPreparationRetainsReservationAndDiscardsLatePlanOrError() async throws {
        for cancelTask in [false, true] {
            for fail in [false, true] {
                let discovery = DPIWriteDiscovery()
                let controller = HeldDPIController(holdsPreparation: true)
                let manager = DeviceManager(discovery: discovery, dpiController: controller)
                manager.start()
                let device = try #require(manager.devices.first)
                let task = Task { await manager.prepareDPIChange(for: device.id, x: 1600, y: 1600) }
                await controller.waitForPreparation()
                let plan = try #require(await controller.plan)
                if cancelTask {
                    var subscription: AnyCancellable?
                    await withCheckedContinuation { continuation in
                        subscription = manager.$drainingOperationIDs.dropFirst()
                            .filter { $0.contains(device.id) }.first().sink { _ in continuation.resume() }
                        task.cancel()
                    }
                    subscription?.cancel()
                } else {
                    manager.cancelDPIChange(for: device.id)
                }
                #expect(manager.isDeviceBusy(device.id) && manager.dpiBusyIDs.isEmpty)
                #expect(manager.drainingOperationIDs == [device.id])
                await manager.prepareDPIChange(for: device.id, x: 3200, y: 3200)
                #expect(await controller.preparations == 1)
                await controller.finishPreparation(failing: fail)
                await task.value
                if !fail { #expect(!plan.isUsable) }
                #expect(manager.pendingDPIChanges.isEmpty && manager.dpiErrors.isEmpty && manager.dpiBusyIDs.isEmpty)
                #expect(manager.mouseReadouts.isEmpty && manager.lastSuccessfulReadings.isEmpty)
                #expect(!manager.isDeviceBusy(device.id) && manager.drainingOperationIDs.isEmpty)
                await manager.confirmDPIChange(for: device.id, planID: plan.id)
                #expect(await controller.applications == 0)
                await manager.prepareDPIChange(for: device.id, x: 3200, y: 3200)
                #expect(await controller.preparations == 2)
                #expect(manager.pendingDPIChanges[device.id]?.after.current.x == 3200)
                manager.stop()
            }
        }
    }

    @Test func lateApplyCannotRepopulateAfterSleepReconnectStopOrTaskCancellation() async throws {
        for event in 0..<4 {
            let discovery = DPIWriteDiscovery()
            let controller = HeldDPIController()
            let manager = DeviceManager(discovery: discovery, dpiController: controller)
            manager.start()
            let device = try #require(manager.devices.first)
            await manager.prepareDPIChange(for: device.id, x: 1600, y: 1600)
            let plan = try #require(manager.pendingDPIChanges[device.id])
            let task = Task { await manager.confirmDPIChange(for: device.id, planID: plan.id) }
            await controller.waitForApplication()
            switch event {
            case 0: manager.suspend(); manager.resume()
            case 1:
                discovery.interfaces = []; discovery.refresh()
                discovery.interfaces = device.interfaces; discovery.refresh()
            case 2: manager.stop(); manager.start()
            default: task.cancel()
            }
            #expect(!plan.isUsable)
            #expect(!plan.permit.consume()) // A queued SET can no longer acquire write permission.
            #expect(manager.isDeviceBusy(device.id))
            await manager.prepareDPIChange(for: device.id, x: 3200, y: 3200)
            #expect(await controller.preparations == 1)
            await controller.finishApplication()
            await task.value
            #expect(manager.mouseReadouts.isEmpty && manager.dpiWriteResults.isEmpty)
            #expect(manager.dpiBusyIDs.isEmpty && manager.pendingDPIChanges.isEmpty && !manager.isDeviceBusy(device.id))
            await manager.prepareDPIChange(for: device.id, x: 3200, y: 3200)
            #expect(await controller.preparations == 2)
            manager.stop()
        }
    }

    @Test func alreadyCancelledTasksCannotPrepareOrSubmitASetting() async throws {
        let controller = HeldDPIController()
        let manager = DeviceManager(discovery: DPIWriteDiscovery(), dpiController: controller)
        manager.start()
        let device = try #require(manager.devices.first)
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await manager.prepareDPIChange(for: device.id, x: 1600, y: 1600)
        }.value
        #expect(await controller.preparations == 0)
        await manager.prepareDPIChange(for: device.id, x: 1600, y: 1600)
        let plan = try #require(manager.pendingDPIChanges[device.id])
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await manager.confirmDPIChange(for: device.id, planID: plan.id)
        }.value
        #expect(await controller.applications == 0)
        #expect(manager.pendingDPIChanges[device.id]?.id == plan.id && plan.isUsable)
        manager.stop()
    }
}
