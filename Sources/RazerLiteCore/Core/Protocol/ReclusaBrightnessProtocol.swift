import Foundation

/// Independently encoded brightness facts reviewed from Razer's rzDevice25 and
/// DualLinkKeyboard bundles for product 756 / dongle 757. No mode change or pairing commands.
enum ReclusaBrightnessProtocol {
    static let profileID: UInt8 = 1
    static let regionsTransaction: UInt8 = 0x80
    static let brightnessTransaction: UInt8 = 0x81

    static func regionsRequest(transaction: UInt8 = regionsTransaction) -> [UInt8] {
        RazerReportCodec.request(transaction: transaction, commandClass: 0x0F,
                                 commandID: 0x80, payload: Array(repeating: 0, count: 80))
    }

    static func brightnessRequest(regionID: UInt8, transaction: UInt8 = brightnessTransaction) throws -> [UInt8] {
        guard regionID != 0 else { throw DeviceQueryError.malformed("不能查询未确定的灯区") }
        return RazerReportCodec.request(transaction: transaction, commandClass: 0x0F,
                                       commandID: 0x84, payload: [profileID, regionID, 0])
    }

    static func regionsReply(_ frame: [UInt8], transaction: UInt8 = regionsTransaction) throws -> RazerReportCodec.Reply {
        try RazerReportCodec.reply(frame, transaction: transaction, commandClass: 0x0F, commandID: 0x80)
    }

    static func brightnessReply(_ frame: [UInt8], transaction: UInt8 = brightnessTransaction) throws -> RazerReportCodec.Reply {
        try RazerReportCodec.reply(frame, transaction: transaction, commandClass: 0x0F, commandID: 0x84)
    }

    /// Official lighting runner sets profile 1, all-region selector 0.
    /// This command is only used after a unique concrete region has been read and confirmed.
    static func setRequest(raw: UInt8, transaction: UInt8 = 0x82) -> [UInt8] {
        RazerReportCodec.request(transaction: transaction, commandClass: 0x0F,
                                 commandID: 0x04, payload: [profileID, 0, raw])
    }

    static func setReply(_ frame: [UInt8], transaction: UInt8 = 0x82) throws -> RazerReportCodec.Reply {
        try RazerReportCodec.reply(frame, transaction: transaction, commandClass: 0x0F, commandID: 0x04)
    }

    static func validateSetAcknowledgement(_ payload: [UInt8], raw: UInt8) throws {
        guard payload == [profileID, 0, raw] else {
            throw DeviceQueryError.malformed("亮度设置响应未回显 profile 1、全部灯区与目标值")
        }
    }

    static func raw(forPercent percent: Int) throws -> UInt8 {
        guard (0...100).contains(percent) else { throw DeviceQueryError.malformed("亮度必须在 0–100% 之间") }
        return UInt8(percent * 255 / 100)
    }

    /// Official records have five bytes: ID, update rate, data type, width, height.
    /// This minimal reader accepts one concrete region only; never guesses a default.
    static func singleRegion(_ payload: [UInt8]) throws -> UInt8 {
        guard payload.count == 5, payload[0] != 0 else {
            throw DeviceQueryError.malformed("亮度试读要求唯一非零灯区；灯区列表为空、格式不完整或包含多个灯区")
        }
        return payload[0]
    }

    static func rawBrightness(_ payload: [UInt8], regionID: UInt8) throws -> UInt8 {
        guard regionID != 0, payload.count == 3, payload[0] == profileID, payload[1] == regionID else {
            throw DeviceQueryError.malformed("亮度响应必须为 3 字节，并回显 profile 1 与已查询灯区")
        }
        return payload[2]
    }

    /// Matches the official UI conversion, including rounding upward for nonzero raw values.
    static func percent(_ raw: UInt8) -> Int { (Int(raw) * 100 + 254) / 255 }
}
