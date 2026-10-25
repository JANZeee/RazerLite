import Foundation
import Testing
@testable import RazerLiteCore

private struct PollingTransportSession {
    let replies: [[UInt8]]
    let sendFailure: MouseQueryError?
    let receiveFailure: MouseQueryError?

    init(replies: [[UInt8]], sendFailure: MouseQueryError? = nil, receiveFailure: MouseQueryError? = nil) {
        self.replies = replies
        self.sendFailure = sendFailure
        self.receiveFailure = receiveFailure
    }
}

private struct PollingTransportSnapshot: Sendable {
    let opens: Int
    let frames: [[UInt8]]
    let reportIDs: [Int]
    let receives: Int
    let closes: Int
}

/// Independent of the existing mouse-read fixture: records every vendor request and owns scripted reports.
private final class PollingTransportAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [PollingTransportSession]
    private var opens = 0
    private var frames: [[UInt8]] = []
    private var reportIDs: [Int] = []
    private var receives = 0
    private var closes = 0

    init(_ sessions: [PollingTransportSession]) { self.sessions = sessions }

    func open() throws -> any HIDFeatureTransport {
        lock.lock()
        opens += 1
        guard !sessions.isEmpty else {
            lock.unlock()
            throw MouseQueryError.io(operation: "模拟打开失败", code: -1)
        }
        let session = sessions.removeFirst()
        lock.unlock()
        return PollingFeatureTransport(session: session, audit: self)
    }

    func recordSend(_ bytes: [UInt8], reportID: Int) {
        lock.lock()
        frames.append(bytes)
        reportIDs.append(reportID)
        lock.unlock()
    }

    func recordReceive() {
        lock.lock()
        receives += 1
        lock.unlock()
    }

    func recordClose() {
        lock.lock()
        closes += 1
        lock.unlock()
    }

    func snapshot() -> PollingTransportSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return PollingTransportSnapshot(opens: opens, frames: frames, reportIDs: reportIDs,
                                        receives: receives, closes: closes)
    }
}

private final class PollingFeatureTransport: HIDFeatureTransport {
    private let audit: PollingTransportAudit
    private var replies: [[UInt8]]
    private let sendFailure: MouseQueryError?
    private let receiveFailure: MouseQueryError?
    private var closed = false

    init(session: PollingTransportSession, audit: PollingTransportAudit) {
        self.audit = audit
        replies = session.replies
        sendFailure = session.sendFailure
        receiveFailure = session.receiveFailure
    }

    func send(_ bytes: [UInt8], reportID: Int) throws {
        audit.recordSend(bytes, reportID: reportID)
        if let sendFailure { throw sendFailure }
    }

    func receive(reportID: Int, length: Int) throws -> [UInt8] {
        audit.recordReceive()
        if let receiveFailure { throw receiveFailure }
        guard !replies.isEmpty else { throw MouseQueryError.io(operation: "模拟接收超时", code: -1) }
        return replies.removeFirst()
    }

    func close() {
        guard !closed else { return }
        closed = true
        audit.recordClose()
    }
}

/// A gate used only to prove the old status reader and the new polling reader share the feature-I/O queue.
private final class FeatureQueueGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let releaseSignal = DispatchSemaphore(value: 0)

    func blockFirstReceive() {
        lock.lock()
        if !entered {
            entered = true
            let currentWaiters = waiters
            waiters.removeAll()
            lock.unlock()
            currentWaiters.forEach { $0.resume() }
            releaseSignal.wait()
            return
        }
        lock.unlock()
    }

    func waitUntilBlocked() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if entered {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() { releaseSignal.signal() }
}

private final class BlockingMouseTransport: HIDFeatureTransport, @unchecked Sendable {
    private let gate: FeatureQueueGate
    private var replies: [[UInt8]]
    private var firstReceive = true

    init(gate: FeatureQueueGate, replies: [[UInt8]]) {
        self.gate = gate
        self.replies = replies
    }

    func send(_ bytes: [UInt8], reportID: Int) throws {}

    func receive(reportID: Int, length: Int) throws -> [UInt8] {
        if firstReceive {
            firstReceive = false
            gate.blockFirstReceive()
        }
        guard !replies.isEmpty else { throw MouseQueryError.io(operation: "模拟断开", code: -1) }
        return replies.removeFirst()
    }

    func close() {}
}

struct PollingRateReadServiceTests {
    private func device(pid: Int = 0x00E6) -> DeviceInfo {
        DeviceInfo.group([MouseReadServiceTests().controlInterface(pid: pid)])[0]
    }

    private func response(_ payload: [UInt8], status: UInt8 = 2) -> [UInt8] {
        ViperReadProtocolTests().response(.pollingRate, payload: payload, status: status)
    }

