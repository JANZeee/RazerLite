import Foundation
import Testing
@testable import RazerLiteCore

private struct ReclusaPowerFixtures {
    func device() -> DeviceInfo { ReclusaBrightnessFixtures().device() }

    /// Independently assembled synthetic replies, not a hardware capture or production encoder.
    func response(_ field: KeyboardPowerField, payload: [UInt8], transaction: UInt8 = 0x80,
                  status: UInt8 = 2) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 90)
        bytes[0] = status; bytes[1] = transaction; bytes[5] = UInt8(payload.count)
        bytes[6] = 7; bytes[7] = field == .battery ? 0x80 : 0x84
        bytes.replaceSubrange(8..<(8 + payload.count), with: payload)
        bytes[88] = bytes[2..<88].reduce(0, ^)
        return bytes
    }
}

private final class ReclusaPowerAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [[UInt8]] = []
    private var opens = 0
    private var receives = 0
    private var closes = 0
    func open() { lock.lock(); defer { lock.unlock() }; opens += 1 }
    func send(_ frame: [UInt8]) { lock.lock(); defer { lock.unlock() }; frames.append(frame) }
    func receive() { lock.lock(); defer { lock.unlock() }; receives += 1 }
    func close() { lock.lock(); defer { lock.unlock() }; closes += 1 }
    func snapshot() -> (frames: [[UInt8]], opens: Int, receives: Int, closes: Int) {
        lock.lock(); defer { lock.unlock() }; return (frames, opens, receives, closes)
    }
}

private final class ReclusaPowerTransport: HIDFeatureTransport {
    private let audit: ReclusaPowerAudit
    private var replies: [[UInt8]]
    private let failSend: Bool
    private let echo: Bool
    private var request: [UInt8]?
    init(audit: ReclusaPowerAudit, replies: [[UInt8]], failSend: Bool, echo: Bool) {
        self.audit = audit; self.replies = replies; self.failSend = failSend; self.echo = echo
    }
    func send(_ bytes: [UInt8], reportID: Int) throws {
        #expect(reportID == 0 && bytes.count == 90)
        audit.send(bytes); request = bytes
        if failSend { throw DeviceQueryError.io(operation: "模拟发送失败", code: -1) }
    }
    func receive(reportID: Int, length: Int) throws -> [UInt8] {
        #expect(reportID == 0 && length == 90)
        audit.receive()
        if echo, let request {
            return ReclusaPowerFixtures().response(request[7] == 0x80 ? .battery : .charging,
                                                    payload: [0, 1], transaction: request[1])
        }
        guard !replies.isEmpty else { throw DeviceQueryError.io(operation: "模拟断开", code: -1) }
        return replies.removeFirst()
    }
    func close() { audit.close() }
}

struct ReclusaPowerTests {
    private let fixtures = ReclusaPowerFixtures()
    private func service(_ audit: ReclusaPowerAudit, replies: [[UInt8]], failSend: Bool = false,
                         echo: Bool = false) -> KeyboardPowerReadService {
        .init(transportFactory: { _ in
            audit.open()
            return ReclusaPowerTransport(audit: audit, replies: replies, failSend: failSend, echo: echo)
        }, wait: {})
    }

    @Test func requestsUseBatteryZeroAndTheDualLinkKeyboardBankOnly() throws {
        for (field, command, crc) in [(KeyboardPowerField.battery, UInt8(0x80), UInt8(0x85)), (.charging, 0x84, 0x81)] {
            let expected: [UInt8] = [0, 0x80, 0, 0, 0, 2, 7, command]
                + Array(repeating: UInt8(0), count: 80) + [crc, 0]
            #expect(try ReclusaPowerProtocol.request(field) == expected)
            #expect(try ReclusaPowerProtocol.request(field, transaction: 0x9E)[1] == 0x9E)
        }
        for transaction: UInt8 in [0, 0x1F, 0x7F, 0x9F, 0xFF] {
            #expect(throws: DeviceQueryError.self) { try ReclusaPowerProtocol.request(.battery, transaction: transaction) }
        }
    }

