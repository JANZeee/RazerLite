import Foundation
import Testing
@testable import RazerLiteCore

private final class ReclusaPollingBus: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [[[UInt8]]]
    private var frames: [[UInt8]] = []
    private var opens = 0
    private var receives = 0
    private var closes = 0
    private var onSend: (@Sendable ([UInt8]) -> Void)?
    let failsSetting: Bool

    init(_ sessions: [[[UInt8]]], failsSetting: Bool = false) {
        self.sessions = sessions
        self.failsSetting = failsSetting
    }
    func open() throws -> any HIDFeatureTransport {
        lock.lock(); defer { lock.unlock() }
        opens += 1
        guard !sessions.isEmpty else { throw DeviceQueryError.deviceChanged }
        return ReclusaPollingTransport(bus: self, replies: sessions.removeFirst())
    }
    func send(_ frame: [UInt8]) {
        lock.lock(); frames.append(frame); let callback = onSend; lock.unlock()
        callback?(frame)
    }
    func receive() { lock.lock(); defer { lock.unlock() }; receives += 1 }
    func close() { lock.lock(); defer { lock.unlock() }; closes += 1 }
    func setOnSend(_ callback: @escaping @Sendable ([UInt8]) -> Void) {
        lock.lock(); defer { lock.unlock() }; onSend = callback
    }
    func snapshot() -> (frames: [[UInt8]], opens: Int, receives: Int, closes: Int) {
        lock.lock(); defer { lock.unlock() }; return (frames, opens, receives, closes)
    }
}

private final class ReclusaPollingTransport: HIDFeatureTransport {
    private let bus: ReclusaPollingBus
    private var replies: [[UInt8]]
    init(bus: ReclusaPollingBus, replies: [[UInt8]]) { self.bus = bus; self.replies = replies }
    func send(_ bytes: [UInt8], reportID: Int) throws {
        #expect(reportID == 0 && bytes.count == 90)
        bus.send(bytes)
        if bus.failsSetting && bytes[7] == 0x40 { throw DeviceQueryError.io(operation: "模拟发送中断", code: -1) }
    }
    func receive(reportID: Int, length: Int) throws -> [UInt8] {
        #expect(reportID == 0 && length == 90)
        bus.receive()
        guard !replies.isEmpty else { throw DeviceQueryError.deviceChanged }
        return replies.removeFirst()
    }
    func close() { bus.close() }
}

