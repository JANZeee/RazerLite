import Combine
import Foundation
import Testing
@testable import RazerLiteCore

@MainActor private final class LifecycleDiscovery: HIDDiscovering {
    var onChange: (([HIDInterface], String) -> Void)?
    var onError: ((String) -> Void)?
    var interfaces: [HIDInterface]
    init(_ interfaces: [HIDInterface]) { self.interfaces = interfaces }
    func start() { refresh() }
    func refresh() { onChange?(interfaces, "测试系统属性") }
    func stop() {}
    func publish(_ interfaces: [HIDInterface]) { self.interfaces = interfaces; refresh() }
}

private actor LifecycleGate<Value: Sendable> {
    private var pending: [Int: CheckedContinuation<Value, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var devices: [DeviceInfo] = []
    func read(_ device: DeviceInfo) async -> Value {
        devices.append(device)
        let index = devices.count
        return await withCheckedContinuation {
            pending[index] = $0
            let ready = waiters.filter { $0.0 <= index }
            waiters.removeAll { $0.0 <= index }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForCall(_ count: Int) async {
        if devices.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func finish(_ index: Int, _ value: Value) { pending.removeValue(forKey: index)?.resume(returning: value) }
}

private struct LifecycleChargingReader: MouseChargingReadingService {
    let gate: LifecycleGate<MouseChargingReading>
    func read(_ device: DeviceInfo) async -> MouseChargingReading { await gate.read(device) }
}

private struct LifecyclePollingReader: MousePollingReadingService {
    let gate: LifecycleGate<MousePollingReading>
    func read(_ device: DeviceInfo) async -> MousePollingReading { await gate.read(device) }
}

private struct LifecycleDPIController: MouseDPIControlling {
    let gate: LifecycleGate<MouseDPIPlan>
    func prepare(_ device: DeviceInfo, x: Int, y: Int) async throws -> MouseDPIPlan { await gate.read(device) }
    func apply(_ plan: MouseDPIPlan) async -> MouseDPIWriteResult {
        Issue.record("Lifecycle tests never authorize even a simulated apply")
        return .init(deviceID: plan.deviceID, interfaceID: plan.interface.id, completedAt: .now, outcome: .notSent,
                     attemptedWrite: false, readback: nil, message: "测试禁止应用")
    }
}

private actor LifecycleImmediateChargingReader: MouseChargingReadingService {
    private(set) var calls = 0
    func read(_ device: DeviceInfo) async -> MouseChargingReading {
        calls += 1
        return .init(deviceID: device.id, interfaceID: device.interfaces[0].id, readAt: .now, state: .charging, issue: nil)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ReadLifecycleTests {
    private func interfaces() -> [HIDInterface] { [MouseReadServiceTests().controlInterface()] }
    private func charging(_ device: DeviceInfo, at: Date = Date(timeIntervalSince1970: 1000), failed: Bool = false) -> MouseChargingReading {
        .init(deviceID: device.id, interfaceID: device.interfaces[0].id, readAt: at, state: failed ? nil : .notCharging,
              issue: failed ? .init(field: "charging", message: "测试超时", kind: .timeout) : nil)
    }

    @Test @MainActor func invalidationRetainsReservationUntilPhysicalCompletion() throws {
        let coordinator = DeviceOperationCoordinator()
        let device = try #require(DeviceInfo.group(interfaces()).first)
        coordinator.reconcile([device])
        let old = try #require(coordinator.begin(.charging, for: device.id))
        coordinator.reconcile([])
        coordinator.reconcile([device])
        #expect(!coordinator.isCurrent(old) && coordinator.isDraining(device.id))
        for operation: DeviceOperation in [.mouse, .polling, .charging, .dpiPrepare, .dpiApply] {
            #expect(coordinator.begin(operation, for: device.id) == nil)
        }
        coordinator.finish(old)
        let current = try #require(coordinator.begin(.polling, for: device.id))
        coordinator.finish(old) // A delayed cleanup must not release a newer operation.
        #expect(coordinator.isCurrent(current) && coordinator.isBusy(device.id))
        coordinator.finish(current)
        #expect(!coordinator.isBusy(device.id))
    }

    @Test @MainActor func propertyRefreshRetainsGenerationButFingerprintChangeReplacesIt() throws {
        let coordinator = DeviceOperationCoordinator()
        let device = try #require(DeviceInfo.group(interfaces()).first)
        coordinator.reconcile([device])
        let ticket = try #require(coordinator.begin(.mouse, for: device.id))
        #expect(coordinator.reconcile([device]).isEmpty)
        #expect(coordinator.isCurrent(ticket))
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(device.interfaces[0])) as? [String: Any])
        fields["versionNumber"] = 0x0200
        let changed = try JSONDecoder().decode(HIDInterface.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(coordinator.reconcile(DeviceInfo.group([changed])) == [device.id])
        #expect(!coordinator.isCurrent(ticket) && coordinator.isDraining(device.id))
        coordinator.finish(ticket)
    }

    @Test @MainActor func reconnectSleepAndRestartBlockNewReadsUntilOldServiceReturns() async throws {
        for event in 0..<3 {
            let discovery = LifecycleDiscovery(interfaces())
            let gate = LifecycleGate<MouseChargingReading>()
            let manager = DeviceManager(discovery: discovery, chargingReader: LifecycleChargingReader(gate: gate))
            manager.start()
            let device = try #require(manager.devices.first)
            let old = Task { await manager.readChargingState(for: device.id) }
            await gate.waitForCall(1)
            if event == 0 { discovery.publish([]); discovery.publish(device.interfaces) }
            if event == 1 { manager.suspend(); manager.resume() }
            if event == 2 { manager.stop(); manager.start() }
            #expect(manager.readingChargingDeviceIDs.isEmpty)
            #expect(manager.drainingOperationIDs == [device.id])
            #expect(manager.readSummary(for: device.id).state == .waiting)
            #expect(manager.adapterAssessment(for: device).capability("charging")?.session.state == .waiting)
            await manager.readChargingState(for: device.id)
            #expect(await gate.devices.count == 1)
            await gate.finish(1, charging(device))
            await old.value
            #expect(manager.chargingReadouts.isEmpty && manager.drainingOperationIDs.isEmpty)
            let next = Task { await manager.readChargingState(for: device.id) }
            await gate.waitForCall(2)
            await gate.finish(2, charging(device, at: Date(timeIntervalSince1970: 2000)))
            await next.value
            #expect(manager.chargingReadouts[device.id]?.readAt == Date(timeIntervalSince1970: 2000))
            manager.stop()
        }
    }

    @Test @MainActor func cancelledTaskDiscardsResultAndHoldsItsPhysicalReservation() async throws {
        let discovery = LifecycleDiscovery(interfaces())
        let gate = LifecycleGate<MouseChargingReading>()
        let manager = DeviceManager(discovery: discovery, chargingReader: LifecycleChargingReader(gate: gate))
        manager.start()
        let device = try #require(manager.devices.first)
        let task = Task { await manager.readChargingState(for: device.id) }
        await gate.waitForCall(1)
        var subscription: AnyCancellable?
        await withCheckedContinuation { continuation in
            subscription = manager.$drainingOperationIDs.dropFirst().filter { $0.contains(device.id) }.first().sink { _ in
                continuation.resume()
            }
            task.cancel()
        }
        subscription?.cancel()
        #expect(manager.readSummary(for: device.id).state == .waiting)
        await manager.readChargingState(for: device.id)
        #expect(await gate.devices.count == 1)
        await gate.finish(1, charging(device))
        await task.value
        #expect(manager.chargingReadouts.isEmpty && manager.drainingOperationIDs.isEmpty)
        #expect(manager.readSummary(for: device.id).state == .cancelled)
        #expect(manager.adapterAssessment(for: device).capability("charging")?.session.failureKind == .cancelled)
        manager.stop()
    }

    @Test @MainActor func failedRefreshKeepsExplicitHistoricalSampleWithoutRestoringACurrentValue() async throws {
        let discovery = LifecycleDiscovery(interfaces())
        let gate = LifecycleGate<MouseChargingReading>()
        let manager = DeviceManager(discovery: discovery, chargingReader: LifecycleChargingReader(gate: gate))
        manager.start()
        let device = try #require(manager.devices.first)
        let first = Task { await manager.readChargingState(for: device.id) }
        await gate.waitForCall(1)
        await gate.finish(1, charging(device)); await first.value
        let second = Task { await manager.readChargingState(for: device.id) }
        await gate.waitForCall(2)
        let busy = try #require(manager.adapterAssessment(for: device).capability("charging"))
        #expect(busy.session.state == .reading && busy.session.value == nil)
        #expect(busy.session.previous?.value == "未充电")
        #expect(busy.session.previous?.at == Date(timeIntervalSince1970: 1000))
        await gate.finish(2, charging(device, at: Date(timeIntervalSince1970: 2000), failed: true)); await second.value
        let failed = try #require(manager.adapterAssessment(for: device).capability("charging"))
        #expect(failed.session.state == .failed && failed.session.failureKind == .timeout)
        #expect(failed.session.at == Date(timeIntervalSince1970: 2000))
        #expect(failed.session.previous == busy.session.previous)
        #expect(manager.chargingReadouts[device.id]?.state == nil)
        #expect(manager.readSummary(for: device.id).state == .unconfirmed)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(DiagnosticSnapshot.self, from: manager.snapshotData())
        #expect(snapshot.schemaVersion == 9)
        #expect(snapshot.adapterAssessments?[device.id]?.capability("charging") == failed)
        #expect(snapshot.connectionCheck == manager.connectionCheck())
        manager.suspend(); manager.resume()
        #expect(manager.lastSuccessfulReadings.isEmpty)
        #expect(manager.adapterAssessment(for: device).capability("charging")?.session.previous == nil)
        manager.stop()
    }

    @Test @MainActor func failingOneFieldPreservesOtherFieldsAndOpeningViewsNeverQueries() async throws {
        let discovery = LifecycleDiscovery(interfaces())
        let chargingGate = LifecycleGate<MouseChargingReading>()
        let pollingGate = LifecycleGate<MousePollingReading>()
        let manager = DeviceManager(discovery: discovery, pollingReader: LifecyclePollingReader(gate: pollingGate),
                                    chargingReader: LifecycleChargingReader(gate: chargingGate))
        manager.start()
        let device = try #require(manager.devices.first)
        let first = Task { await manager.readChargingState(for: device.id) }
        await chargingGate.waitForCall(1)
        await manager.readPollingRate(for: device.id)
        #expect(await pollingGate.devices.isEmpty)
        await chargingGate.finish(1, charging(device)); await first.value
        let second = Task { await manager.readPollingRate(for: device.id) }
        await pollingGate.waitForCall(1)
        await pollingGate.finish(1, .init(deviceID: device.id, interfaceID: device.interfaces[0].id, readAt: .now,
            configuredHertz: nil, issue: .init(field: "pollingRate", message: "测试拒绝", kind: .deviceRejected)))
        await second.value
        #expect(manager.chargingReadouts[device.id]?.state == .notCharging)
        #expect(manager.readSummary(for: device.id).state == .partial)
        for _ in 0..<5 {
            manager.refresh()
            _ = manager.adapterAssessment(for: device).readingSummary
            _ = manager.connectionCheck()
            _ = try manager.snapshotData()
        }
        #expect(await chargingGate.devices.count == 1)
        #expect(await pollingGate.devices.count == 1)
        manager.stop()
    }

    @Test @MainActor func identicalModelsAreIsolatedAndLateResponseCannotSeedHistory() async throws {
        let firstInterface = MouseReadServiceTests().controlInterface()
        let secondInterface = MouseReadServiceTests().controlInterface(id: 33, usbID: 200)
        let discovery = LifecycleDiscovery([firstInterface, secondInterface])
        let gate = LifecycleGate<MouseChargingReading>()
        let manager = DeviceManager(discovery: discovery, chargingReader: LifecycleChargingReader(gate: gate))
        manager.start()
        let first = try #require(manager.devices.first { $0.id == firstInterface.groupID })
        let second = try #require(manager.devices.first { $0.id == secondInterface.groupID })
        let firstTask = Task { await manager.readChargingState(for: first.id) }
        await gate.waitForCall(1)
        let secondTask = Task { await manager.readChargingState(for: second.id) }
        await gate.waitForCall(2)
        discovery.publish([secondInterface])
        await gate.finish(2, charging(second)); await secondTask.value
        await gate.finish(1, charging(first)); await firstTask.value
        #expect(manager.chargingReadouts.keys.sorted() == [second.id])
        #expect(manager.lastSuccessfulReadings.keys.sorted() == [second.id])
        #expect(manager.lastSuccessfulReadings[second.id]?["charging"]?.value == "未充电")
        manager.stop()
    }

    @Test @MainActor func invalidatedDPIPreflightStillBlocksReadsAndItsLatePlanCannotBeConfirmed() async throws {
        let discovery = LifecycleDiscovery(interfaces())
        let gate = LifecycleGate<MouseDPIPlan>()
        let chargingReader = LifecycleImmediateChargingReader()
        let manager = DeviceManager(discovery: discovery, dpiController: LifecycleDPIController(gate: gate), chargingReader: chargingReader)
        manager.start()
        let device = try #require(manager.devices.first)
        let before = try ViperV4ReadProtocol.dpiState(ViperReadProtocolTests().dpiPayload())
        let plan = MouseDPIPlan(deviceID: device.id, deviceName: device.product, before: before,
            after: try ViperV4DPIProtocol.replacingCurrent(in: before, x: 1600, y: 1600), interface: device.interfaces[0], issuedAt: .now)
        let task = Task { await manager.prepareDPIChange(for: device.id, x: 1600, y: 1600) }
        await gate.waitForCall(1)
        manager.suspend(); manager.resume()
        await manager.prepareDPIChange(for: device.id, x: 1600, y: 1600)
        await manager.readChargingState(for: device.id)
        #expect(await gate.devices.count == 1)
        #expect(await chargingReader.calls == 0)
        await gate.finish(1, plan); await task.value
        #expect(!plan.isUsable && manager.pendingDPIChanges.isEmpty && manager.dpiBusyIDs.isEmpty)
        await manager.confirmDPIChange(for: device.id, planID: plan.id)
        await manager.readChargingState(for: device.id)
        #expect(await chargingReader.calls == 1)
        manager.stop()
    }

    @Test func previousSchemaSevenSessionsDecodeWithoutHistoricalFields() throws {
        let device = try #require(DeviceInfo.group(interfaces()).first)
        var object = try #require(JSONSerialization.jsonObject(with: DiagnosticSnapshot(interfaces: device.interfaces).jsonData()) as? [String: Any])
        object["schemaVersion"] = 7
        object["applicationVersion"] = "0.10.0-capabilities-and-diagnostics"
        var assessments = try #require(object["adapterAssessments"] as? [String: [String: Any]])
        var assessment = try #require(assessments[device.id])
        var capabilities = try #require(assessment["capabilities"] as? [[String: Any]])
        for index in capabilities.indices {
            var session = try #require(capabilities[index]["session"] as? [String: Any])
            session.removeValue(forKey: "value")
            session.removeValue(forKey: "previous")
            capabilities[index]["session"] = session
        }
        assessment["capabilities"] = capabilities
        assessments[device.id] = assessment
        object["adapterAssessments"] = assessments
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.schemaVersion == 7)
        #expect(decoded.adapterAssessments?[device.id]?.capabilities.allSatisfy { $0.session.previous == nil } == true)
    }

    #if DEBUG
    @Test @MainActor func retryFailureScenarioKeepsCurrentAndHistoricalSourcesSeparate() async throws {
        let session = try OfflineScenarioSession()
        await session.load(.retryFailed)
        let device = try #require(session.manager.devices.first)
        let assessment = session.manager.adapterAssessment(for: device)
        #expect(assessment.readingSummary == "部分状态已取得")
        #expect(assessment.capability("charging")?.session.state == .failed)
        #expect(assessment.capability("charging")?.session.previous?.source.contains("模拟服务") == true)
        #expect(assessment.capability("battery")?.session.state == .succeeded)
        #expect(assessment.capability("battery")?.session.previous == nil)
        #expect(session.manager.readSummary(for: device.id).state == .partial)
        session.manager.stop()
    }
    #endif
}
