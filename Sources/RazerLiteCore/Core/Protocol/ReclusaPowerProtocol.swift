import Foundation

/// Battery-ID queries reviewed in the official product 756/757 rzDevice25 middleware.
/// This receiver route uses the DualLink keyboard transaction bank, not the 02D2 protocol.
enum ReclusaPowerProtocol {
    static let batteryID: UInt8 = 0

    static func request(_ field: KeyboardPowerField, transaction: UInt8 = 0x80) throws -> [UInt8] {
        try validateTransaction(transaction)
        return RazerReportCodec.request(transaction: transaction, commandClass: 0x07,
                                        commandID: field.commandID, payload: [batteryID, 0])
    }

    static func reply(_ frame: [UInt8], field: KeyboardPowerField,
                      transaction: UInt8 = 0x80) throws -> RazerReportCodec.Reply {
        try validateTransaction(transaction)
        return try RazerReportCodec.reply(frame, transaction: transaction, commandClass: 0x07,
                                          commandID: field.commandID)
    }

    static func batteryPercent(_ payload: [UInt8]) throws -> Int {
        try validatePayload(payload)
        return Int(payload[1]) * 100 / 255
    }

    static func chargingState(_ payload: [UInt8]) throws -> DeviceChargingState {
        try validatePayload(payload)
        switch payload[1] {
        case 0: return .notCharging
        case 1: return .charging
        default: return .unknown(payload[1])
        }
    }

    private static func validatePayload(_ payload: [UInt8]) throws {
        guard payload.count == 2, payload[0] == batteryID else {
            throw DeviceQueryError.malformed("键盘电源响应必须为 2 字节，并回显电池 ID 0")
        }
    }

    private static func validateTransaction(_ transaction: UInt8) throws {
        guard (0x80...0x9E).contains(transaction) else {
            throw DeviceQueryError.malformed("Reclusa 电源查询需要键盘事务号 80–9E")
        }
    }
}
