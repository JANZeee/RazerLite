import Foundation
import Testing
@testable import RazerLiteCore

struct KeyboardPowerFixtures {
    /// Synthetic identity with the shape of the saved 02D2 interface-2 snapshot; not live hardware.
    func interface() -> HIDInterface {
        HIDInterface(id: 2, vendorID: 0x1532, productID: 0x02D2, product: "Keyboard fixture", manufacturer: "Razer",
            transport: "USB", locationID: 1, versionNumber: 0x0100, usbDeviceID: 200, usbInterfaceNumber: 2,
            usbDeviceRelease: 0x0100, primaryUsagePage: 1, primaryUsage: 2,
            usages: [HIDUsage(page: 1, usage: 2), HIDUsage(page: 1, usage: 1)],
            maxInputReportSize: 8, maxOutputReportSize: 0, maxFeatureReportSize: 90,
            registryClass: "Fixture", observedDrivers: ["fixture-driver"], isVirtual: false)
    }
    func device() -> DeviceInfo { DeviceInfo.group([interface()])[0] }
    func modified(_ fields: [String: Any]) throws -> HIDInterface {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(interface())) as? [String: Any])
        for (key, value) in fields { object[key] = value }
        return try JSONDecoder().decode(HIDInterface.self, from: JSONSerialization.data(withJSONObject: object))
    }
    /// Synthetic reports made independently of the production request builder. No capture is claimed.
    func response(_ field: KeyboardPowerField, value: UInt8, status: UInt8 = 2, transaction: UInt8 = 0x9F) -> [UInt8] {
        let command: UInt8 = field == .battery ? 0x80 : 0x84
        let crc: UInt8 = 2 ^ 7 ^ command ^ value
        return [status, transaction, 0, 0, 0, 2, 7, command, 0, value] + Array(repeating: UInt8(0), count: 78) + [crc, 0]
    }
}

private final class KeyboardTransportAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var opens = 0
    private var frames: [[UInt8]] = []
    private var reportIDs: [Int] = []
    private var receives = 0
    private var closes = 0
    private var active = 0
    private var maximumActive = 0
    func opened() { lock.lock(); defer { lock.unlock() }; opens += 1; active += 1; maximumActive = max(maximumActive, active) }
    func sent(_ bytes: [UInt8], id: Int) { lock.lock(); defer { lock.unlock() }; frames.append(bytes); reportIDs.append(id) }
    func received() { lock.lock(); defer { lock.unlock() }; receives += 1 }
    func closed() { lock.lock(); defer { lock.unlock() }; closes += 1; active -= 1 }
    func snapshot() -> (opens: Int, frames: [[UInt8]], ids: [Int], receives: Int, closes: Int, maximumActive: Int) {
        lock.lock(); defer { lock.unlock() }; return (opens, frames, reportIDs, receives, closes, maximumActive)
    }
}

private final class KeyboardFeatureTransport: HIDFeatureTransport {
    let audit: KeyboardTransportAudit
    var replies: [[UInt8]]
    let sendError: DeviceQueryError?
    init(audit: KeyboardTransportAudit, replies: [[UInt8]], sendError: DeviceQueryError?) {
        self.audit = audit; self.replies = replies; self.sendError = sendError
    }
    func send(_ bytes: [UInt8], reportID: Int) throws {
        audit.sent(bytes, id: reportID)
        if let sendError { throw sendError }
    }
    func receive(reportID: Int, length: Int) throws -> [UInt8] {
        audit.received()
        #expect(reportID == 0 && length == 90)
        guard !replies.isEmpty else { throw DeviceQueryError.io(operation: "模拟断开", code: -1) }
        return replies.removeFirst()
    }
    func close() { audit.closed() }
}

struct KeyboardPowerTests {
    let fixtures = KeyboardPowerFixtures()
    private func service(_ audit: KeyboardTransportAudit, replies: [[UInt8]], sendError: DeviceQueryError? = nil) -> KeyboardPowerReadService {
        KeyboardPowerReadService { _ in
            audit.opened()
            return KeyboardFeatureTransport(audit: audit, replies: replies, sendError: sendError)
        }
    }

    @Test func exactRequestsHaveKeyboardTransactionAndNoModeOrSettingsCommands() {
        for (field, command, crc) in [(KeyboardPowerField.battery, UInt8(0x80), UInt8(0x85)), (.charging, 0x84, 0x81)] {
            let expected: [UInt8] = [0, 0x9F, 0, 0, 0, 2, 7, command] + Array(repeating: UInt8(0), count: 80) + [crc, 0]
            #expect(BlackWidowPowerProtocol.request(field) == expected)
        }
    }

    @Test func adapterRejectsOtherPIDsInputLayoutsAmbiguityAndBluetooth() async throws {
        let device = fixtures.device()
        #expect(DeviceReadRegistry.backends(for: device) == [.blackWidowLowProfileUSB])
        #expect(!MouseReadService.canRead(device) && !ChargingReadService.canRead(device))
        let changes: [[String: Any]] = [["productID": 0x02D4], ["productID": 0x02D5], ["productID": 0x00E6],
            ["vendorID": 0x068E], ["transport": "Bluetooth Low Energy"], ["isVirtual": true],
            ["usbInterfaceNumber": 3], ["usbDeviceID": NSNull()], ["maxInputReportSize": 0],
            ["maxOutputReportSize": 1], ["maxFeatureReportSize": 91], ["primaryUsage": 6]]
        var rejected = try changes.map { DeviceInfo.group([try fixtures.modified($0)])[0] }
        rejected.append(DeviceInfo.group([fixtures.interface(), try fixtures.modified(["id": 3])])[0])
        let audit = KeyboardTransportAudit()
        let reader = service(audit, replies: [])
        for value in rejected {
            #expect(!KeyboardPowerReadService.canRead(value))
            #expect(await reader.read(value, field: .battery).hasValue == false)
        }
        #expect(audit.snapshot().opens == 0)
    }

