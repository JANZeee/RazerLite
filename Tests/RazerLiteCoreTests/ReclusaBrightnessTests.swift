import Foundation
import Testing
@testable import RazerLiteCore

struct ReclusaBrightnessFixtures {
    func interface(_ number: Int) -> HIDInterface {
        .init(id: UInt64(number + 10), vendorID: 0x1532, productID: 0x02F5,
              product: "Razer Reclusa Mini 65%", manufacturer: "Fixture", transport: "USB",
              locationID: nil, versionNumber: nil, usbDeviceID: 100, usbInterfaceNumber: number,
              usbDeviceRelease: nil, primaryUsagePage: number == 3 ? 12 : 1,
              primaryUsage: number == 3 ? 1 : 6, usages: [], maxInputReportSize: number == 3 ? 0 : 8,
              maxOutputReportSize: 0, maxFeatureReportSize: number == 3 ? 90 : 0,
              registryClass: "Fixture", observedDrivers: [], isVirtual: false)
    }
    func device() -> DeviceInfo { .init(id: "reclusa-fixture", interfaces: [interface(1), interface(3)]) }
    func modified(_ fields: [String: Any], number: Int = 3) throws -> HIDInterface {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(interface(number))) as? [String: Any])
        for (key, value) in fields { object[key] = value }
        return try JSONDecoder().decode(HIDInterface.self, from: JSONSerialization.data(withJSONObject: object))
    }
    // Synthetic ACKs, independently assembled. These are protocol tests, not hardware evidence.
    func response(_ command: UInt8, payload: [UInt8], status: UInt8 = 2, transaction: UInt8? = nil) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 90)
        bytes[0] = status; bytes[1] = transaction ?? (command == 0x80 ? 0x80 : 0x81)
        bytes[5] = UInt8(payload.count); bytes[6] = 0x0F; bytes[7] = command
        bytes.replaceSubrange(8..<(8 + payload.count), with: payload)
        bytes[88] = bytes[2..<88].reduce(0, ^)
        return bytes
    }
    var region: [UInt8] { response(0x80, payload: [5, 30, 1, 15, 5]) }
    func brightness(_ raw: UInt8) -> [UInt8] { response(0x84, payload: [1, 5, raw]) }
}

private final class ReclusaReadAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [[UInt8]] = []
    private var opens = 0
    private var receives = 0
    private var closes = 0
    private var active = 0
    private var maximumActive = 0
    func open() { lock.lock(); defer { lock.unlock() }; opens += 1; active += 1; maximumActive = max(maximumActive, active) }
    func send(_ bytes: [UInt8]) { lock.lock(); defer { lock.unlock() }; frames.append(bytes) }
    func receive() { lock.lock(); defer { lock.unlock() }; receives += 1 }
    func close() { lock.lock(); defer { lock.unlock() }; closes += 1; active -= 1 }
    func snapshot() -> (frames: [[UInt8]], opens: Int, receives: Int, closes: Int, maximumActive: Int) {
        lock.lock(); defer { lock.unlock() }; return (frames, opens, receives, closes, maximumActive)
    }
}

private final class ReclusaReadTransport: HIDFeatureTransport {
    private var replies: [[UInt8]]
    private let audit: ReclusaReadAudit
    private let failsSend: Bool
    init(replies: [[UInt8]], audit: ReclusaReadAudit, failsSend: Bool) {
        self.replies = replies; self.audit = audit; self.failsSend = failsSend
    }
    func send(_ bytes: [UInt8], reportID: Int) throws {
        #expect(reportID == 0 && bytes.count == 90)
        audit.send(bytes)
        if failsSend { throw DeviceQueryError.io(operation: "模拟发送失败", code: -1) }
    }
    func receive(reportID: Int, length: Int) throws -> [UInt8] {
        #expect(reportID == 0 && length == 90)
        audit.receive()
        guard !replies.isEmpty else { throw DeviceQueryError.deviceChanged }
        return replies.removeFirst()
    }
    func close() { audit.close() }
}

struct ReclusaBrightnessTests {
    private let fixtures = ReclusaBrightnessFixtures()
    private func service(_ audit: ReclusaReadAudit, replies: [[UInt8]], failsSend: Bool = false) -> ReclusaBrightnessReadService {
        .init(factory: { _ in
            audit.open()
            return ReclusaReadTransport(replies: replies, audit: audit, failsSend: failsSend)
        }, wait: {})
    }

