import Foundation
import Testing
@testable import RazerLiteCore

private struct LiveBrightnessFixtures {
    func device(pid: Int = 0x02F5) -> DeviceInfo {
        let interfaces = [1, 3].map { number in
            HIDInterface(id: UInt64(number + 10), vendorID: 0x1532, productID: pid,
                product: "Razer Reclusa Mini 65%", manufacturer: "Fixture", transport: "USB",
                locationID: nil, versionNumber: nil, usbDeviceID: 100, usbInterfaceNumber: number,
                usbDeviceRelease: nil, primaryUsagePage: number == 3 ? 12 : 1,
                primaryUsage: number == 3 ? 1 : 6, usages: [], maxInputReportSize: number == 3 ? 0 : 8,
                maxOutputReportSize: 0, maxFeatureReportSize: number == 3 ? 90 : 0,
                registryClass: "Fixture", observedDrivers: [], isVirtual: false)
        }
        return .init(id: "live-brightness-fixture", interfaces: interfaces)
    }

    // Synthetic responses assembled separately from the production codec.
    func reply(_ command: UInt8, transaction: UInt8, payload: [UInt8], status: UInt8 = 2) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 90)
        result[0] = status; result[1] = transaction; result[5] = UInt8(payload.count)
        result[6] = 0x0F; result[7] = command
        result.replaceSubrange(8..<(8 + payload.count), with: payload)
        result[88] = result[2..<88].reduce(0, ^)
        return result
    }
    var region: [UInt8] { reply(0x80, transaction: 0x80, payload: [5, 30, 1, 15, 5]) }
    func brightness(_ raw: UInt8, transaction: UInt8 = 0x81) -> [UInt8] {
        reply(0x84, transaction: transaction, payload: [1, 5, raw])
    }
    func acknowledgement(_ raw: UInt8) -> [UInt8] { reply(4, transaction: 0x82, payload: [1, 0, raw]) }
}

private final class LiveBrightnessAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var opens = 0
    private var frames: [[UInt8]] = []
    private var receives = 0
    private var closes = 0
    func open() { lock.lock(); defer { lock.unlock() }; opens += 1 }
    func sent(_ frame: [UInt8]) { lock.lock(); defer { lock.unlock() }; frames.append(frame) }
    func receive() -> Int { lock.lock(); defer { lock.unlock() }; receives += 1; return receives }
    func close() { lock.lock(); defer { lock.unlock() }; closes += 1 }
    func snapshot() -> (opens: Int, frames: [[UInt8]], receives: Int, closes: Int) {
        lock.lock(); defer { lock.unlock() }; return (opens, frames, receives, closes)
    }
}

private final class LiveBrightnessTransport: HIDFeatureTransport {
    let audit: LiveBrightnessAudit
    var replies: [[UInt8]]
    let onReceive: @Sendable (Int) -> Void
    init(audit: LiveBrightnessAudit, replies: [[UInt8]], onReceive: @escaping @Sendable (Int) -> Void) {
        self.audit = audit; self.replies = replies; self.onReceive = onReceive
    }
    func send(_ bytes: [UInt8], reportID: Int) throws {
        #expect(reportID == 0 && bytes.count == 90)
        audit.sent(bytes)
    }
    func receive(reportID: Int, length: Int) throws -> [UInt8] {
        #expect(reportID == 0 && length == 90)
        onReceive(audit.receive())
        guard !replies.isEmpty else { throw DeviceQueryError.deviceChanged }
        return replies.removeFirst()
    }
    func close() { audit.close() }
}

struct LiveBrightnessServiceTests {
    private let fixtures = LiveBrightnessFixtures()
    private func service(_ audit: LiveBrightnessAudit, replies: [[UInt8]],
                         onReceive: @escaping @Sendable (Int) -> Void = { _ in }) -> ReclusaLiveBrightnessService {
        .init(factory: { _ in
            audit.open()
            return LiveBrightnessTransport(audit: audit, replies: replies, onReceive: onReceive)
        }, wait: {})
    }

    @Test func liveChangeUsesOneSetAndIndependentReadbackWithoutModeOrSlotWrites() async {
        for (percent, raw) in [(50, UInt8(127)), (0, 0)] {
            let audit = LiveBrightnessAudit()
            let permit = LiveBrightnessPermit()
            let result = await service(audit, replies: [fixtures.region, fixtures.brightness(255),
                fixtures.acknowledgement(raw), fixtures.brightness(raw, transaction: 0x83)])
                .set(fixtures.device(), percent: percent, permit: permit)
            #expect(result.outcome == .verified && result.attemptedWrite && result.readback?.hasValue == true)
            #expect(result.readback?.rawBrightness == raw && result.readback?.percent == percent)
            let snapshot = audit.snapshot()
            #expect(snapshot.opens == 1 && snapshot.closes == 1)
            #expect(snapshot.frames.map { $0[7] } == [0x80, 0x84, 4, 0x84])
            #expect(snapshot.frames.map { $0[1] } == [0x80, 0x81, 0x82, 0x83])
            #expect(Array(snapshot.frames[2][8..<11]) == [1, 0, raw])
            #expect(!permit.isUsable)
        }
    }

