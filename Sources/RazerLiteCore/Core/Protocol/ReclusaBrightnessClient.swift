import Foundation

/// One serial, shared-open HID session. Busy responses are received again, never resent.
struct ReclusaBrightnessClient {
    let transport: any HIDFeatureTransport
    let wait: @Sendable () -> Void

    func region(transaction: UInt8 = 0x80) throws -> UInt8 {
        let payload = try query(ReclusaBrightnessProtocol.regionsRequest(transaction: transaction)) {
            try ReclusaBrightnessProtocol.regionsReply($0, transaction: transaction)
        }
        return try ReclusaBrightnessProtocol.singleRegion(payload)
    }

    func brightness(regionID: UInt8, transaction: UInt8 = 0x81) throws -> UInt8 {
        let payload = try query(ReclusaBrightnessProtocol.brightnessRequest(regionID: regionID, transaction: transaction)) {
            try ReclusaBrightnessProtocol.brightnessReply($0, transaction: transaction)
        }
        return try ReclusaBrightnessProtocol.rawBrightness(payload, regionID: regionID)
    }

    func setBrightness(raw: UInt8, transaction: UInt8 = 0x82) throws {
        let payload = try query(ReclusaBrightnessProtocol.setRequest(raw: raw, transaction: transaction)) {
            try ReclusaBrightnessProtocol.setReply($0, transaction: transaction)
        }
        try ReclusaBrightnessProtocol.validateSetAcknowledgement(payload, raw: raw)
    }

    func read(deviceID: String, interfaceID: UInt64, regionTransaction: UInt8 = 0x80,
              brightnessTransaction: UInt8 = 0x81) throws -> KeyboardBrightnessReading {
        let regionID = try region(transaction: regionTransaction)
        let raw = try brightness(regionID: regionID, transaction: brightnessTransaction)
        return .init(deviceID: deviceID, interfaceID: interfaceID, profileID: ReclusaBrightnessProtocol.profileID,
                     regionID: regionID, rawBrightness: raw, percent: ReclusaBrightnessProtocol.percent(raw),
                     issue: nil, readAt: Date())
    }

    private func query(_ request: [UInt8], decode: ([UInt8]) throws -> RazerReportCodec.Reply) throws -> [UInt8] {
        try transport.send(request, reportID: 0)
        wait()
        for attempt in 0..<16 {
            switch try decode(transport.receive(reportID: 0, length: RazerReportCodec.length)) {
            case let .payload(payload): return payload
            case .busy:
                if attempt < 15 { wait() }
            }
        }
        throw DeviceQueryError.busyTimeout
    }
}
