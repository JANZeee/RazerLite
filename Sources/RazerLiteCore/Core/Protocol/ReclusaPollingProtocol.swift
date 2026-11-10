import Foundation

/// Product 756 / dongle 757 official USB high-speed polling format. Profile 1 only.
/// Higher rates decode correctly, but writes remain limited until DualLink eligibility is known.
enum ReclusaPollingProtocol {
    static let profileID: UInt8 = 1
    static let writableRates = [125, 250, 500, 1000]

    static func getRequest(transaction: UInt8 = 0x80) -> [UInt8] {
        RazerReportCodec.request(transaction: transaction, commandClass: 0,
                                 commandID: 0xC0, payload: [profileID, 0])
    }

    static func setRequest(hertz: Int, transaction: UInt8 = 0x81) throws -> [UInt8] {
        RazerReportCodec.request(transaction: transaction, commandClass: 0,
                                 commandID: 0x40, payload: [profileID, try writableCode(for: hertz)])
    }

    static func writableCode(for hertz: Int) throws -> UInt8 {
        switch hertz {
        case 125: 0x40
        case 250: 0x20
        case 500: 0x10
        case 1000: 0x08
        default: throw DeviceQueryError.malformed("此键盘当前开放 125、250、500、1000 Hz；更高档位尚需验证接收器共享连接状态")
        }
    }

    static func hertz(_ payload: [UInt8]) throws -> Int {
        guard payload.count == 2, payload[0] == profileID else {
            throw DeviceQueryError.malformed("键盘回报率响应必须为 2 字节，并回显 profile 1")
        }
        switch payload[1] {
        case 0x40: return 125
        case 0x20: return 250
        case 0x10: return 500
        case 0x08: return 1000
        case 0x04: return 2000
        case 0x02: return 4000
        case 0x01: return 8000
        default: throw DeviceQueryError.malformed("键盘返回未知回报率编码，未推测配置值")
        }
    }

    static func validateAcknowledgement(_ payload: [UInt8], hertz: Int) throws {
        guard payload == [profileID, try writableCode(for: hertz)] else {
            throw DeviceQueryError.malformed("键盘回报率设置响应未完整回显 profile 1 与目标值")
        }
    }
}