    @Test func alreadyMatchingRawValueOnlyReadsAndConsumesTheIntentLifetime() async {
        let audit = LiveBrightnessAudit()
        let reader = service(audit, replies: [fixtures.region, fixtures.brightness(127)])
        let permit = LiveBrightnessPermit()
        let first = await reader.set(fixtures.device(), percent: 50, permit: permit)
        #expect(first.outcome == .verified && !first.attemptedWrite && first.readback?.percent == 50)
        let second = await reader.set(fixtures.device(), percent: 50, permit: permit)
        #expect(second.outcome == .notSent && !second.attemptedWrite && second.readback == nil)
        #expect(audit.snapshot().opens == 1 && audit.snapshot().frames.map { $0[7] } == [0x80, 0x84])
    }

    @Test func invalidIdentityTargetExpiredAndCancelledIntentNeverOpen() async {
        let audit = LiveBrightnessAudit()
        let writer = service(audit, replies: [])
        let cancelled = LiveBrightnessPermit(); cancelled.invalidate()
        let expired = LiveBrightnessPermit(issuedAt: .now.advanced(by: .seconds(-6)))
        for (device, percent, permit) in [(fixtures.device(pid: 0x02F4), 50, LiveBrightnessPermit()),
            (fixtures.device(), -1, LiveBrightnessPermit()), (fixtures.device(), 101, LiveBrightnessPermit()),
            (fixtures.device(), 50, expired), (fixtures.device(), 50, cancelled)] {
            let result = await writer.set(device, percent: percent, permit: permit)
            #expect(result.outcome == .notSent && !result.attemptedWrite && result.readback == nil)
        }
        #expect(audit.snapshot().opens == 0)
    }

    @Test func cancelledDuringPreflightCannotSendASetting() async {
        let audit = LiveBrightnessAudit()
        let permit = LiveBrightnessPermit()
        let result = await service(audit, replies: [fixtures.region, fixtures.brightness(255)], onReceive: {
            if $0 == 2 { permit.invalidate() }
        }).set(fixtures.device(), percent: 50, permit: permit)
        #expect(result.outcome == .notSent && !result.attemptedWrite && result.readback == nil)
        #expect(audit.snapshot().frames.map { $0[7] } == [0x80, 0x84] && audit.snapshot().closes == 1)
    }

    @Test func badAckDisconnectAndWrongReadbackRemainUncertainWithoutRetry() async {
        let badEcho = fixtures.reply(4, transaction: 0x82, payload: [1, 5, 127])
        let cases = [[badEcho], [], [fixtures.acknowledgement(127)],
                     [fixtures.acknowledgement(127), fixtures.brightness(128, transaction: 0x83)]]
        for tail in cases {
            let audit = LiveBrightnessAudit()
            let result = await service(audit, replies: [fixtures.region, fixtures.brightness(255)] + tail)
                .set(fixtures.device(), percent: 50, permit: LiveBrightnessPermit())
            #expect(result.outcome == .uncertain && result.attemptedWrite && result.readback == nil)
            #expect(audit.snapshot().frames.filter { $0[7] == 4 }.count == 1 && audit.snapshot().closes == 1)
        }
    }

    @Test func busySettingAcknowledgementHasFiniteReceiveBudgetAndNeverResends() async {
        let audit = LiveBrightnessAudit()
        let busy = fixtures.reply(4, transaction: 0x82, payload: [], status: 1)
        let result = await service(audit, replies: [fixtures.region, fixtures.brightness(255)] + Array(repeating: busy, count: 16))
            .set(fixtures.device(), percent: 50, permit: LiveBrightnessPermit())
        #expect(result.outcome == .uncertain && result.readback == nil)
        #expect(audit.snapshot().frames.count == 3 && audit.snapshot().receives == 18 && audit.snapshot().closes == 1)
    }
}

@MainActor
private final class LiveBrightnessScheduleHarness {
    var time = ContinuousClock.now
    var delays: [Duration] = []
    var waitingDelays: [(Duration, CheckedContinuation<Void, any Error>)] = []
    var values: [Int] = []
    var starts: [ContinuousClock.Instant] = []
    var permits: [LiveBrightnessPermit] = []
    var applications: [CheckedContinuation<Bool, Never>] = []
    var active = 0
    var maximumActive = 0
    func sleep(_ duration: Duration) async throws {
        delays.append(duration)
        try await withCheckedThrowingContinuation { waitingDelays.append((duration, $0)) }
    }
    func releaseDelay() {
        guard !waitingDelays.isEmpty else { return }
        let (duration, continuation) = waitingDelays.removeFirst()
        time = time.advanced(by: duration)
        continuation.resume()
    }
    func apply(_ value: Int, permit: LiveBrightnessPermit) async -> Bool {
        values.append(value); starts.append(time); permits.append(permit)
        active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        return await withCheckedContinuation { applications.append($0) }
    }
    func finish(_ success: Bool) {
        guard !applications.isEmpty else { return }
        applications.removeFirst().resume(returning: success)
    }
    func controller() -> LiveBrightnessController {
        LiveBrightnessController(sleep: { try await self.sleep($0) }, now: { self.time },
                                 apply: { await self.apply($0, permit: $1) })
    }
}