    @Test func getFramesMatchReviewedFieldsWithoutAnySettingCommand() throws {
        var regions = [UInt8](repeating: 0, count: 90)
        regions.replaceSubrange(0..<8, with: [0, 0x80, 0, 0, 0, 80, 0x0F, 0x80])
        regions[88] = 0xDF
        #expect(ReclusaBrightnessProtocol.regionsRequest() == regions)
        var brightness = [UInt8](repeating: 0, count: 90)
        brightness.replaceSubrange(0..<11, with: [0, 0x81, 0, 0, 0, 3, 0x0F, 0x84, 1, 5, 0])
        brightness[88] = 0x8C
        #expect(try ReclusaBrightnessProtocol.brightnessRequest(regionID: 5) == brightness)
        #expect(throws: DeviceQueryError.self) { try ReclusaBrightnessProtocol.brightnessRequest(regionID: 0) }
    }

    @Test func exactIdentityAndUniqueInterfaceAreRequiredBeforeOpeningTransport() async throws {
        #expect(ReclusaBrightnessReadService.canRead(fixtures.device()))
        let changes: [[String: Any]] = [
            ["productID": 0x02F4], ["productID": 0x02E3], ["vendorID": 0x068E],
            ["product": "Razer Reclusa X Mini 65%"], ["transport": "Bluetooth"], ["isVirtual": true],
            ["usbInterfaceNumber": 2], ["usbDeviceID": NSNull()], ["usbDeviceID": 200], ["primaryUsagePage": 1],
            ["primaryUsage": 6], ["maxInputReportSize": 1], ["maxOutputReportSize": 1], ["maxFeatureReportSize": 91]
        ]
        var rejected = try changes.map { DeviceInfo(id: "wrong", interfaces: [fixtures.interface(1), try fixtures.modified($0)]) }
        rejected.append(.init(id: "ambiguous", interfaces: [fixtures.interface(1), fixtures.interface(3), try fixtures.modified(["id": 14])]))
        rejected.append(.init(id: "no-keyboard", interfaces: [fixtures.interface(3)]))
        rejected.append(.init(id: "empty", interfaces: []))
        rejected.append(.init(id: "mixed-name", interfaces: [try fixtures.modified(["product": "Other"], number: 1), fixtures.interface(3)]))
        let audit = ReclusaReadAudit()
        for device in rejected {
            #expect(!ReclusaBrightnessReadService.canRead(device))
            let reading = await service(audit, replies: []).read(device)
            #expect(!reading.hasValue && reading.percent == nil && reading.rawBrightness == nil)
        }
        #expect(audit.snapshot().opens == 0)
    }

    @Test func readsOnlyRegionThenProfileOneAndPreservesZero() async {
        for (raw, percent) in [(UInt8(0), 0), (1, 1), (127, 50), (128, 51), (254, 100), (255, 100)] {
            let audit = ReclusaReadAudit()
            let reading = await service(audit, replies: [fixtures.region, fixtures.brightness(raw)]).read(fixtures.device())
            #expect(reading.hasValue && reading.issue == nil)
            #expect(reading.profileID == 1 && reading.regionID == 5 && reading.rawBrightness == raw && reading.percent == percent)
            #expect(reading.deviceID == fixtures.device().id && reading.interfaceID == 13)
            #expect(audit.snapshot().frames.map { $0[7] } == [0x80, 0x84])
            #expect(audit.snapshot().frames.map { $0[1] } == [0x80, 0x81])
            #expect(audit.snapshot().opens == 1 && audit.snapshot().closes == 1)
        }
    }

    @Test func incompleteEmptyZeroOrMultipleRegionsNeverFallbackToBrightness() async {
        let payloads: [[UInt8]] = [[], [5], [5, 30, 1, 15], [0, 30, 1, 15, 5],
                                  [5, 30, 1, 15, 5, 6, 30, 1, 15, 5], [5, 30, 1, 15, 5, 5, 30, 1, 15, 5]]
        for payload in payloads {
            let audit = ReclusaReadAudit()
            let reading = await service(audit, replies: [fixtures.response(0x80, payload: payload)]).read(fixtures.device())
            #expect(!reading.hasValue && reading.issue != nil && reading.regionID == nil && reading.percent == nil)
            #expect(audit.snapshot().frames.count == 1 && audit.snapshot().closes == 1)
        }
    }

    @Test func brightnessMustEchoRequestedProfileAndRegionWithExactlyThreeBytes() async {
        let payloads: [[UInt8]] = [[], [1, 5], [0, 5, 128], [1, 0, 128], [1, 6, 128], [1, 5, 128, 0]]
        for payload in payloads {
            let audit = ReclusaReadAudit()
            let reading = await service(audit, replies: [fixtures.region, fixtures.response(0x84, payload: payload)]).read(fixtures.device())
            #expect(!reading.hasValue && reading.issue != nil && reading.regionID == 5)
            #expect(reading.rawBrightness == nil && reading.percent == nil)
            #expect(audit.snapshot().frames.count == 2 && audit.snapshot().closes == 1)
        }
    }

