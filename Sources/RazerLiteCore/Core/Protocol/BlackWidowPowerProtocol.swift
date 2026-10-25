import Foundation

public enum KeyboardPowerField: String, Codable, CaseIterable, Sendable {
    case battery, charging
    public var title: String { self == .battery ? "电池电量" : "充电状态" }
    var commandID: UInt8 { self == .battery ? 0x80 : 0x84 }
}

/// Command facts: OpenRazer PR #2912 head 54f9f686… / razerchromacommon.c and razerkbd_driver.c.
/// Does not contain the driver's probe-time device-mode change or any configuration command.
enum BlackWidowPowerProtocol {
    static func request(_ field: KeyboardPowerField) -> [UInt8] {
        RazerReportCodec.request(transaction: 0x9F, commandClass: 7, commandID: field.commandID, payload: [0, 0])
    }

    static func reply(_ frame: [UInt8], field: KeyboardPowerField) throws -> RazerReportCodec.Reply {
        try RazerReportCodec.reply(frame, transaction: 0x9F, commandClass: 7, commandID: field.commandID)
    }

    static func validate(_ payload: [UInt8]) throws {
        guard payload.count == 2, payload[0] == 0 else {
            throw MouseQueryError.malformed("键盘电源状态必须为 2 字节，且首字节为 00")
        }
    }

    static func batteryPercent(_ payload: [UInt8]) throws -> Int {
        try validate(payload)
        return Int((Double(payload[1]) * 100 / 255).rounded())
    }

    static func chargingState(_ payload: [UInt8]) throws -> DeviceChargingState {
        try validate(payload)
        switch payload[1] {
        case 0: return .notCharging
        case 1: return .charging
        default: throw MouseQueryError.malformed("未知的键盘充电状态编码")
        }
    }
}