    @Test func batteryZeroIsValidAndBothFieldsQueryIndependently() async {
        for (field, value) in [(KeyboardPowerField.battery, UInt8(0)), (.battery, 255), (.charging, 0), (.charging, 1)] {
            let audit = KeyboardTransportAudit()
            let reading = await service(audit, replies: [fixtures.response(field, value: value)]).read(fixtures.device(), field: field)
            let state = audit.snapshot()
            #expect(reading.hasValue && reading.issue == nil)
            #expect(state.opens == 1 && state.frames.count == 1 && state.ids == [0] && state.closes == 1)
            #expect(state.frames.first?[7] == (field == .battery ? 0x80 : 0x84))
            if field == .battery { #expect(reading.batteryPercent == (value == 0 ? 0 : 100) && reading.chargingState == nil) }
            else { #expect(reading.chargingState == (value == 0 ? .notCharging : .charging) && reading.batteryPercent == nil) }
        }
    }

    @Test func busyOnlyReceivesAgainAndBusyNeverBecomesAValue() async {
        let audit = KeyboardTransportAudit()
        let busy = fixtures.response(.charging, value: 0, status: 1)
        let success = fixtures.response(.charging, value: 1)
        let reading = await service(audit, replies: [busy, success]).read(fixtures.device(), field: .charging)
        #expect(reading.chargingState == .charging)
        #expect(audit.snapshot().frames.count == 1 && audit.snapshot().receives == 2)
        let exhausted = KeyboardTransportAudit()
        let failed = await service(exhausted, replies: Array(repeating: busy, count: 16)).read(fixtures.device(), field: .charging)
        #expect(!failed.hasValue && failed.issue?.kind == .busy)
        #expect(exhausted.snapshot().frames.count == 1 && exhausted.snapshot().receives == 16 && exhausted.snapshot().closes == 1)
    }

    @Test func malformedMismatchedAndRejectedResponsesStopWithoutResend() async {
        var badCRC = fixtures.response(.charging, value: 1); badCRC[88] ^= 1
        let cases: [([UInt8], ReadFailureKind)] = [([0], .invalidData), (badCRC, .invalidData),
            (fixtures.response(.charging, value: 2), .invalidData),
            (fixtures.response(.battery, value: 128), .protocolMismatch),
            (fixtures.response(.charging, value: 1, transaction: 0x1F), .protocolMismatch),
            (fixtures.response(.charging, value: 0, status: 4), .timeout),
            (fixtures.response(.charging, value: 0, status: 5), .unsupported)]
        for (frame, kind) in cases {
            let audit = KeyboardTransportAudit()
            let result = await service(audit, replies: [frame]).read(fixtures.device(), field: .charging)
            #expect(!result.hasValue && result.batteryPercent == nil && result.chargingState == nil && result.issue?.kind == kind)
            #expect(audit.snapshot().frames.count == 1 && audit.snapshot().receives == 1 && audit.snapshot().closes == 1)
        }
        for payload: [UInt8] in [[], [0], [0, 1, 0], [1, 1]] {
            #expect(throws: DeviceQueryError.self) { try BlackWidowPowerProtocol.batteryPercent(payload) }
            #expect(throws: DeviceQueryError.self) { try BlackWidowPowerProtocol.chargingState(payload) }
        }
    }

    @Test func openingSendingAndReceivingErrorsDoNotInventBatteryValues() async {
        let openFailure = KeyboardPowerReadService { _ in throw DeviceQueryError.io(operation: "模拟打开失败", code: -1) }
        #expect(await openFailure.read(fixtures.device(), field: .battery).hasValue == false)
        let sendAudit = KeyboardTransportAudit()
        let sending = await service(sendAudit, replies: [], sendError: .io(operation: "模拟发送失败", code: -1))
            .read(fixtures.device(), field: .battery)
        #expect(!sending.hasValue && sendAudit.snapshot().receives == 0 && sendAudit.snapshot().closes == 1)
        let receiveAudit = KeyboardTransportAudit()
        let receiving = await service(receiveAudit, replies: []).read(fixtures.device(), field: .charging)
        #expect(!receiving.hasValue && receiveAudit.snapshot().closes == 1)
    }

    @Test func concurrentKeyboardSessionsCannotOverlapTheirFeatureTransfers() async {
        let audit = KeyboardTransportAudit()
        let battery = service(audit, replies: [fixtures.response(.battery, value: 128)])
        let charging = service(audit, replies: [fixtures.response(.charging, value: 0)])
        async let first = battery.read(fixtures.device(), field: .battery)
        async let second = charging.read(fixtures.device(), field: .charging)
        let results = await [first, second]
        #expect(results.allSatisfy { $0.hasValue })
        #expect(audit.snapshot().maximumActive == 1 && audit.snapshot().closes == 2)
    }
}
