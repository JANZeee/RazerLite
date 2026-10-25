import Foundation
import Testing
@testable import RazerLiteCore

struct ViperReadProtocolTests {
    func response(_ query: ViperV4Query, payload: [UInt8], status: UInt8 = 2) -> [UInt8] {
        var bytes = ViperV4ReadProtocol.request(query)
        bytes[0] = status
        bytes[5] = UInt8(payload.count)
        bytes.replaceSubrange(8..<(8 + payload.count), with: payload)
        bytes[88] = ViperV4ReadProtocol.checksum(bytes)
        return bytes
    }

    func dpiPayload() -> [UInt8] {
        // Synthetic response: two distinct X/Y stages, second stage active. Not a hardware capture.
        [0, 2, 2, 1, 0x03, 0x20, 0x03, 0x20, 0, 0, 2, 0x06, 0x40, 0x04, 0xB0, 0, 0]
    }

    @Test func requestsAreExactReadCommandsOnly() {
        let battery = ViperV4ReadProtocol.request(.battery)
        #expect(battery.count == 90)
        #expect(Array(battery[0..<8]) == [0, 0x1F, 0, 0, 0, 2, 7, 0x80])
        #expect(battery[88] == 0x85)
        #expect(battery[8..<88].allSatisfy { $0 == 0 })
        let dpi = ViperV4ReadProtocol.request(.dpiStages)
        #expect(Array(dpi[0..<8]) == [0, 0x1F, 0, 0, 0, 80, 4, 0x86])
        #expect(dpi[88] == 0xD2)
        let polling = ViperV4ReadProtocol.request(.pollingRate)
        #expect(Array(polling[0..<10]) == [0, 0x1F, 0, 0, 0, 2, 0, 0xC0, 1, 0])
        #expect(polling[10..<88].allSatisfy { $0 == 0 })
        #expect(polling[88] == 0xC3)
        let charging = ViperV4ReadProtocol.request(.charging)
        #expect(Array(charging.prefix(10)) == [0, 0x1F, 0, 0, 0, 2, 7, 0x84, 0, 0])
        #expect(charging[10..<88].allSatisfy { $0 == 0 })
        #expect(charging[88] == 0x81)
        #expect(ViperV4Query.allCases.count == 4)
    }

    @Test func chargingFlagNeverGuessesUnknownValuesOrDischarging() throws {
        #expect(try ViperV4ReadProtocol.chargingState([0, 0]) == .notCharging)
        #expect(try ViperV4ReadProtocol.chargingState([0, 1]) == .charging)
        for payload: [UInt8] in [[], [0], [0, 1, 0], [1, 1], [0, 2], [0, 255]] {
            #expect(throws: MouseQueryError.self) { try ViperV4ReadProtocol.chargingState(payload) }
        }
    }

    @Test func pollingRequiresExactPayloadAndOnlyKnownCodes() throws {
        for (code, rate) in [(UInt8(0x40), 125), (0x10, 500), (0x08, 1000), (0x04, 2000), (0x02, 4000), (0x01, 8000)] {
            #expect(try ViperV4ReadProtocol.pollingRate([1, code]) == rate)
            #expect(try ViperV4ReadProtocol.reply(response(.pollingRate, payload: [1, code]), for: .pollingRate) == .payload([1, code]))
        }
        let invalid: [[UInt8]] = [[], [1], [0, 8], [1, 8, 0], [1, 0], [1, 3], [1, 255]]
        for payload in invalid {
            #expect(throws: MouseQueryError.self) { try ViperV4ReadProtocol.pollingRate(payload) }
        }
    }

    @Test func batteryAndDistinctDPIAxesDecode() throws {
        #expect(try ViperV4ReadProtocol.batteryPercent([0, 0]) == 0)
        #expect(try ViperV4ReadProtocol.batteryPercent([0, 128]) == 50)
        #expect(try ViperV4ReadProtocol.batteryPercent([0, 255]) == 100)
        let state = try ViperV4ReadProtocol.dpiState(dpiPayload())
        #expect(state.activeStage == 2)
        #expect(state.current.x == 1600)
        #expect(state.current.y == 1200)
        #expect(state.stages[0].x == 800)
        #expect(try ViperV4ReadProtocol.reply(response(.battery, payload: [0, 128]), for: .battery) == .payload([0, 128]))
    }

    @Test func malformedFramesNeverBecomeValues() {
        #expect(throws: MouseQueryError.self) { try ViperV4ReadProtocol.reply([0], for: .battery) }
        var frame = response(.battery, payload: [0, 200])
        frame[9] ^= 1
        #expect(throws: MouseQueryError.self) { try ViperV4ReadProtocol.reply(frame, for: .battery) }
        frame = response(.battery, payload: [0, 200])
        frame[5] = 81
        frame[88] = ViperV4ReadProtocol.checksum(frame)
        #expect(throws: MouseQueryError.self) { try ViperV4ReadProtocol.reply(frame, for: .battery) }
        #expect(throws: MouseQueryError.self) { try ViperV4ReadProtocol.dpiState([0, 0, 0]) }
        #expect(throws: MouseQueryError.self) { try ViperV4ReadProtocol.dpiState([0, 2, 1]) }
        #expect(throws: MouseQueryError.self) { try ViperV4ReadProtocol.batteryPercent([]) }
    }

    @Test func decodedDiagnosticsCannotCreateInvalidCurrentStage() throws {
        let state = try ViperV4ReadProtocol.dpiState(dpiPayload())
        #expect(try JSONDecoder().decode(MouseDPIState.self, from: JSONEncoder().encode(state)) == state)
        for invalid in ["{\"activeStage\":0,\"stages\":[]}",
                        "{\"activeStage\":-9223372036854775808,\"stages\":[{\"x\":800,\"y\":800}]}" ] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(MouseDPIState.self, from: Data(invalid.utf8)) }
        }
    }

    @Test func busyFailureAndConcurrentResponsesAreDistinct() throws {
        #expect(try ViperV4ReadProtocol.reply(response(.battery, payload: [], status: 1), for: .battery) == .busy)
        #expect(throws: MouseQueryError.rejected(5)) {
            try ViperV4ReadProtocol.reply(response(.battery, payload: [], status: 5), for: .battery)
        }
        #expect(throws: MouseQueryError.mismatchedResponse(transaction: 0x1F, commandClass: 4, commandID: 0x86)) {
            try ViperV4ReadProtocol.reply(response(.dpiStages, payload: dpiPayload()), for: .battery)
        }
        var frame = response(.battery, payload: [0, 200])
        frame[1] = 0xFF
        #expect(throws: MouseQueryError.mismatchedResponse(transaction: 0xFF, commandClass: 7, commandID: 0x80)) { try ViperV4ReadProtocol.reply(frame, for: .battery) }
    }
}