struct ReclusaPollingTests {
    private let fixtures = ReclusaBrightnessFixtures()
    private func reader(_ bus: ReclusaPollingBus) -> PollingRateReadService {
        .init(transportFactory: { _ in try bus.open() }, wait: {})
    }
    private func controller(_ bus: ReclusaPollingBus) -> PollingRateControlService {
        .init(factory: { _ in try bus.open() }, wait: {})
    }
    /// Independently assembled synthetic packets, not captures or proof of hardware behavior.
    private func response(_ command: UInt8 = 0xC0, payload: [UInt8] = [1, 8],
                          transaction: UInt8 = 0x80, status: UInt8 = 2) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: 90)
        frame[0] = status; frame[1] = transaction; frame[5] = UInt8(payload.count); frame[7] = command
        frame.replaceSubrange(8..<(8 + payload.count), with: payload)
        frame[88] = frame[2..<88].reduce(0, ^)
        return frame
    }
    private func acknowledgement(_ payload: [UInt8] = [1, 0x20], status: UInt8 = 2) -> [UInt8] {
        response(0x40, payload: payload, transaction: 0x81, status: status)
    }
    private func plan(issuedAt: ContinuousClock.Instant = .now, after: Int = 250) -> PollingRatePlan {
        .init(deviceID: fixtures.device().id, deviceName: fixtures.device().product, before: 1000, after: after,
              interface: fixtures.interface(3), issuedAt: issuedAt, route: .reclusaReceiver)
    }

    @Test func exactFramesUseKeyboardBankProfileOneAndOnlyFourWritableRates() throws {
        var expected = [UInt8](repeating: 0, count: 90)
        expected.replaceSubrange(0..<10, with: [0, 0x80, 0, 0, 0, 2, 0, 0xC0, 1, 0])
        expected[88] = 0xC3
        #expect(ReclusaPollingProtocol.getRequest() == expected)
        for (hz, code, crc) in [(125, 0x40, 0x03), (250, 0x20, 0x63), (500, 0x10, 0x53), (1000, 8, 0x4B)] {
            expected.replaceSubrange(0..<10, with: [0, 0x81, 0, 0, 0, 2, 0, 0x40, 1, UInt8(code)])
            expected[88] = UInt8(crc)
            #expect(try ReclusaPollingProtocol.setRequest(hertz: hz) == expected)
        }
        #expect(PollingRateControlService.supportedRates(for: fixtures.device()) == [125, 250, 500, 1000])
        let viper = DeviceInfo.group([MouseReadServiceTests().controlInterface()])[0]
        #expect(PollingRateControlService.supportedRates(for: viper) == [125, 500, 1000, 2000, 4000, 8000])
    }

    @Test func exactUSBIdentityAndUniqueInterfaceRequiredForReadAndWrite() async throws {
        #expect(PollingRateReadService.canRead(fixtures.device()))
        #expect(PollingRateControlService.canControl(fixtures.device()))
        #expect(PollingRateReadService.controlInterface(in: fixtures.device())?.id == 13)
        #expect(PollingRateControlService.controlInterface(in: fixtures.device())?.id == 13)
        let changes: [[String: Any]] = [
            ["productID": 0x02F4], ["productID": 0x02F6], ["productID": 0x02D2], ["vendorID": 0x068E],
            ["product": "Other Razer Keyboard"], ["transport": "Bluetooth"], ["isVirtual": true],
            ["usbInterfaceNumber": 2], ["usbDeviceID": NSNull()], ["usbDeviceID": 200],
            ["primaryUsagePage": 1], ["primaryUsage": 6], ["maxInputReportSize": 1],
            ["maxOutputReportSize": 1], ["maxFeatureReportSize": 91]
        ]
        var rejected = try changes.map { DeviceInfo(id: "wrong", interfaces: [fixtures.interface(1), try fixtures.modified($0)]) }
        rejected.append(.init(id: "ambiguous", interfaces: [fixtures.interface(1), fixtures.interface(3), try fixtures.modified(["id": 14])]))
        rejected.append(.init(id: "no-keyboard", interfaces: [fixtures.interface(3)]))
        rejected.append(.init(id: "empty", interfaces: []))
        let bus = ReclusaPollingBus([])
        for target in rejected {
            #expect(!PollingRateReadService.canRead(target) && !PollingRateControlService.canControl(target))
            #expect(PollingRateControlService.supportedRates(for: target).isEmpty)
            let reading = await reader(bus).read(target)
            #expect(reading.configuredHertz == nil && reading.interfaceID == nil && reading.issue?.kind == .unavailable)
            await #expect(throws: DeviceQueryError.self) { try await controller(bus).prepare(target, hertz: 250) }
        }
        for hz in [Int.min, 0, 333, 2000, 4000, 8000, Int.max] {
            await #expect(throws: DeviceQueryError.self) { try await controller(bus).prepare(fixtures.device(), hertz: hz) }
        }
        #expect(bus.snapshot().opens == 0 && bus.snapshot().frames.isEmpty)
    }

    @Test func readsAllSevenCodesWithoutWritingOrInventingUnknownValues() async {
        for (code, hz) in [(UInt8(0x40), 125), (0x20, 250), (0x10, 500), (8, 1000), (4, 2000), (2, 4000), (1, 8000)] {
            let bus = ReclusaPollingBus([[response(payload: [1, code])]])
            let reading = await reader(bus).read(fixtures.device())
            #expect(reading.configuredHertz == hz && reading.issue == nil && reading.interfaceID == 13)
            #expect(bus.snapshot().frames.map { $0[7] } == [0xC0])
            #expect(bus.snapshot().frames.map { $0[1] } == [0x80])
            #expect(bus.snapshot().closes == 1)
        }
        let invalidPayloads: [[UInt8]] = [[], [1], [0, 8], [2, 8], [1, 0], [1, 3], [1, 8, 0]]
        for payload in invalidPayloads {
            let bus = ReclusaPollingBus([[response(payload: payload)]])
            let reading = await reader(bus).read(fixtures.device())
            #expect(reading.configuredHertz == nil && reading.issue?.kind == .invalidData)
            #expect(bus.snapshot().frames.count == 1 && bus.snapshot().closes == 1)
        }
    }

    @Test func invalidHeadersOrStatusFailClosedAndBusyOnlyReceivesAgain() async {
        var badCRC = response(); badCRC[88] ^= 1
        var wrongClass = response(); wrongClass[6] = 7; wrongClass[88] = wrongClass[2..<88].reduce(0, ^)
        var fragmented = response(); fragmented[2] = 1; fragmented[88] = fragmented[2..<88].reduce(0, ^)
        for reply in [badCRC, wrongClass, fragmented, Array(response().dropLast()),
                      response(transaction: 0x1F), response(0x40), response(status: 4), response(status: 5)] {
            let bus = ReclusaPollingBus([[reply]])
            let reading = await reader(bus).read(fixtures.device())
            #expect(reading.configuredHertz == nil && reading.issue != nil)
            #expect(bus.snapshot().frames.count == 1 && bus.snapshot().closes == 1)
        }
        let busy = response(status: 1)
        let bus = ReclusaPollingBus([[busy, response()]])
        #expect(await reader(bus).read(fixtures.device()).configuredHertz == 1000)
        #expect(bus.snapshot().frames.count == 1 && bus.snapshot().receives == 2)
        let exhausted = ReclusaPollingBus([Array(repeating: busy, count: 16)])
        let failed = await reader(exhausted).read(fixtures.device())
        #expect(failed.configuredHertz == nil && failed.issue?.kind == .busy)
        #expect(exhausted.snapshot().frames.count == 1 && exhausted.snapshot().receives == 16)
        #expect(exhausted.snapshot().closes == 1)
    }

    @Test func prepareReadsOnlyAndApplyUsesOneSetThenSeparateReadbackAndConsumesPermit() async throws {
        let bus = ReclusaPollingBus([[response()], [response(), acknowledgement(status: 1), acknowledgement(),
            response(payload: [1, 0x20], transaction: 0x82)]])
        let service = controller(bus)
        let prepared = try await service.prepare(fixtures.device(), hertz: 250)
        #expect(prepared.before == 1000 && prepared.after == 250)
        #expect(bus.snapshot().frames.map { $0[7] } == [0xC0])
        let result = await service.apply(prepared)
        #expect(result.outcome == .verified && result.attemptedWrite && result.readback == 250)
        #expect(bus.snapshot().frames.map { $0[7] } == [0xC0, 0xC0, 0x40, 0xC0])
        #expect(bus.snapshot().frames.map { $0[1] } == [0x80, 0x80, 0x81, 0x82])
        #expect(bus.snapshot().opens == 2 && bus.snapshot().closes == 2)
        #expect(await service.apply(prepared).outcome == .notSent)
        #expect(bus.snapshot().frames.count == 4 && bus.snapshot().opens == 2)
    }

    @Test func unchangedOrInvalidPrepareBaselineNeverOffersPlan() async {
        for reply in [response(payload: [1, 0x20]), response(payload: [1, 3]), response(payload: [0, 8])] {
            let bus = ReclusaPollingBus([[reply]])
            await #expect(throws: DeviceQueryError.self) { try await controller(bus).prepare(fixtures.device(), hertz: 250) }
            #expect(bus.snapshot().frames.map { $0[7] } == [0xC0] && bus.snapshot().closes == 1)
        }
    }

    @Test func changedCancelledExpiredAndInvalidTargetsDoNotSet() async {
        let changed = ReclusaPollingBus([[response(payload: [1, 0x10])]])
        let result = await controller(changed).apply(plan())
        #expect(result.outcome == .notSent && !result.attemptedWrite)
        #expect(changed.snapshot().frames.map { $0[7] } == [0xC0])
        let cancelled = plan(); cancelled.invalidate()
        let closed = ReclusaPollingBus([])
        for candidate in [cancelled, plan(issuedAt: .now.advanced(by: .seconds(-61))), plan(after: 8000)] {
            let rejected = await controller(closed).apply(candidate)
            #expect(rejected.outcome == .notSent && !rejected.attemptedWrite)
        }
        #expect(closed.snapshot().opens == 0)
        let candidate = plan()
        let invalidated = ReclusaPollingBus([[response()]])
        invalidated.setOnSend { _ in candidate.invalidate() }
        #expect(await controller(invalidated).apply(candidate).outcome == .notSent)
        #expect(invalidated.snapshot().frames.map { $0[7] } == [0xC0])
    }

    @Test func rejectedAmbiguousOrMissingAcknowledgementNeverRetriesTheSet() async {
        var badCRC = acknowledgement(); badCRC[88] ^= 1
        let responses = [[], [badCRC], [acknowledgement([0, 0x20])], [acknowledgement([1, 8])],
            [acknowledgement([1])], [acknowledgement([1, 0x20, 0])], [acknowledgement(status: 5)],
            [response(0x40, payload: [1, 0x20], transaction: 0x80)],
            Array(repeating: acknowledgement(status: 1), count: 16)]
        for replies in responses {
            let bus = ReclusaPollingBus([[response()] + replies])
            let candidate = plan()
            let result = await controller(bus).apply(candidate)
            #expect(result.outcome == .uncertain && result.attemptedWrite && result.readback == nil)
            #expect(bus.snapshot().frames.map { $0[7] } == [0xC0, 0x40] && bus.snapshot().closes == 1)
            #expect(await controller(bus).apply(candidate).outcome == .notSent)
        }
        let interrupted = ReclusaPollingBus([[response()]], failsSetting: true)
        let result = await controller(interrupted).apply(plan())
        #expect(result.outcome == .uncertain && result.attemptedWrite && result.readback == nil)
        #expect(interrupted.snapshot().frames.map { $0[7] } == [0xC0, 0x40])
    }

    @Test func readbackMismatchDisconnectAndStaleTransactionRemainUncertain() async {
        for replies in [[], [response(transaction: 0x82)], [response(payload: [1, 0x20], transaction: 0x80)]] {
            let bus = ReclusaPollingBus([[response(), acknowledgement()] + replies])
            let result = await controller(bus).apply(plan())
            #expect(result.outcome == .uncertain && result.attemptedWrite)
            #expect(bus.snapshot().frames.map { $0[7] } == [0xC0, 0x40, 0xC0])
            #expect(bus.snapshot().closes == 1)
        }
    }
}
