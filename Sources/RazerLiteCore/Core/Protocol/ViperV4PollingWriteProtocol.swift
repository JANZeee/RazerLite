import Foundation

/// Exact Viper V4 command, independently checked against the public USB control captures.
enum ViperV4PollingWriteProtocol {
    static let rates = [125, 500, 1000, 2000, 4000, 8000]

    static func code(for hertz: Int) throws -> UInt8 {
        switch hertz {
        case 125: 0x40
        case 500: 0x10
        case 1000: 0x08
        case 2000: 0x04
        case 4000: 0x02
        case 8000: 0x01
        default: throw MouseQueryError.malformed("此适配仅接受 125、500、1000、2000、4000、8000 Hz")
        }
    }

    static func request(hertz: Int) throws -> [UInt8] {
        RazerReportCodec.request(transaction: ViperV4ReadProtocol.transaction, commandClass: 0,
            commandID: 0x40, payload: [1, try code(for: hertz)])
    }

    static func validateAcknowledgement(_ payload: [UInt8], hertz: Int) throws {
        guard payload == [1, try code(for: hertz)] else {
            throw MouseQueryError.malformed("回报率设置响应未完整回显目标值")
        }
    }
}
