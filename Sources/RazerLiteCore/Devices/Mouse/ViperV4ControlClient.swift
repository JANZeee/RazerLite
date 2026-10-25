import Foundation

final class ViperV4ControlClient {
    private let transport: any HIDFeatureTransport
    private let attempts: Int
    private let busyDelay: TimeInterval

    init(transport: any HIDFeatureTransport, attempts: Int = 16, busyDelay: TimeInterval = 0.035) {
        self.transport = transport
        self.attempts = attempts
        self.busyDelay = busyDelay
    }

    func query(_ query: ViperV4Query) throws -> [UInt8] {
        try transport.send(ViperV4ReadProtocol.request(query), reportID: ViperV4ReadProtocol.reportID)
        return try receiveReply(commandClass: query.commandClass, commandID: query.commandID)
    }

    func setDPI(_ state: MouseDPIState) throws {
        try transport.send(ViperV4DPIProtocol.request(state), reportID: ViperV4ReadProtocol.reportID)
        _ = try receiveReply(commandClass: 0x04, commandID: 0x06)
    }

    private func receiveReply(commandClass: UInt8, commandID: UInt8) throws -> [UInt8] {
        // Native SetReport completion need not mean the receiver has prepared its response.
        // Give it one settling interval before GetReport; retain all matching checks afterwards.
        if busyDelay > 0 { Thread.sleep(forTimeInterval: busyDelay) }
        for attempt in 0..<attempts {
            let bytes = try transport.receive(reportID: ViperV4ReadProtocol.reportID, length: ViperV4ReadProtocol.reportLength)
            switch try ViperV4ReadProtocol.reply(bytes, commandClass: commandClass, commandID: commandID) {
            case let .payload(payload): return payload
            case .busy:
                if attempt + 1 < attempts { Thread.sleep(forTimeInterval: busyDelay) }
            }
        }
        throw MouseQueryError.busyTimeout
    }
}
