import Foundation
import Testing
@testable import RazerLiteCore

private final class RateBus: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [[[UInt8]]]
    private var sent: [[UInt8]] = []
    private var closes = 0
    var onSend: (@Sendable ([UInt8]) -> Void)?
    init(_ sessions: [[[UInt8]]]) { self.sessions = sessions }
    func open() throws -> any HIDFeatureTransport {
        lock.lock(); defer { lock.unlock() }
        guard !sessions.isEmpty else { throw MouseQueryError.deviceChanged }
        return RateTransport(replies: sessions.removeFirst(), bus: self)
    }
    func record(_ bytes: [UInt8]) {
        lock.lock(); sent.append(bytes); lock.unlock()
        onSend?(bytes)
    }
    func close() { lock.lock(); defer { lock.unlock() }; closes += 1 }
    func snapshot() -> ([[UInt8]], Int) { lock.lock(); defer { lock.unlock() }; return (sent, closes) }
}
private final class RateTransport: HIDFeatureTransport {
    private var replies: [[UInt8]]
    private let bus: RateBus
    init(replies: [[UInt8]], bus: RateBus) { self.replies = replies; self.bus = bus }
    func send(_ bytes: [UInt8], reportID: Int) throws { bus.record(bytes) }
    func receive(reportID: Int, length: Int) throws -> [UInt8] {
        guard !replies.isEmpty else { throw MouseQueryError.deviceChanged }
        return replies.removeFirst()
    }
    func close() { bus.close() }
}