    @Test func exactReceiverIdentityIsRequiredBeforeAnyTransportOpen() async throws {
        let identity = ReclusaBrightnessFixtures()
        #expect(KeyboardPowerReadService.controlInterface(in: fixtures.device())?.id == 13)
        #expect(DeviceReadRegistry.backends(for: fixtures.device()) == [.reclusaMini65USB])
        #expect(!BatteryRefreshEligibility.allows(.reclusaMini65USB, simulation: false))
        let changes: [[String: Any]] = [
            ["productID": 0x02F4], ["productID": 0x02F6], ["productID": 0x02D2], ["vendorID": 0x068E],
            ["product": "Other Razer Keyboard"], ["transport": "Bluetooth"], ["isVirtual": true],
            ["usbInterfaceNumber": 2], ["usbDeviceID": NSNull()], ["usbDeviceID": 200],
            ["primaryUsagePage": 1], ["maxInputReportSize": 1], ["maxOutputReportSize": 1], ["maxFeatureReportSize": 91]
        ]
        var rejected = try changes.map {
            DeviceInfo(id: "wrong", interfaces: [identity.interface(1), try identity.modified($0)])
        }
        rejected.append(.init(id: "ambiguous", interfaces: [identity.interface(1), identity.interface(3), try identity.modified(["id": 14])]))
        rejected.append(.init(id: "missing-keyboard", interfaces: [identity.interface(3)]))
        rejected.append(.init(id: "empty", interfaces: []))
        let audit = ReclusaPowerAudit()
        let reader = service(audit, replies: [])
        for device in rejected {
            #expect(!KeyboardPowerReadService.canRead(device))
            let reading = await reader.read(device, field: .battery)
            #expect(!reading.hasValue && reading.batteryPercent == nil && reading.chargingState == nil)
        }
        #expect(audit.snapshot().opens == 0)
    }

    @Test func batteryUsesFloorAndZeroIsARealValueOnlyAfterAValidResponse() async {
        for (raw, percent) in [(UInt8(0), 0), (1, 0), (127, 49), (128, 50), (254, 99), (255, 100)] {
            let audit = ReclusaPowerAudit()
            let result = await service(audit, replies: [fixtures.response(.battery, payload: [0, raw])])
                .read(fixtures.device(), field: .battery)
            #expect(result.hasValue && result.batteryPercent == percent && result.chargingState == nil)
            #expect(result.matches(fixtures.device(), field: .battery))
            #expect(!result.matches(fixtures.device(), field: .charging))
            #expect(!result.matches(.init(id: "different", interfaces: fixtures.device().interfaces), field: .battery))
            #expect(audit.snapshot().frames.count == 1 && audit.snapshot().closes == 1)
        }
        // BlackWidow's separately reviewed conversion remains unchanged.
        #expect((try? BlackWidowPowerProtocol.batteryPercent([0, 127])) == 50)
    }

    @Test func chargingKeepsUnknownWireValuesWithoutInferringBatteryPercent() async {
        for raw: UInt8 in [0, 1, 2, 3, 4, 5, 6, 255] {
            let result = await service(ReclusaPowerAudit(), replies: [fixtures.response(.charging, payload: [0, raw])])
                .read(fixtures.device(), field: .charging)
            let expected: DeviceChargingState = raw == 0 ? .notCharging : raw == 1 ? .charging : .unknown(raw)
            #expect(result.hasValue && result.chargingState == expected && result.batteryPercent == nil)
        }
        #expect(throws: DeviceQueryError.self) { try BlackWidowPowerProtocol.chargingState([0, 2]) }
    }

