import Foundation
import Testing
@testable import RazerLiteCore

@MainActor
private final class FakeDiscovery: HIDDiscovering {
    var onChange: (([HIDInterface], String) -> Void)?
    var onError: ((String) -> Void)?
    var starts = 0
    var stops = 0
    func start() { starts += 1; onChange?([], "初始快照") }
    func refresh() { onChange?([], "刷新") }
    func stop() { stops += 1 }
}

struct DeviceManagerTests {
    @Test @MainActor func simulatedInterfaceRemovalAndReconnectUpdateDeviceGroups() {
        let fake = FakeDiscovery()
        let manager = DeviceManager(discovery: fake)
        let fixture = DeviceTests()
        manager.start()
        fake.onChange?([fixture.interface(id: 1), fixture.interface(id: 2)], "接入")
        #expect(manager.physicalDevices.count == 1)
        #expect(manager.interfaceCount == 2)
        fake.onChange?([fixture.interface(id: 2)], "部分接口移除")
        #expect(manager.physicalDevices.count == 1)
        #expect(manager.interfaceCount == 1)
        fake.onChange?([], "设备移除")
        #expect(manager.devices.isEmpty)
        fake.onChange?([fixture.interface(id: 50, usbID: 500)], "重新连接")
        #expect(manager.physicalDevices.first?.id == "usb-500")
        manager.stop()
    }

    @Test @MainActor func lifetimeAndRefreshAreIdempotent() {
        let fake = FakeDiscovery()
        let manager = DeviceManager(discovery: fake)
        manager.start()
        manager.start()
        #expect(fake.starts == 1)
        #expect(manager.isMonitoring)
        manager.refresh()
        #expect(manager.logs.last?.message == "刷新")
        manager.stop()
        manager.stop()
        #expect(fake.stops == 1)
        #expect(fake.onChange == nil)
        #expect(fake.onError == nil)
        #expect(!manager.isMonitoring)
        manager.start()
        #expect(fake.starts == 2)
        manager.stop()
    }

    @Test @MainActor func errorsSurfaceAndLogMemoryIsBounded() {
        let fake = FakeDiscovery()
        let manager = DeviceManager(discovery: fake)
        manager.start()
        for index in 0..<250 { fake.onChange?([], "事件 \(index)") }
        #expect(manager.logs.count == 200)
        #expect(manager.logs.last?.message == "事件 249")
        fake.onError?("模拟权限失败")
        #expect(manager.lastError == "模拟权限失败")
        #expect(manager.logs.last?.isError == true)
        #expect(manager.logs.count == 200)
        manager.clearError()
        #expect(manager.lastError == nil)
        manager.stop()
    }

    @Test @MainActor func discoveryDoesNotRetainServiceThroughCallbacks() {
        let fake = FakeDiscovery()
        weak var reference: DeviceManager?
        do {
            let manager = DeviceManager(discovery: fake)
            manager.start()
            reference = manager
        }
        #expect(reference == nil)
        fake.onChange?([], "释放后的回调")
        fake.onError?("释放后的错误")
    }
}

private actor DeferredMouseReader: MouseStatusReading {
    private var pending: CheckedContinuation<MouseTelemetry, Never>?
    private var started: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var calls = 0
    func read(_ device: DeviceInfo) async -> MouseTelemetry {
        calls += 1
        return await withCheckedContinuation {
            pending = $0
            let ready = started.filter { $0.0 <= calls }
            started.removeAll { $0.0 <= calls }
            for (_, waiter) in ready { waiter.resume() }
        }
    }
    func waitUntilStarted(count: Int = 1) async {
        if calls >= count { return }
        await withCheckedContinuation { started.append((count, $0)) }
    }
    func finish(_ value: MouseTelemetry) { pending?.resume(returning: value); pending = nil }
}

struct DeviceManagerReadTests {
    private func reading(for device: DeviceInfo) throws -> MouseTelemetry {
        MouseTelemetry(deviceID: device.id, interfaceID: MouseReadService.interfaceID(for: device), readAt: Date(),
                       batteryPercent: 60, dpi: try ViperV4ReadProtocol.dpiState(ViperReadProtocolTests().dpiPayload()), issues: [])
    }

