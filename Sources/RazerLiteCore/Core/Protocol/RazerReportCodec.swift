import Foundation

/// Framing only. Exact-model adapters own command selection and interface eligibility.
enum RazerReportCodec {
    static let length = 90
    enum Reply: Equatable { case busy; case payload([UInt8]) }

    static func request(transaction: UInt8, commandClass: UInt8, commandID: UInt8, payload: [UInt8]) -> [UInt8] {
        precondition(payload.count <= 80)
        var frame = [UInt8](repeating: 0, count: length)
        frame[1] = transaction
        frame[5] = UInt8(payload.count)
        frame[6] = commandClass
        frame[7] = commandID
        frame.replaceSubrange(8..<(8 + payload.count), with: payload)
        frame[88] = checksum(frame)
        return frame
    }

    static func checksum(_ frame: [UInt8]) -> UInt8 {
        precondition(frame.count == length)
        return frame[2..<88].reduce(0, ^)
    }

    static func reply(_ frame: [UInt8], transaction: UInt8, commandClass: UInt8, commandID: UInt8) throws -> Reply {
        guard frame.count == length else { throw MouseQueryError.malformed("长度应为 90 字节，实际 \(frame.count)") }
        guard checksum(frame) == frame[88] else { throw MouseQueryError.malformed("校验码不匹配") }
        guard frame[2] == 0, frame[3] == 0, frame[4] == 0, frame[89] == 0, frame[5] <= 80 else {
            throw MouseQueryError.malformed("头部、分包或保留字段不符合当前协议")
        }
        guard frame[1] == transaction, frame[6] == commandClass, frame[7] == commandID else {
            throw MouseQueryError.mismatchedResponse(transaction: frame[1], commandClass: frame[6], commandID: frame[7])
        }
        switch frame[0] {
        case 1: return .busy
        case 2: return .payload(Array(frame[8..<(8 + Int(frame[5]))]))
        default: throw MouseQueryError.rejected(frame[0])
        }
    }
}
