import Foundation
import Testing
@testable import RazerLiteCore

private final class BrightnessControlBus: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [[[UInt8]]]
    private var frames: [[UInt8]] = []
    private var opens = 0
    private var closes = 0
    private var onSend: (@Sendable ([UInt8]) -> Void)?
    let failSetting: Bool
    init(_ sessions: [[[UInt8]]], failSetting: Bool = false) { self.sessions = sessions; self.failSetting = failSetting }
    func open() throws -> any HIDFeatureTransport {
        lock.lock(); defer { lock.unlock() }
        guard !sessions.isEmpty else { throw DeviceQueryError.deviceChanged }
        opens += 1
        return BrightnessControlTransport(bus: self, replies: sessions.removeFirst())
    }
    func send(_ frame: [UInt8]) {
        lock.lock(); frames.append(frame); let callback = onSend; lock.unlock()
        callback?(frame)
    }
    func close() { lock.lock(); defer { lock.unlock() }; closes += 1 }
    func setOnSend(_ callback: @escaping @Sendable ([UInt8]) -> Void) { lock.lock(); defer { lock.unlock() }; onSend = callback }
    func snapshot() -> (frames: [[UInt8]], opens: Int, closes: Int) {
        lock.lock(); defer { lock.unlock() }; return (frames, opens, closes)
    }
}

private final class BrightnessControlTransport: HIDFeatureTransport {
    private let bus: BrightnessControlBus
    private var replies: [[UInt8]]
    init(bus: BrightnessControlBus, replies: [[UInt8]]) { self.bus = bus; self.replies = replies }
    func send(_ bytes: [UInt8], reportID: Int) throws {
        #expect(reportID == 0 && bytes.count == 90)
        bus.send(bytes)
        if bus.failSetting && bytes[7] == 0x04 { throw DeviceQueryError.io(operation: "模拟设置传输失败", code: -1) }
    }
    func receive(reportID: Int, length: Int) throws -> [UInt8] {
        #expect(reportID == 0 && length == 90)
        guard !replies.isEmpty else { throw DeviceQueryError.deviceChanged }
        return replies.removeFirst()
    }
    func close() { bus.close() }
}

struct ReclusaBrightnessControlTests {
    private let fixtures = ReclusaBrightnessFixtures()
    private func service(_ bus: BrightnessControlBus) -> ReclusaBrightnessControlService {
        .init(factory: { _ in try bus.open() }, wait: {})
    }
    private func reads(_ raw: UInt8, region: UInt8 = 5, regionTransaction: UInt8 = 0x80,
                       brightnessTransaction: UInt8 = 0x81) -> [[UInt8]] {
        [fixtures.response(0x80, payload: [region, 30, 1, 15, 5], transaction: regionTransaction),
         fixtures.response(0x84, payload: [1, region, raw], transaction: brightnessTransaction)]
    }
    private func acknowledgement(_ raw: UInt8, status: UInt8 = 2) -> [UInt8] {
        fixtures.response(0x04, payload: [1, 0, raw], status: status, transaction: 0x82)
    }
    private func plan(percent: Int = 50, raw: UInt8 = 127, beforeRaw: UInt8 = 255,
                      issuedAt: ContinuousClock.Instant = .now) -> KeyboardBrightnessPlan {
        let device = fixtures.device()
        let before = KeyboardBrightnessReading(deviceID: device.id, interfaceID: 13, profileID: 1, regionID: 5,
            rawBrightness: beforeRaw, percent: ReclusaBrightnessProtocol.percent(beforeRaw), issue: nil, readAt: Date())
        return .init(deviceID: device.id, deviceName: device.product, before: before,
                     afterPercent: percent, afterRaw: raw, interface: fixtures.interface(3), issuedAt: issuedAt)
    }

    @Test func setUsesProfileOneAllRegionAndFloorEncodingWithExactPercentRoundTrip() throws {
        for percent in 0...100 {
            let raw = try ReclusaBrightnessProtocol.raw(forPercent: percent)
            #expect(Int(raw) == percent * 255 / 100)
            #expect(ReclusaBrightnessProtocol.percent(raw) == percent)
            var expected = [UInt8](repeating: 0, count: 90)
            expected.replaceSubrange(0..<11, with: [0, 0x82, 0, 0, 0, 3, 0x0F, 4, 1, 0, raw])
            expected[88] = 0x09 ^ raw
            #expect(ReclusaBrightnessProtocol.setRequest(raw: raw) == expected)
        }
    }

    @Test func prepareOnlyReadsAndConfirmedPlanSendsOnceDespiteBusyThenIndependentlyReadsBack() async throws {
        let bus = BrightnessControlBus([reads(255), reads(255) + [acknowledgement(127, status: 1), acknowledgement(127)]
            + reads(127, regionTransaction: 0x83, brightnessTransaction: 0x84)])
        let controller = service(bus)
        let prepared = try await controller.prepare(fixtures.device(), percent: 50)
        #expect(prepared.before.rawBrightness == 255 && prepared.afterRaw == 127 && prepared.afterPercent == 50)
        #expect(bus.snapshot().frames.map { $0[7] } == [0x80, 0x84])
        let result = await controller.apply(prepared)
        #expect(result.outcome == .verified && result.attemptedWrite)
        #expect(result.readback?.rawBrightness == 127 && result.readback?.percent == 50 && result.readback?.profileID == 1)
        #expect(bus.snapshot().frames.map { $0[7] } == [0x80, 0x84, 0x80, 0x84, 4, 0x80, 0x84])
        #expect(bus.snapshot().frames.map { $0[1] } == [0x80, 0x81, 0x80, 0x81, 0x82, 0x83, 0x84])
        #expect(bus.snapshot().opens == 2 && bus.snapshot().closes == 2)
        #expect(await controller.apply(prepared).outcome == .notSent)
        #expect(bus.snapshot().frames.count == 7 && bus.snapshot().opens == 2)
    }