    @Test @MainActor func queriesAreExplicitDeduplicatedAndExported() async throws {
        let discovery = FakeDiscovery()
        let reader = DeferredMouseReader()
        let manager = DeviceManager(discovery: discovery, mouseReader: reader)
        let control = MouseReadServiceTests().controlInterface()
        manager.start()
        discovery.onChange?([control], "接入")
        manager.refresh()
        discovery.onChange?([control], "属性刷新")
        #expect(await reader.calls == 0)
        let device = try #require(manager.devices.first)
        let task = Task { await manager.readMouseState(for: device.id) }
        await reader.waitUntilStarted()
        #expect(manager.readingDeviceIDs.contains(device.id))
        await manager.readMouseState(for: device.id)
        #expect(await reader.calls == 1)
        await reader.finish(try reading(for: device))
        await task.value
        #expect(manager.mouseReadouts[device.id]?.batteryPercent == 60)
        #expect(manager.readingDeviceIDs.isEmpty)
        #expect(String(decoding: try manager.snapshotData(), as: UTF8.self).contains("mouseReadouts"))
        manager.stop()
    }

    @Test @MainActor func lateResponseAfterDisconnectAndReconnectIsDiscarded() async throws {
        let discovery = FakeDiscovery()
        let reader = DeferredMouseReader()
        let manager = DeviceManager(discovery: discovery, mouseReader: reader)
        manager.start()
        discovery.onChange?([MouseReadServiceTests().controlInterface()], "接入")
        let device = try #require(manager.devices.first)
        let task = Task { await manager.readMouseState(for: device.id) }
        await reader.waitUntilStarted()
        discovery.onChange?([], "断开")
        #expect(manager.readingDeviceIDs.isEmpty)
        discovery.onChange?([MouseReadServiceTests().controlInterface(id: 30)], "重新接入")
        await reader.finish(try reading(for: device))
        await task.value
        #expect(manager.mouseReadouts.isEmpty)
        manager.stop()
    }

    @Test @MainActor func lateResponseAfterStopIsDiscarded() async throws {
        let discovery = FakeDiscovery()
        let reader = DeferredMouseReader()
        let manager = DeviceManager(discovery: discovery, mouseReader: reader)
        manager.start()
        discovery.onChange?([MouseReadServiceTests().controlInterface()], "接入")
        let device = try #require(manager.devices.first)
        let task = Task { await manager.readMouseState(for: device.id) }
        await reader.waitUntilStarted()
        manager.stop()
        await reader.finish(try reading(for: device))
        await task.value
        #expect(manager.mouseReadouts.isEmpty)
        #expect(manager.readingDeviceIDs.isEmpty)
    }

    @Test @MainActor func failedRefreshRemovesPreviousValuesAndDoesNotShowModal() async throws {
        let discovery = FakeDiscovery()
        let reader = DeferredMouseReader()
        let manager = DeviceManager(discovery: discovery, mouseReader: reader)
        manager.start()
        discovery.onChange?([MouseReadServiceTests().controlInterface()], "接入")
        let device = try #require(manager.devices.first)
        let first = Task { await manager.readMouseState(for: device.id) }
        await reader.waitUntilStarted()
        await reader.finish(try reading(for: device))
        await first.value
        let second = Task { await manager.readMouseState(for: device.id) }
        await reader.waitUntilStarted(count: 2)
        #expect(manager.mouseReadouts[device.id] == nil)
        await reader.finish(MouseTelemetry(deviceID: device.id, interfaceID: 3, readAt: Date(), batteryPercent: nil,
                                           dpi: nil, issues: [MouseReadIssue(field: "battery", message: "模拟拒绝")]))
        await second.value
        #expect(manager.mouseReadouts[device.id]?.batteryPercent == nil)
        #expect(manager.lastError == nil)
        #expect(manager.logs.last?.isError == true)
        manager.stop()
    }
}

private actor FakeDPIController: MouseDPIControlling {
    private(set) var preparations = 0
    private(set) var writes = 0
    func prepare(_ device: DeviceInfo, x: Int, y: Int) async throws -> MouseDPIPlan {
        preparations += 1
        let before = try ViperV4ReadProtocol.dpiState(ViperReadProtocolTests().dpiPayload())
        let after = try ViperV4DPIProtocol.replacingCurrent(in: before, x: x, y: y)
        return MouseDPIPlan(deviceID: device.id, deviceName: device.product, before: before, after: after,
                            interface: MouseReadServiceTests().controlInterface(), issuedAt: .now)
    }
    func apply(_ plan: MouseDPIPlan) async -> MouseDPIWriteResult {
        writes += 1
        return MouseDPIWriteResult(deviceID: plan.deviceID, interfaceID: plan.interface.id, completedAt: Date(), outcome: .verified,
                                   attemptedWrite: true, readback: plan.after, message: "模拟写入已验证")
    }
}