@MainActor
struct LiveBrightnessControllerTests {
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition())
    }

    @Test func rapidEditsCoalesceAndFinalTargetRunsAfterSingleInflightOperation() async throws {
        let harness = LiveBrightnessScheduleHarness()
        let controller = harness.controller()
        controller.submit(percent: 10); controller.submit(percent: 20); controller.submit(percent: 30)
        try await eventually { harness.waitingDelays.count == 1 }
        #expect(harness.values.isEmpty && controller.target == 30)
        harness.releaseDelay()
        try await eventually { harness.values == [30] }
        controller.submit(percent: 40); controller.submit(percent: 60); controller.submit(percent: 80)
        #expect(controller.target == 80 && harness.values == [30])
        harness.finish(true)
        try await eventually { harness.waitingDelays.count == 1 }
        #expect(harness.delays == [.milliseconds(150), .milliseconds(250)])
        harness.releaseDelay()
        try await eventually { harness.values == [30, 80] }
        harness.finish(true)
        try await eventually { !controller.hasWork }
        #expect(controller.target == nil && harness.maximumActive == 1 && harness.waitingDelays.isEmpty)
        #expect(harness.starts[0].duration(to: harness.starts[1]) >= .milliseconds(250))
    }

    @Test func returningToActiveTargetSupersedesQueuedIntermediateValue() async throws {
        let harness = LiveBrightnessScheduleHarness(); let controller = harness.controller()
        controller.submit(percent: 40)
        try await eventually { !harness.waitingDelays.isEmpty }; harness.releaseDelay()
        try await eventually { harness.values == [40] }
        controller.submit(percent: 70); controller.submit(percent: 40)
        #expect(controller.target == 40)
        harness.finish(true)
        try await eventually { !controller.hasWork }
        #expect(harness.values == [40] && harness.delays.count == 1)
    }

    @Test func cancellationDuringDelayDropsTheTargetAndAllowsOnlyANewExplicitEdit() async throws {
        let harness = LiveBrightnessScheduleHarness(); let controller = harness.controller()
        controller.submit(percent: 20)
        try await eventually { !harness.waitingDelays.isEmpty }
        controller.cancel()
        #expect(controller.target == nil && controller.hasWork)
        #expect(!controller.submit(percent: 40))
        harness.releaseDelay()
        try await eventually { !controller.hasWork }
        #expect(harness.values.isEmpty)
        #expect(controller.submit(percent: 60))
        try await eventually { !harness.waitingDelays.isEmpty }; harness.releaseDelay()
        try await eventually { harness.values == [60] }; harness.finish(true)
        try await eventually { !controller.hasWork }
    }

    @Test func cancellationRevokesInflightPermitAndDoesNotReplayOnLateSuccess() async throws {
        let harness = LiveBrightnessScheduleHarness(); let controller = harness.controller()
        controller.submit(percent: 20)
        try await eventually { !harness.waitingDelays.isEmpty }; harness.releaseDelay()
        try await eventually { harness.values == [20] }
        controller.submit(percent: 40); controller.cancel()
        #expect(!harness.permits[0].isUsable && controller.target == nil && controller.hasWork)
        harness.finish(true)
        try await eventually { !controller.hasWork }
        #expect(harness.values == [20] && harness.waitingDelays.isEmpty)
    }

    @Test func failureClearsQueuedEditsInsteadOfAutomaticallyRetrying() async throws {
        let harness = LiveBrightnessScheduleHarness(); let controller = harness.controller()
        controller.submit(percent: 20)
        try await eventually { !harness.waitingDelays.isEmpty }; harness.releaseDelay()
        try await eventually { harness.values == [20] }
        controller.submit(percent: 40); harness.finish(false)
        try await eventually { !controller.hasWork }
        #expect(controller.target == nil && harness.values == [20] && harness.waitingDelays.isEmpty)
        #expect(!controller.submit(percent: -1) && !controller.submit(percent: 101))
        #expect(!controller.hasWork)
    }

    @Test func newBurstRespectsLastStartTimeAndIdleHasNoRepeatingTimer() async throws {
        let harness = LiveBrightnessScheduleHarness(); let controller = harness.controller()
        controller.submit(percent: 20)
        try await eventually { !harness.waitingDelays.isEmpty }; harness.releaseDelay()
        try await eventually { harness.values == [20] }; harness.finish(true)
        try await eventually { !controller.hasWork }
        controller.submit(percent: 40)
        try await eventually { !harness.waitingDelays.isEmpty }; harness.releaseDelay()
        try await eventually { !harness.waitingDelays.isEmpty }
        #expect(harness.delays.last == .milliseconds(100))
        harness.releaseDelay()
        try await eventually { harness.values == [20, 40] }; harness.finish(true)
        try await eventually { !controller.hasWork }
        #expect(harness.starts[0].duration(to: harness.starts[1]) == .milliseconds(250))
        #expect(harness.waitingDelays.isEmpty)
    }
}