    @Test func invalidInputAndOtherDevicesDoNotOpenAndUnchangedRawDoesNotOfferPlan() async throws {
        let rejected = BrightnessControlBus([])
        for value in [-1, 101, Int.max, Int.min] {
            await #expect(throws: DeviceQueryError.self) { try await service(rejected).prepare(fixtures.device(), percent: value) }
        }
        let other = DeviceInfo(id: "other", interfaces: [fixtures.interface(1), try fixtures.modified(["productID": 0x02E3])])
        await #expect(throws: DeviceQueryError.self) { try await service(rejected).prepare(other, percent: 50) }
        #expect(rejected.snapshot().opens == 0)
        let unchanged = BrightnessControlBus([reads(127)])
        await #expect(throws: DeviceQueryError.self) { try await service(unchanged).prepare(fixtures.device(), percent: 50) }
        #expect(unchanged.snapshot().frames.map { $0[7] } == [0x80, 0x84] && unchanged.snapshot().closes == 1)
    }

    @Test func cancelledExpiredOrInconsistentPlansNeverOpen() async {
        let cancelled = plan(); cancelled.invalidate()
        let expired = plan(issuedAt: .now.advanced(by: .seconds(-61)))
        let inconsistent = plan(percent: 50, raw: 128)
        let bus = BrightnessControlBus([])
        for candidate in [cancelled, expired, inconsistent] {
            let result = await service(bus).apply(candidate)
            #expect(result.outcome == .notSent && !result.attemptedWrite && result.readback == nil)
        }
        #expect(bus.snapshot().opens == 0 && bus.snapshot().frames.isEmpty)
    }

    @Test func changedRawOrRegionAbortsBeforeSet() async {
        for replies in [reads(254), reads(255, region: 6)] {
            let bus = BrightnessControlBus([replies])
            let result = await service(bus).apply(plan())
            #expect(result.outcome == .notSent && !result.attemptedWrite && result.readback == nil)
            #expect(bus.snapshot().frames.map { $0[7] } == [0x80, 0x84] && bus.snapshot().closes == 1)
        }
    }

    @Test func invalidationDuringFreshQueryPreventsSet() async {
        let candidate = plan()
        let bus = BrightnessControlBus([reads(255)])
        bus.setOnSend { _ in candidate.invalidate() }
        let result = await service(bus).apply(candidate)
        #expect(result.outcome == .notSent && !result.attemptedWrite && result.readback == nil)
        #expect(bus.snapshot().frames.map { $0[7] } == [0x80, 0x84])
    }

    @Test func invalidSetAcknowledgementsBecomeUncertainWithoutRetryOrOldReadback() async {
        var wrongChecksum = acknowledgement(127); wrongChecksum[88] ^= 1
        let responses = [wrongChecksum, fixtures.response(4, payload: [0, 0, 127], transaction: 0x82),
            fixtures.response(4, payload: [1, 5, 127], transaction: 0x82), acknowledgement(128),
            fixtures.response(4, payload: [1, 0], transaction: 0x82),
            fixtures.response(4, payload: [1, 0, 127], transaction: 0x81), acknowledgement(127, status: 5)]
        for response in responses {
            let bus = BrightnessControlBus([reads(255) + [response]])
            let candidate = plan()
            let result = await service(bus).apply(candidate)
            #expect(result.outcome == .uncertain && result.attemptedWrite && result.readback == nil)
            #expect(bus.snapshot().frames.map { $0[7] } == [0x80, 0x84, 4] && bus.snapshot().closes == 1)
            #expect(await service(bus).apply(candidate).outcome == .notSent)
        }
    }

    @Test func readbackMismatchOrDisconnectNeverExposesBaselineAsSuccess() async {
        let readbacks = [reads(126, regionTransaction: 0x83, brightnessTransaction: 0x84),
            reads(127, region: 6, regionTransaction: 0x83, brightnessTransaction: 0x84), []]
        for readback in readbacks {
            let bus = BrightnessControlBus([reads(255) + [acknowledgement(127)] + readback])
            let result = await service(bus).apply(plan())
            #expect(result.outcome == .uncertain && result.attemptedWrite && result.readback == nil)
            #expect(bus.snapshot().frames.filter { $0[7] == 4 }.count == 1 && bus.snapshot().closes == 1)
        }
        let failedSend = BrightnessControlBus([reads(255)], failSetting: true)
        let failed = await service(failedSend).apply(plan())
        #expect(failed.outcome == .uncertain && failed.attemptedWrite && failed.readback == nil)
        #expect(failedSend.snapshot().frames.filter { $0[7] == 4 }.count == 1 && failedSend.snapshot().closes == 1)
    }

    @Test func zeroPercentIsValidAndBusySetStopsAfterOneSubmission() async {
        let off = BrightnessControlBus([reads(255) + [acknowledgement(0)]
            + reads(0, regionTransaction: 0x83, brightnessTransaction: 0x84)])
        let result = await service(off).apply(plan(percent: 0, raw: 0))
        #expect(result.outcome == .verified && result.readback?.rawBrightness == 0 && result.readback?.percent == 0)
        let busy = BrightnessControlBus([reads(255) + Array(repeating: acknowledgement(127, status: 1), count: 16)])
        let failed = await service(busy).apply(plan())
        #expect(failed.outcome == .uncertain && failed.attemptedWrite && failed.readback == nil)
        #expect(busy.snapshot().frames.map { $0[7] } == [0x80, 0x84, 4] && busy.snapshot().closes == 1)
    }
}