struct PollingRateControlTests {
    private var device: DeviceInfo { DeviceInfo.group([MouseReadServiceTests().controlInterface()])[0] }
    private func reply(_ command: UInt8 = 0xC0, _ payload: [UInt8] = [1, 8], status: UInt8 = 2) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 90)
        bytes[0] = status; bytes[1] = 0x1F; bytes[5] = UInt8(payload.count); bytes[7] = command
        bytes.replaceSubrange(8..<(8 + payload.count), with: payload)
        bytes[88] = bytes[2...87].reduce(0, ^)
        return bytes
    }
    private func service(_ bus: RateBus) -> PollingRateControlService { .init { _ in try bus.open() } }

    @Test func exactSetFramesMatchCaptureFieldsForSixRates() throws {
        for (hz, code, crc) in [(125, 0x40, 0x03), (500, 0x10, 0x53), (1000, 8, 0x4B),
                                 (2000, 4, 0x47), (4000, 2, 0x41), (8000, 1, 0x42)] {
            var expected = [UInt8](repeating: 0, count: 90)
            expected.replaceSubrange(0..<10, with: [0, 0x1F, 0, 0, 0, 2, 0, 0x40, 1, UInt8(code)])
            expected[88] = UInt8(crc)
            #expect(try ViperV4PollingWriteProtocol.request(hertz: hz) == expected)
        }
    }

    @Test func prepareOnlyReadsAndApplySendsOnceDespiteBusyThenChecksReadback() async throws {
        let bus = RateBus([[reply()], [reply(), reply(0x40, [1, 4], status: 1), reply(0x40, [1, 4]), reply(0xC0, [1, 4])]])
        let controller = service(bus)
        let plan = try await controller.prepare(device, hertz: 2000)
        #expect(plan.before == 1000 && plan.after == 2000)
        #expect(bus.snapshot().0.map { $0[7] } == [0xC0])
        let result = await controller.apply(plan)
        #expect(result.outcome == .verified && result.readback == 2000 && result.attemptedWrite)
        #expect(bus.snapshot().0.map { $0[7] } == [0xC0, 0xC0, 0x40, 0xC0])
        #expect(bus.snapshot().1 == 2)
        #expect(await controller.apply(plan).outcome == .notSent)
        #expect(bus.snapshot().0.count == 4)
    }

    @Test func invalidRateAndNonmatchingDeviceNeverOpenTransport() async {
        let bus = RateBus([])
        for hertz in [0, 250, 3000, 16000] {
            await #expect(throws: MouseQueryError.self) { try await service(bus).prepare(device, hertz: hertz) }
        }
        let interface = MouseReadServiceTests().controlInterface(pid: 0x00E5)
        let other = DeviceInfo.group([interface])[0]
        await #expect(throws: MouseQueryError.self) { try await service(bus).prepare(other, hertz: 2000) }
        #expect(bus.snapshot().0.isEmpty && bus.snapshot().1 == 0)
    }

    @Test func unchangedOrInvalidBaselineDoesNotOfferConfirmation() async {
        for response in [reply(), reply(0xC0, [1, 3]), reply(0xC0, [0, 8])] {
            let bus = RateBus([[response]])
            await #expect(throws: MouseQueryError.self) { try await service(bus).prepare(device, hertz: 1000) }
            #expect(bus.snapshot().0.count == 1 && bus.snapshot().1 == 1)
        }
    }

    @Test func changedBaselineCancelledAndExpiredPlansNeverSet() async throws {
        let bus = RateBus([[reply()], [reply(0xC0, [1, 1])]])
        let controller = service(bus)
        let plan = try await controller.prepare(device, hertz: 2000)
        let result = await controller.apply(plan)
        #expect(result.outcome == .notSent && !result.attemptedWrite)
        let cancelled = PollingRatePlan(deviceID: device.id, deviceName: device.product, before: 1000, after: 2000,
            interface: device.interfaces[0], issuedAt: .now)
        cancelled.invalidate()
        let expired = PollingRatePlan(deviceID: device.id, deviceName: device.product, before: 1000, after: 2000,
            interface: device.interfaces[0], issuedAt: .now.advanced(by: .seconds(-61)))
        #expect(await controller.apply(cancelled).outcome == .notSent)
        #expect(await controller.apply(expired).outcome == .notSent)
        #expect(bus.snapshot().0.map { $0[7] } == [0xC0, 0xC0])
    }

    @Test func invalidationDuringFreshReadStopsBeforeSet() async throws {
        let bus = RateBus([[reply()], [reply()]])
        let controller = service(bus)
        let plan = try await controller.prepare(device, hertz: 2000)
        bus.onSend = { _ in plan.invalidate() }
        #expect(await controller.apply(plan).outcome == .notSent)
        #expect(bus.snapshot().0.map { $0[7] } == [0xC0, 0xC0])
    }

    @Test func badAcknowledgementsAndIOFailureAreUncertainWithoutRetry() async throws {
        var badCRC = reply(0x40, [1, 4]); badCRC[88] ^= 1
        var wrongTransaction = reply(0x40, [1, 4]); wrongTransaction[1] = 0
        for responses in [[], [reply(0x40, [1, 4], status: 3)], [reply(0x40, [1, 8])],
                          [reply(0x40, [1])], [reply(0x40, [0, 4])], [reply(0xC0, [1, 4])],
                          [badCRC], [wrongTransaction], Array(repeating: reply(0x40, [1, 4], status: 1), count: 16)] {
            let bus = RateBus([[reply()], [reply()] + responses])
            let controller = service(bus)
            let plan = try await controller.prepare(device, hertz: 2000)
            let result = await controller.apply(plan)
            #expect(result.outcome == .uncertain && result.attemptedWrite && result.readback == nil)
            #expect(bus.snapshot().0.map { $0[7] } == [0xC0, 0xC0, 0x40])
            #expect(bus.snapshot().1 == 2)
        }
    }

    @Test func readbackMismatchAndTimeoutAreNotSuccess() async throws {
        for responses in [[reply()], []] {
            let bus = RateBus([[reply()], [reply(), reply(0x40, [1, 4])] + responses])
            let controller = service(bus)
            let plan = try await controller.prepare(device, hertz: 2000)
            let result = await controller.apply(plan)
            #expect(result.outcome == .uncertain && result.attemptedWrite)
            #expect(result.readback == (responses.isEmpty ? nil : 1000))
            #expect(bus.snapshot().0.map { $0[7] } == [0xC0, 0xC0, 0x40, 0xC0])
        }
    }
}
