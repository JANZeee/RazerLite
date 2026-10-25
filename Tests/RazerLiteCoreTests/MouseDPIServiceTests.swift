import Foundation
import Testing
@testable import RazerLiteCore

private final class DPIBus: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [[[UInt8]]]
    private var sent: [[UInt8]] = []
    private var closes = 0
    init(_ sessions: [[[UInt8]]]) { self.sessions = sessions }
    func open() throws -> any HIDFeatureTransport {
        lock.lock(); defer { lock.unlock() }
        guard !sessions.isEmpty else { throw MouseQueryError.deviceChanged }
        return DPIFeatureTransport(replies: sessions.removeFirst(), bus: self)
    }
    func record(_ frame: [UInt8]) { lock.lock(); defer { lock.unlock() }; sent.append(frame) }
    func close() { lock.lock(); defer { lock.unlock() }; closes += 1 }
    func snapshot() -> ([[UInt8]], Int) { lock.lock(); defer { lock.unlock() }; return (sent, closes) }
}

private final class DPIFeatureTransport: HIDFeatureTransport {
    private var replies: [[UInt8]]
    private let bus: DPIBus
    init(replies: [[UInt8]], bus: DPIBus) { self.replies = replies; self.bus = bus }
    func send(_ bytes: [UInt8], reportID: Int) throws { bus.record(bytes) }
    func receive(reportID: Int, length: Int) throws -> [UInt8] {
        guard !replies.isEmpty else { throw MouseQueryError.io(operation: "模拟断开", code: -1) }
        return replies.removeFirst()
    }
    func close() { bus.close() }
}

struct MouseDPIServiceTests {
    private var device: DeviceInfo { DeviceInfo.group([MouseReadServiceTests().controlInterface()])[0] }
    private var baseline: [UInt8] { ViperReadProtocolTests().dpiPayload() }
    private func response(_ payload: [UInt8]) -> [UInt8] { ViperReadProtocolTests().response(.dpiStages, payload: payload) }
    private func acknowledgement(status: UInt8 = 2) -> [UInt8] {
        var bytes = ViperReadProtocolTests().response(.dpiStages, payload: [], status: status)
        bytes[7] = 6
        bytes[88] = ViperV4ReadProtocol.checksum(bytes)
        return bytes
    }
    private func targetPayload() -> [UInt8] {
        var bytes = baseline
        bytes.replaceSubrange(11...14, with: [0x03, 0xE8, 0x05, 0xDC])
        return bytes
    }
    private func service(_ bus: DPIBus) -> MouseDPIService { MouseDPIService { _ in try bus.open() } }

    @Test func encodingChangesOnlyCurrentValuesWithKnownStorageAndChecksum() throws {
        let before = try ViperV4DPIProtocol.writableBaseline(baseline)
        let after = try ViperV4DPIProtocol.replacingCurrent(in: before, x: 1000, y: 1500)
        let frame = ViperV4DPIProtocol.request(after)
        #expect(Array(frame.prefix(8)) == [0, 0x1F, 0, 0, 0, 17, 4, 6])
        #expect(Array(frame[8..<25]) == [1, 2, 2, 0, 3, 0x20, 3, 0x20, 0, 0, 1, 3, 0xE8, 5, 0xDC, 0, 0])
        #expect(frame[88] == 0x21)
        #expect(frame[25..<88].allSatisfy { $0 == 0 })
        #expect(before.stages[0] == after.stages[0])
        #expect(before.current.x == 1600)
    }

    @Test func unknownMetadataAndInvalidTargetsAreRejected() async {
        for offset in [3, 8, 9] {
            var payload = baseline
            payload[offset] = 7
            #expect(throws: MouseQueryError.self) { try ViperV4DPIProtocol.writableBaseline(payload) }
        }
        let bus = DPIBus([])
        for (x, y) in [(0, 800), (99, 800), (2846, 800), (800, 50001)] {
            await #expect(throws: MouseQueryError.self) { try await service(bus).prepare(device, x: x, y: y) }
        }
        #expect(bus.snapshot().0.isEmpty)
    }

    @Test func preparationNeverWritesAndCancelOrExpiryPreventsApplication() async throws {
        let bus = DPIBus([[response(baseline)], [response(baseline)]])
        let controller = service(bus)
        let plan = try await controller.prepare(device, x: 1000, y: 1500)
        #expect(bus.snapshot().0.map { $0[7] } == [0x86])
        #expect(bus.snapshot().1 == 1)
        plan.invalidate()
        #expect(await controller.apply(plan).outcome == .notSent)
        let second = try await controller.prepare(device, x: 1000, y: 1500)
        let expired = MouseDPIPlan(deviceID: second.deviceID, deviceName: second.deviceName, before: second.before,
                                   after: second.after, interface: second.interface, issuedAt: .now.advanced(by: .seconds(-61)))
        #expect(await controller.apply(expired).outcome == .notSent)
        #expect(bus.snapshot().0.map { $0[7] } == [0x86, 0x86])
    }

