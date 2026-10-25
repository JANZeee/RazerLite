import Foundation
import Testing
@testable import RazerLiteCore

private final class SimulatedFeatureTransport: HIDFeatureTransport {
    var sent: [[UInt8]] = []
    var replies: [[UInt8]] = []
    var receiveCount = 0
    var closed = false
    var audit: TransportAudit?
    func send(_ bytes: [UInt8], reportID: Int) throws { sent.append(bytes); audit?.sent(bytes[7]) }
    func receive(reportID: Int, length: Int) throws -> [UInt8] {
        receiveCount += 1
        guard !replies.isEmpty else { throw MouseQueryError.io(operation: "模拟断连", code: -1) }
        return replies.removeFirst()
    }
    func close() { closed = true; audit?.closed() }
}

private final class TransportAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [UInt8] = []
    private var closes = 0
    func sent(_ command: UInt8) { lock.lock(); defer { lock.unlock() }; commands.append(command) }
    func closed() { lock.lock(); defer { lock.unlock() }; closes += 1 }
    func snapshot() -> ([UInt8], Int) { lock.lock(); defer { lock.unlock() }; return (commands, closes) }
}

struct MouseReadServiceTests {
    func controlInterface(id: UInt64 = 3, pid: Int = 0x00E6, page: Int = 12, usbID: UInt64 = 100) -> HIDInterface {
        HIDInterface(id: id, vendorID: 0x1532, productID: pid, product: "Viper fixture", manufacturer: nil,
                     transport: "USB", locationID: 0, versionNumber: 0x0101, usbDeviceID: usbID,
                     usbInterfaceNumber: 3, usbDeviceRelease: 0x0101, primaryUsagePage: page, primaryUsage: 1,
                     usages: [], maxInputReportSize: 0, maxOutputReportSize: 0, maxFeatureReportSize: 90,
                     registryClass: "Fixture", observedDrivers: [], isVirtual: false)
    }

    @Test func interfaceSelectionRejectsNeighboursAndInputCollections() {
        let good = DeviceInfo.group([controlInterface()])[0]
        #expect(MouseReadService.canRead(good))
        #expect(!MouseReadService.canRead(DeviceInfo.group([controlInterface(pid: 0x00E5)])[0]))
        #expect(!MouseReadService.canRead(DeviceInfo.group([controlInterface(page: 1)])[0]))
        #expect(!MouseReadService.canRead(DeviceInfo.group([controlInterface(), controlInterface(id: 4)])[0]))
        #expect(!ViperV4Adapter.isSameInterface(controlInterface(id: 4), expected: controlInterface()))
    }

    @Test func busyResponsesAreBoundedAndRequestIsNotResent() throws {
        let fixtures = ViperReadProtocolTests()
        let transport = SimulatedFeatureTransport()
        transport.replies = [fixtures.response(.battery, payload: [], status: 1), fixtures.response(.battery, payload: [0, 128])]
        let value = try ViperV4ControlClient(transport: transport, attempts: 2, busyDelay: 0).query(.battery)
        #expect(value == [0, 128])
        #expect(transport.sent.count == 1)
        #expect(transport.receiveCount == 2)

        let busy = SimulatedFeatureTransport()
        busy.replies = Array(repeating: fixtures.response(.battery, payload: [], status: 1), count: 3)
        #expect(throws: MouseQueryError.busyTimeout) {
            try ViperV4ControlClient(transport: busy, attempts: 3, busyDelay: 0).query(.battery)
        }
        #expect(busy.receiveCount == 3)
        #expect(busy.sent.count == 1)
    }

    @Test func unexpectedResponseStopsWithoutExtraCommands() {
        let transport = SimulatedFeatureTransport()
        transport.replies = [ViperReadProtocolTests().response(.dpiStages, payload: [])]
        #expect(throws: MouseQueryError.mismatchedResponse(transaction: 0x1F, commandClass: 4, commandID: 0x86)) { try ViperV4ControlClient(transport: transport).query(.battery) }
        #expect(transport.sent.count == 1)
        #expect(transport.receiveCount == 1)
    }

    @Test func transportOpenFailureIsReportedInsteadOfInventingValues() async {
        let service = MouseReadService { _ in throw MouseQueryError.io(operation: "模拟拒绝", code: -1) }
        let result = await service.read(DeviceInfo.group([controlInterface()])[0])
        #expect(result.batteryPercent == nil)
        #expect(result.dpi == nil)
        #expect(!result.isComplete)
        #expect(result.issues.count == 1)
    }

    @Test func fullQueriesSerializeAndCloseTheirSessions() async {
        let audit = TransportAudit()
        let service = MouseReadService { _ in
            let transport = SimulatedFeatureTransport()
            transport.audit = audit
            let fixtures = ViperReadProtocolTests()
            transport.replies = [fixtures.response(.battery, payload: [0, 153]),
                                 fixtures.response(.dpiStages, payload: fixtures.dpiPayload())]
            return transport
        }
        let device = DeviceInfo.group([controlInterface()])[0]
        async let first = service.read(device)
        async let second = service.read(device)
        let results = await [first, second]
        #expect(results.allSatisfy { $0.isComplete })
        #expect(results.allSatisfy { $0.batteryPercent == 60 && $0.dpi?.current.x == 1600 })
        #expect(audit.snapshot().0 == [0x80, 0x86, 0x80, 0x86])
        #expect(audit.snapshot().1 == 2)
    }

    @Test func validatedPartialValueSurvivesLaterFailureAndHandleCloses() async {
        let audit = TransportAudit()
        let service = MouseReadService { _ in
            let transport = SimulatedFeatureTransport()
            transport.audit = audit
            transport.replies = [ViperReadProtocolTests().response(.battery, payload: [0, 153]), [0]]
            return transport
        }
        let result = await service.read(DeviceInfo.group([controlInterface()])[0])
        #expect(result.batteryPercent == 60)
        #expect(result.dpi == nil)
        #expect(result.issues.first?.field == "dpi")
        #expect(!result.isComplete)
        #expect(audit.snapshot().1 == 1)
    }
}