    @Test func busyReadsAgainWithoutResendingAndHasFiniteLimit() async {
        let busyRegion = fixtures.response(0x80, payload: [], status: 1)
        let busyBrightness = fixtures.response(0x84, payload: [], status: 1)
        let audit = ReclusaReadAudit()
        let reading = await service(audit, replies: [busyRegion, fixtures.region, busyBrightness, fixtures.brightness(128)]).read(fixtures.device())
        #expect(reading.hasValue && audit.snapshot().frames.count == 2 && audit.snapshot().receives == 4)
        for regionSucceeded in [false, true] {
            let exhausted = ReclusaReadAudit()
            let responses = regionSucceeded ? [fixtures.region] + Array(repeating: busyBrightness, count: 16)
                : Array(repeating: busyRegion, count: 16)
            let failed = await service(exhausted, replies: responses).read(fixtures.device())
            #expect(!failed.hasValue && failed.issue?.kind == .busy && failed.percent == nil)
            #expect(exhausted.snapshot().frames.count == (regionSucceeded ? 2 : 1))
            #expect(exhausted.snapshot().receives == (regionSucceeded ? 17 : 16) && exhausted.snapshot().closes == 1)
        }
    }

    @Test func corruptMismatchedAndRejectedFramesStopBeforeNextCommand() async {
        var badChecksum = fixtures.region; badChecksum[88] ^= 1
        var wrongClass = fixtures.region; wrongClass[6] = 7; wrongClass[88] = wrongClass[2..<88].reduce(0, ^)
        var fragmented = fixtures.region; fragmented[2] = 1; fragmented[88] = fragmented[2..<88].reduce(0, ^)
        let cases = [Array(fixtures.region.dropLast()), badChecksum, wrongClass, fragmented,
                     fixtures.response(0x80, payload: [5, 30, 1, 15, 5], transaction: 0x1F),
                     fixtures.response(0x84, payload: [1, 5, 128]), fixtures.response(0x80, payload: [], status: 5)]
        for reply in cases {
            let audit = ReclusaReadAudit()
            let failed = await service(audit, replies: [reply]).read(fixtures.device())
            #expect(!failed.hasValue && failed.issue != nil && failed.percent == nil)
            #expect(audit.snapshot().frames.count == 1 && audit.snapshot().receives == 1 && audit.snapshot().closes == 1)
        }
    }

    @Test func transportFailuresCloseAndNeverExposePartialBrightness() async {
        for (replies, failsSend) in [([[UInt8]](), true), ([], false), ([fixtures.region], false)] {
            let audit = ReclusaReadAudit()
            let failed = await service(audit, replies: replies, failsSend: failsSend).read(fixtures.device())
            #expect(!failed.hasValue && failed.issue != nil && failed.rawBrightness == nil && failed.percent == nil)
            #expect(audit.snapshot().opens == 1 && audit.snapshot().closes == 1)
        }
    }

    @Test func independentReadsShareSerialExecutorAndDoNotRegisterBatteryCapability() async {
        let audit = ReclusaReadAudit()
        let reader = service(audit, replies: [fixtures.region, fixtures.brightness(100)])
        async let first = reader.read(fixtures.device())
        async let second = reader.read(fixtures.device())
        let values = await [first, second]
        #expect(values.allSatisfy { $0.hasValue })
        #expect(audit.snapshot().opens == 2 && audit.snapshot().closes == 2 && audit.snapshot().maximumActive == 1)
        #expect(DeviceReadRegistry.backends(for: fixtures.device()).isEmpty)
        #expect(AdapterManifestCatalog.manifest(for: fixtures.device())?.feature("brightness")?.implementation == .implemented)
    }

    @Test func diagnosticPreservesProfileScopeAndDecodesHistoricalSchemaWithoutBrightness() async throws {
        let reading = await service(ReclusaReadAudit(), replies: [fixtures.region, fixtures.brightness(128)]).read(fixtures.device())
        let snapshot = DiagnosticSnapshot(interfaces: fixtures.device().interfaces,
                                          keyboardBrightnessReadouts: [reading.deviceID: reading])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticSnapshot.self, from: snapshot.jsonData())
        let preserved = try #require(decoded.keyboardBrightnessReadouts?[reading.deviceID])
        #expect(preserved.profileID == 1 && preserved.regionID == 5 && preserved.rawBrightness == 128 && preserved.percent == 51)
        #expect(decoded.mode == "manual-status-queries; no setting commands")
        var historical = try #require(JSONSerialization.jsonObject(with: DiagnosticSnapshot(interfaces: []).jsonData()) as? [String: Any])
        historical["schemaVersion"] = 6
        for key in ["keyboardBrightnessReadouts", "adapterManifests", "adapterAssessments", "connectionCheck"] {
            historical.removeValue(forKey: key)
        }
        let old = try decoder.decode(DiagnosticSnapshot.self, from: JSONSerialization.data(withJSONObject: historical))
        #expect(old.schemaVersion == 6 && old.keyboardBrightnessReadouts == nil)
    }
}
