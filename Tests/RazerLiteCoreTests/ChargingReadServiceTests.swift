import Foundation
import Testing
@testable import RazerLiteCore

private final class ChargingAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [[UInt8]] = []
    private var reportIDs: [Int] = []
    private var closes = 0
    func sent(_ frame: [UInt8], id: Int) { lock.lock(); defer { lock.unlock() }; frames.append(frame); reportIDs.append(id) }
    func closed() { lock.lock(); defer { lock.unlock() }; closes += 1 }
    func snapshot() -> ([[UInt8]], [Int], Int) { lock.lock(); defer { lock.unlock() }; return (frames, reportIDs, closes) }
}

private final class ChargingTransport: HIDFeatureTransport {
    let audit: ChargingAudit
    var replies: [[UInt8]]
    init(audit: ChargingAudit, replies: [[UInt8]]) { self.audit = audit; self.replies = replies }
    func send(_ bytes: [UInt8], reportID: Int) throws { audit.sent(bytes, id: reportID) }
    func receive(reportID: Int, length: Int) throws -> [UInt8] {
        guard !replies.isEmpty else { throw MouseQueryError.io(operation: "模拟断开", code: -1) }
        return replies.removeFirst()
    }
    func close() { audit.closed() }
}

struct ChargingReadServiceTests {
    private func device(pid: Int = 0x00E6) -> DeviceInfo {
        DeviceInfo.group([MouseReadServiceTests().controlInterface(pid: pid)])[0]
    }

    @Test func originalCaptureResponsesDecodeWithoutUsingOurFrameBuilder() throws {
        // Archive 746a881e…3411: wired-polling record 4, wireless-config record 4.
        // The capture's transaction differs; it is not included in the protocol CRC.
        for (prefix, crc, expected) in [([UInt8(2), 0x1A, 0, 0, 0, 2, 7, 0x84, 0, 1], UInt8(0x80), MouseChargingState.charging),
                                         ([UInt8(2), 0x1B, 0, 0, 0, 2, 7, 0x84, 0, 0], UInt8(0x81), .notCharging)] {
            var captured = prefix + Array(repeating: UInt8(0), count: 78) + [crc, 0]
            captured[1] = 0x1F // Align only the per-connection transaction with this client's expected echo.
            let reply = try ViperV4ReadProtocol.reply(captured, for: .charging)
            guard case let .payload(payload) = reply else { Issue.record("Captured success was not decoded"); continue }
            #expect(try ViperV4ReadProtocol.chargingState(payload) == expected)
        }
    }

    @Test func independentReadSendsOneExactQueryAndClosesEvenAfterBusy() async {
        let audit = ChargingAudit()
        let fixture = ViperReadProtocolTests()
        let reader = ChargingReadService { _ in
            ChargingTransport(audit: audit, replies: [fixture.response(.charging, payload: [0, 0], status: 1),
                                                       fixture.response(.charging, payload: [0, 0])])
        }
        let result = await reader.read(device())
        let (frames, ids, closes) = audit.snapshot()
        #expect(result.state == .notCharging)
        #expect(result.issue == nil)
        #expect(frames.count == 1 && ids == [0] && closes == 1)
        #expect(frames.first == [0, 0x1F, 0, 0, 0, 2, 7, 0x84] + Array(repeating: UInt8(0), count: 80) + [0x81, 0])
    }

    @Test func failuresDoNotTurnIntoNotChargingAndAlwaysClose() async {
        let fixture = ViperReadProtocolTests()
        let cases: [([[UInt8]], ReadFailureKind)] = [
            ([fixture.response(.charging, payload: [0, 2])], .invalidData),
            ([fixture.response(.charging, payload: [0, 0], status: 4)], .timeout),
            ([fixture.response(.charging, payload: [0, 0], status: 5)], .unsupported),
            ([fixture.response(.battery, payload: [0, 100])], .protocolMismatch),
            ([], .io)
        ]
        for (replies, expected) in cases {
            let audit = ChargingAudit()
            let reader = ChargingReadService { _ in ChargingTransport(audit: audit, replies: replies) }
            let result = await reader.read(device())
            #expect(result.state == nil)
            #expect(result.issue?.field == "charging" && result.issue?.kind == expected)
            #expect(audit.snapshot().0.count == 1 && audit.snapshot().2 == 1)
        }
    }

    @Test func neighbouringMouseAndKeyboardPIDsNeverOpenTransport() async {
        for pid in [0x00E5, 0x02D2, 0x00D5] {
            let reader = ChargingReadService { _ in
                Issue.record("Unsupported PID opened a vendor transport")
                throw MouseQueryError.unsupportedDevice
            }
            #expect(!ChargingReadService.canRead(device(pid: pid)))
            #expect(await reader.read(device(pid: pid)).state == nil)
        }
    }

    @Test func chargingSuccessAndFailureRemainDistinctInSummaryAndDiagnostics() throws {
        let device = device()
        let valid = MouseChargingReading(deviceID: device.id, interfaceID: 3, readAt: Date(), state: .charging, issue: nil)
        let failed = MouseChargingReading(deviceID: device.id, interfaceID: 3, readAt: Date(), state: nil,
                                           issue: MouseReadIssue(field: "charging", message: "模拟超时", kind: .timeout))
        #expect(DeviceReadSummary.assess(charging: valid).state == .deviceResponse)
        #expect(DeviceReadSummary.assess(charging: failed).state == .unconfirmed)
        let battery = MouseTelemetry(deviceID: device.id, interfaceID: 3, readAt: Date(), batteryPercent: 0, dpi: nil, issues: [])
        #expect(DeviceReadSummary.assess(mouse: battery, charging: failed).state == .partial)
        #expect(AdapterCatalog.assess(device, charging: valid).capabilities.first { $0.id == "charging" }?.session.state == .succeeded)
        #expect(AdapterCatalog.assess(device).capabilities.first { $0.id == "charging" }?.session.state == .notRead)
        let data = try DiagnosticSnapshot(interfaces: device.interfaces, chargingReadouts: [device.id: valid]).jsonData()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(DiagnosticSnapshot.self, from: data)
        #expect(snapshot.chargingReadouts?[device.id]?.state == .charging)
        #expect(snapshot.mode == "manual-status-queries; no setting commands")
    }
}