    @Test func malformedRejectedAndMismatchedResponsesNeverInventAValueOrRetry() async {
        let valid = fixtures.response(.battery, payload: [0, 128])
        var crc = valid; crc[88] ^= 1
        var wrongClass = valid; wrongClass[6] = 0x0F; wrongClass[88] = wrongClass[2..<88].reduce(0, ^)
        var fragmented = valid; fragmented[2] = 1; fragmented[88] = fragmented[2..<88].reduce(0, ^)
        var reserved = valid; reserved[89] = 1
        let replies = [Array(valid.dropLast()), crc, wrongClass, fragmented, reserved,
            fixtures.response(.battery, payload: [0, 128], transaction: 0x81),
            fixtures.response(.battery, payload: [0, 128], transaction: 0x9F),
            fixtures.response(.charging, payload: [0, 1]),
            fixtures.response(.battery, payload: [1, 128]), fixtures.response(.battery, payload: []),
            fixtures.response(.battery, payload: [0]), fixtures.response(.battery, payload: [0, 128, 0]),
            fixtures.response(.battery, payload: [0, 0], status: 0),
            fixtures.response(.battery, payload: [0, 0], status: 3),
            fixtures.response(.battery, payload: [0, 0], status: 4),
            fixtures.response(.battery, payload: [0, 0], status: 5)]
        for reply in replies {
            let audit = ReclusaPowerAudit()
            let result = await service(audit, replies: [reply]).read(fixtures.device(), field: .battery)
            #expect(!result.hasValue && result.issue != nil && result.batteryPercent == nil && result.chargingState == nil)
            #expect(audit.snapshot().frames.count == 1 && audit.snapshot().receives == 1 && audit.snapshot().closes == 1)
        }
        for payload: [UInt8] in [[], [0], [0, 1, 0], [1, 1]] {
            #expect(throws: DeviceQueryError.self) { try ReclusaPowerProtocol.chargingState(payload) }
        }
    }

    @Test func busyOnlyReceivesAgainWithAFiniteLimit() async {
        let busy = fixtures.response(.charging, payload: [], status: 1)
        let audit = ReclusaPowerAudit()
        let success = await service(audit, replies: [busy, fixtures.response(.charging, payload: [0, 1])])
            .read(fixtures.device(), field: .charging)
        #expect(success.chargingState == .charging)
        #expect(audit.snapshot().frames.count == 1 && audit.snapshot().receives == 2)
        let exhausted = ReclusaPowerAudit()
        let failure = await service(exhausted, replies: Array(repeating: busy, count: 16))
            .read(fixtures.device(), field: .charging)
        #expect(!failure.hasValue && failure.issue?.kind == .busy)
        #expect(exhausted.snapshot().frames.count == 1 && exhausted.snapshot().receives == 16 && exhausted.snapshot().closes == 1)
    }

    @Test func sequenceAdvancesThroughThirtyThenWrapsInTheKeyboardBank() async {
        let audit = ReclusaPowerAudit()
        let reader = service(audit, replies: [], echo: true)
        for _ in 0..<33 {
            let result = await reader.read(fixtures.device(), field: .battery)
            #expect(result.hasValue)
        }
        let sent = audit.snapshot().frames
        #expect(sent.map { $0[1] } == Array(UInt8(0x80)...UInt8(0x9E)) + [0x80, 0x81])
        #expect(sent.allSatisfy { $0[6] == 7 && $0[7] == 0x80 && $0[5] == 2 && $0[8] == 0 })
    }

    @Test func transportFailuresStayUnknownAndAlwaysCloseOpenedSessions() async {
        let openFailure = KeyboardPowerReadService { _ in throw DeviceQueryError.io(operation: "模拟打开失败", code: -1) }
        let opening = await openFailure.read(fixtures.device(), field: .battery)
        #expect(!opening.hasValue && opening.batteryPercent == nil)
        for failSend in [true, false] {
            let audit = ReclusaPowerAudit()
            let result = await service(audit, replies: [], failSend: failSend).read(fixtures.device(), field: .battery)
            #expect(!result.hasValue && result.batteryPercent == nil && result.issue != nil)
            #expect(audit.snapshot().closes == 1 && audit.snapshot().receives == (failSend ? 0 : 1))
        }
    }

    @Test func chargingCodablePreservesHistoricalStringsAndUnknownRawValues() throws {
        let encoder = JSONEncoder(); let decoder = JSONDecoder()
        #expect(try decoder.decode(DeviceChargingState.self, from: Data("\"charging\"".utf8)) == .charging)
        #expect(try decoder.decode(DeviceChargingState.self, from: Data("\"notCharging\"".utf8)) == .notCharging)
        #expect(try encoder.encode(DeviceChargingState.notCharging) == Data("\"notCharging\"".utf8))
        let unknown = DeviceChargingState.unknown(6)
        #expect(try decoder.decode(DeviceChargingState.self, from: encoder.encode(unknown)) == unknown)
        #expect(unknown.title.contains("6") && unknown != .charging && unknown != .notCharging)
        #expect(DeviceChargingState(rawValue: "unknown:256") == nil)
    }
}