struct DeviceManagerDPITests {
    @Test @MainActor func prepareCancelAndStopNeverCallApply() async throws {
        let discovery = FakeDiscovery()
        let controller = FakeDPIController()
        let manager = DeviceManager(discovery: discovery, dpiController: controller)
        manager.start()
        discovery.onChange?([MouseReadServiceTests().controlInterface()], "接入")
        let id = try #require(manager.devices.first?.id)
        #expect(await controller.preparations == 0)
        await manager.prepareDPIChange(for: id, x: 1000, y: 1500)
        let plan = try #require(manager.pendingDPIChanges[id])
        await manager.confirmDPIChange(for: id, planID: UUID())
        #expect(await controller.writes == 0)
        manager.cancelDPIChange(for: id)
        #expect(!plan.isUsable)
        await manager.confirmDPIChange(for: id, planID: plan.id)
        await manager.prepareDPIChange(for: id, x: 1000, y: 1500)
        let other = try #require(manager.pendingDPIChanges[id])
        manager.stop()
        #expect(!other.isUsable)
        await manager.confirmDPIChange(for: id, planID: other.id)
        #expect(await controller.writes == 0)
    }

    @Test @MainActor func explicitConfirmationAppliesOnceAndExportsVerifiedResult() async throws {
        let discovery = FakeDiscovery()
        let controller = FakeDPIController()
        let manager = DeviceManager(discovery: discovery, dpiController: controller)
        manager.start()
        discovery.onChange?([MouseReadServiceTests().controlInterface()], "接入")
        let id = try #require(manager.devices.first?.id)
        await manager.prepareDPIChange(for: id, x: 1000, y: 1500)
        let plan = try #require(manager.pendingDPIChanges[id])
        #expect(await controller.writes == 0)
        await manager.confirmDPIChange(for: id, planID: plan.id)
        await manager.confirmDPIChange(for: id, planID: plan.id)
        #expect(await controller.writes == 1)
        #expect(manager.pendingDPIChanges.isEmpty)
        #expect(manager.dpiBusyIDs.isEmpty)
        #expect(manager.mouseReadouts[id]?.dpi?.current.x == 1000)
        #expect(manager.mouseReadouts[id]?.batteryPercent == nil)
        #expect(manager.dpiWriteResults[id]?.outcome == .verified)
        #expect(String(decoding: try manager.snapshotData(), as: UTF8.self).contains("dpiWriteResults"))
        let original = MouseReadServiceTests().controlInterface()
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        fields["versionNumber"] = 0x0102
        let changed = try JSONDecoder().decode(HIDInterface.self, from: JSONSerialization.data(withJSONObject: fields))
        discovery.onChange?([changed], "同 ID 接口版本变化")
        #expect(manager.dpiWriteResults.isEmpty)
        #expect(manager.mouseReadouts.isEmpty)
        discovery.onChange?([MouseReadServiceTests().controlInterface(id: 30)], "查询接口替换")
        #expect(manager.dpiWriteResults.isEmpty)
        #expect(manager.mouseReadouts.isEmpty)
        manager.stop()
    }

    @Test @MainActor func disconnectAndSleepInvalidatePendingConfirmation() async throws {
        let discovery = FakeDiscovery()
        let controller = FakeDPIController()
        let manager = DeviceManager(discovery: discovery, dpiController: controller)
        manager.start()
        discovery.onChange?([MouseReadServiceTests().controlInterface()], "接入")
        let id = try #require(manager.devices.first?.id)
        await manager.prepareDPIChange(for: id, x: 1000, y: 1500)
        let plan = try #require(manager.pendingDPIChanges[id])
        discovery.onChange?([], "断连")
        #expect(!plan.isUsable)
        #expect(manager.pendingDPIChanges.isEmpty)
        discovery.onChange?([MouseReadServiceTests().controlInterface()], "接入")
        await manager.prepareDPIChange(for: id, x: 1000, y: 1500)
        let second = try #require(manager.pendingDPIChanges[id])
        manager.invalidateDPIPlans()
        #expect(!second.isUsable)
        await manager.confirmDPIChange(for: id, planID: second.id)
        #expect(await controller.writes == 0)
        manager.stop()
    }
}
