import Foundation

/// One submission per operation. Busy replies only cause additional bounded receives.
struct ReclusaPollingClient {
    let transport: any HIDFeatureTransport
    let wait: @Sendable () -> Void

    func pollingRate(transaction: UInt8 = 0x80) throws -> Int {
        let payload = try query(ReclusaPollingProtocol.getRequest(transaction: transaction))
        return try ReclusaPollingProtocol.hertz(payload)
    }

    func setPollingRate(_ hertz: Int, transaction: UInt8 = 0x81) throws {
        let payload = try query(ReclusaPollingProtocol.setRequest(hertz: hertz, transaction: transaction))
        try ReclusaPollingProtocol.validateAcknowledgement(payload, hertz: hertz)
    }

    private func query(_ request: [UInt8]) throws -> [UInt8] {
        try transport.send(request, reportID: 0)
        wait()
        for attempt in 0..<16 {
            switch try RazerReportCodec.reply(transport.receive(reportID: 0, length: RazerReportCodec.length),
                                              transaction: request[1], commandClass: 0, commandID: request[7]) {
            case let .payload(payload): return payload
            case .busy: if attempt < 15 { wait() }
            }
        }
        throw DeviceQueryError.busyTimeout
    }
}