    @Test func successfulWriteRequiresFreshBaselineAckAndFullReadbackAndCannotReplay() async throws {
        let bus = DPIBus([[response(baseline)], [response(baseline), acknowledgement(), response(targetPayload())]])
        let controller = service(bus)
        let plan = try await controller.prepare(device, x: 1000, y: 1500)
        let result = await controller.apply(plan)
        #expect(result.outcome == .verified)
        #expect(result.attemptedWrite)
        #expect(result.readback == plan.after)
        #expect(bus.snapshot().0.map { $0[7] } == [0x86, 0x86, 6, 0x86])
        #expect(bus.snapshot().1 == 2)
        #expect(await controller.apply(plan).outcome == .notSent)
        #expect(bus.snapshot().0.count == 4)
    }

    @Test func concurrentApplicationsOfSamePlanOnlyWriteOnce() async throws {
        let bus = DPIBus([[response(baseline)], [response(baseline), acknowledgement(), response(targetPayload())]])
        let controller = service(bus)
        let plan = try await controller.prepare(device, x: 1000, y: 1500)
        async let first = controller.apply(plan)
        async let second = controller.apply(plan)
        let outcomes = await [first, second].map { $0.outcome }
        #expect(outcomes.filter { $0 == .verified }.count == 1)
        #expect(outcomes.filter { $0 == .notSent }.count == 1)
        #expect(bus.snapshot().0.filter { $0[7] == 6 }.count == 1)
    }

    @Test func externalStageChangesAbortBeforeWrite() async throws {
        var changed = baseline
        changed[1] = 1
        let bus = DPIBus([[response(baseline)], [response(changed)]])
        let controller = service(bus)
        let plan = try await controller.prepare(device, x: 1000, y: 1500)
        let result = await controller.apply(plan)
        #expect(result.outcome == .notSent)
        #expect(!result.attemptedWrite)
        #expect(bus.snapshot().0.map { $0[7] } == [0x86, 0x86])
        #expect(bus.snapshot().1 == 2)
    }

    @Test func failedAckIsUncertainAndNeverRetriedOrRolledBack() async throws {
        let bus = DPIBus([[response(baseline)], [response(baseline), acknowledgement(status: 5)]])
        let controller = service(bus)
        let plan = try await controller.prepare(device, x: 1000, y: 1500)
        let result = await controller.apply(plan)
        #expect(result.outcome == .uncertain)
        #expect(result.attemptedWrite)
        #expect(result.readback == nil)
        #expect(bus.snapshot().0.map { $0[7] } == [0x86, 0x86, 6])
        #expect(bus.snapshot().1 == 2)
    }

    @Test func matchingActiveValueAloneCannotHideOtherStageChanges() async throws {
        var changed = targetPayload()
        changed[5] = 0x21
        let bus = DPIBus([[response(baseline)], [response(baseline), acknowledgement(), response(changed)]])
        let controller = service(bus)
        let plan = try await controller.prepare(device, x: 1000, y: 1500)
        let result = await controller.apply(plan)
        #expect(result.outcome == .uncertain)
        #expect(result.readback?.current == plan.after.current)
        #expect(result.readback != plan.after)
        #expect(bus.snapshot().0.count == 4)
    }

    @Test func noOpAndDeviceReopenFailureDoNotWrite() async throws {
        let bus = DPIBus([[response(baseline)], [response(baseline)]])
        let controller = service(bus)
        await #expect(throws: MouseQueryError.self) { try await controller.prepare(device, x: 1600, y: 1200) }
        let plan = try await controller.prepare(device, x: 1000, y: 1500)
        let result = await controller.apply(plan)
        #expect(result.outcome == .notSent)
        #expect(bus.snapshot().0.map { $0[7] } == [0x86, 0x86])
    }
    // Public capture excerpt, not a local write test:
    // https://github.com/openrazer/openrazer/issues/2760#issuecomment-4933462400
    // Archive SHA256 746a881e02604cab1145ca6cbe1c7165720a102cb7bd62aad17b867dd9fc3411.
    @Test func publicCaptureConfirmsDifferentReadAndWriteIndexBases() throws {
        let hex = "02 10 00 00 00 50 04 86 01 01 05 01 03 20 03 20 00 00 02 03 20 03 20 00 00 03 06 40 06 40 00 00 04 0c 80 0c 80 00 00 05 19 00 19 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 d6 00"
        let bytes = hex.split(separator: " ").map { UInt8($0, radix: 16)! }
        #expect(bytes.count == 90)
        #expect(ViperV4ReadProtocol.checksum(bytes) == bytes[88])
        let before = try ViperV4DPIProtocol.writableBaseline(Array(bytes[8..<88]))
        let encoded = ViperV4DPIProtocol.request(before)
        for index in before.stages.indices {
            let offset = 11 + index * 7
            #expect(bytes[offset] == UInt8(index + 1))
            #expect(encoded[offset] == UInt8(index))
            #expect(Array(encoded[(offset + 1)...(offset + 6)]) == Array(bytes[(offset + 1)...(offset + 6)]))
        }
        var unknown = Array(bytes[8..<88])
        unknown[3] = 0
        #expect(throws: MouseQueryError.self) { try ViperV4DPIProtocol.writableBaseline(unknown) }
    }

}