    private func service(_ audit: PollingTransportAudit) -> PollingRateReadService {
        PollingRateReadService { _ in try audit.open() }
    }

    @Test func explicitPollingReadSendsExactlyOneGetAndCloses() async throws {
        let audit = PollingTransportAudit([.init(replies: [response([1, 4])])])
        let result = await service(audit).read(device())
        let snapshot = audit.snapshot()
        let request = try #require(snapshot.frames.first)

        #expect(result.configuredHertz == 2000)
        #expect(result.issue == nil)
        #expect(snapshot.opens == 1)
        #expect(snapshot.frames.count == 1)
        #expect(snapshot.reportIDs == [0])
        #expect(snapshot.receives == 1)
        #expect(snapshot.closes == 1)
        #expect(Array(request.prefix(10)) == [0, 0x1F, 0, 0, 0, 2, 0, 0xC0, 1, 0])
        #expect(request[10..<88].allSatisfy { $0 == 0 })
        #expect(request[88] == 0xC3)
    }

    @Test func busyPollingResponseOnlyReceivesAgainAndNeverResends() async throws {
        let audit = PollingTransportAudit([.init(replies: [response([1, 0], status: 1), response([1, 8])])])
        let result = await service(audit).read(device())
        let snapshot = audit.snapshot()
        let request = try #require(snapshot.frames.first)

        #expect(result.configuredHertz == 1000)
        #expect(result.issue == nil)
        #expect(snapshot.frames.count == 1)
        #expect(request[6] == 0x00)
        #expect(request[7] == 0xC0)
        #expect(snapshot.receives == 2)
        #expect(snapshot.closes == 1)
    }

    @Test func unknownCodeSelectorAndLengthAreRejectedWithoutInventingAValue() async {
        for payload in [[UInt8(1), 3], [0, 8], [1]] {
            let audit = PollingTransportAudit([.init(replies: [response(payload)])])
            let result = await service(audit).read(device())
            let snapshot = audit.snapshot()

            #expect(result.configuredHertz == nil)
            #expect(result.issue?.field == "pollingRate")
            #expect(result.issue?.kind == .invalidData)
            #expect(snapshot.frames.count == 1)
            #expect(snapshot.receives == 1)
            #expect(snapshot.closes == 1)
        }
    }

    @Test func unsupportedPIDDoesNotOpenAFeatureTransport() async {
        let audit = PollingTransportAudit([])
        let result = await service(audit).read(device(pid: 0x00E5))
        let snapshot = audit.snapshot()

        #expect(result.configuredHertz == nil)
        #expect(result.interfaceID == nil)
        #expect(result.issue?.field == "pollingRate")
        #expect(result.issue?.kind == .unavailable)
        #expect(snapshot.opens == 0)
        #expect(snapshot.frames.isEmpty)
        #expect(snapshot.closes == 0)
    }

    @Test func reportedTimeoutAndNotSupportedCloseTransportAndKeepTheirFailureKinds() async {
        for (status, expected) in [(UInt8(4), ReadFailureKind.timeout), (UInt8(5), .unsupported)] {
            let audit = PollingTransportAudit([.init(replies: [response([1, 0], status: status)])])
            let result = await service(audit).read(device())
            let snapshot = audit.snapshot()

            #expect(result.configuredHertz == nil)
            #expect(result.issue?.field == "pollingRate")
            #expect(result.issue?.kind == expected)
            #expect(snapshot.frames.count == 1)
            #expect(snapshot.receives == 1)
            #expect(snapshot.closes == 1)
        }
    }

    @Test func pollingAndExistingMouseReadsSerializeOnTheFeatureQueue() async throws {
        let gate = FeatureQueueGate()
        var gateReleased = false
        defer {
            if !gateReleased { gate.release() }
        }
        let fixture = ViperReadProtocolTests()
        let oldTransport = BlockingMouseTransport(gate: gate,
                                                   replies: [fixture.response(.battery, payload: [0, 153]),
                                                             fixture.response(.dpiStages, payload: fixture.dpiPayload())])
        let oldReader = MouseReadService { _ in oldTransport }
        let pollingAudit = PollingTransportAudit([.init(replies: [response([1, 2])])])
        let pollingReader = service(pollingAudit)
        let target = device()

        let oldTask = Task { await oldReader.read(target) }
        await gate.waitUntilBlocked()
        let pollingTask = Task { await pollingReader.read(target) }
        try await Task.sleep(for: .milliseconds(25))
        #expect(pollingAudit.snapshot().opens == 0)

        gate.release()
        gateReleased = true
        let oldResult = await oldTask.value
        let pollingResult = await pollingTask.value
        #expect(oldResult.isComplete)
        #expect(pollingResult.configuredHertz == 4000)
        #expect(pollingAudit.snapshot().opens == 1)
    }
}
