import Foundation

/// Protocol facts reviewed from the exact-model public implementation, not a generic Razer command API.
/// Reference: OpenMouse-Project/mouse-protocol @ 54c68c69bbd0bcd750cf10a4e439148e634c02db.
enum ViperV4Query: String, CaseIterable, Sendable {
    case battery
    case dpiStages
    case pollingRate
    case charging

    var commandClass: UInt8 {
        switch self { case .battery, .charging: 0x07; case .dpiStages: 0x04; case .pollingRate: 0x00 }
    }
    var commandID: UInt8 {
        switch self { case .battery: 0x80; case .dpiStages: 0x86; case .pollingRate: 0xC0; case .charging: 0x84 }
    }
    var payloadSize: UInt8 { self == .dpiStages ? 80 : 2 }
}

public struct MouseDPIStage: Codable, Equatable, Sendable {
    public let x: Int
    public let y: Int
}

public struct MouseDPIState: Codable, Equatable, Sendable {
    /// Human-facing, one-based stage index; validated against stages before construction.
    public let activeStage: Int
    public let stages: [MouseDPIStage]
    public var current: MouseDPIStage { stages[activeStage - 1] }

    init(activeStage: Int, stages: [MouseDPIStage]) {
        self.activeStage = activeStage
        self.stages = stages
    }

    private enum CodingKeys: String, CodingKey { case activeStage, stages }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let active = try container.decode(Int.self, forKey: .activeStage)
        let stages = try container.decode([MouseDPIStage].self, forKey: .stages)
        guard (1...5).contains(stages.count), (1...stages.count).contains(active),
              stages.allSatisfy({ (1...50000).contains($0.x) && (1...50000).contains($0.y) }) else {
            throw DecodingError.dataCorruptedError(forKey: .activeStage, in: container, debugDescription: "Invalid DPI stages")
        }
        self.init(activeStage: active, stages: stages)
    }
}

enum ViperV4ReadProtocol {
    static let reportLength = 90
    static let reportID = 0
    static let transaction: UInt8 = 0x1F

    typealias Reply = RazerReportCodec.Reply

    static func request(_ query: ViperV4Query) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: Int(query.payloadSize))
        // Viper V4 polling query has a model-specific selector, confirmed in the original control-only pcap.
        if query == .pollingRate { payload[0] = 0x01 }
        return RazerReportCodec.request(transaction: transaction, commandClass: query.commandClass,
                                        commandID: query.commandID, payload: payload)
    }

    static func checksum(_ frame: [UInt8]) -> UInt8 {
        RazerReportCodec.checksum(frame)
    }

    static func reply(_ frame: [UInt8], for query: ViperV4Query) throws -> Reply {
        try reply(frame, commandClass: query.commandClass, commandID: query.commandID)
    }

    static func reply(_ frame: [UInt8], commandClass: UInt8, commandID: UInt8) throws -> Reply {
        try RazerReportCodec.reply(frame, transaction: transaction, commandClass: commandClass, commandID: commandID)
    }

    static func batteryPercent(_ payload: [UInt8]) throws -> Int {
        guard payload.count >= 2 else { throw MouseQueryError.malformed("电量负载不足 2 字节") }
        return Int((Double(payload[1]) * 100 / 255).rounded())
    }

    static func chargingState(_ payload: [UInt8]) throws -> MouseChargingState {
        guard payload.count == 2, payload[0] == 0 else {
            throw MouseQueryError.malformed("充电状态负载必须是 2 字节，且首字节为 00")
        }
        switch payload[1] {
        case 0: return .notCharging
        case 1: return .charging
        default: throw MouseQueryError.malformed("未知的 Viper V4 充电状态编码 \(hexID(Int(payload[1]), width: 2))")
        }
    }

    static func pollingRate(_ payload: [UInt8]) throws -> Int {
        guard payload.count == 2, payload[0] == 0x01 else {
            throw MouseQueryError.malformed("回报率负载必须是 2 字节，且首字节为 01")
        }
        switch payload[1] {
        case 0x40: return 125
        case 0x10: return 500
        case 0x08: return 1000
        case 0x04: return 2000
        case 0x02: return 4000
        case 0x01: return 8000
        default: throw MouseQueryError.malformed("未知的 Viper V4 回报率编码 \(hexID(Int(payload[1]), width: 2))")
        }
    }

    static func dpiState(_ payload: [UInt8]) throws -> MouseDPIState {
        guard payload.count >= 3 else { throw MouseQueryError.malformed("DPI 头部不足 3 字节") }
        let count = Int(payload[2])
        let active = Int(payload[1])
        guard (1...5).contains(count), (1...count).contains(active), payload.count >= 3 + count * 7 else {
            throw MouseQueryError.malformed("DPI 档位数、当前档位或负载长度不合法")
        }
        var stages: [MouseDPIStage] = []
        for index in 0..<count {
            let offset = 3 + index * 7
            let x = Int(payload[offset + 1]) * 256 + Int(payload[offset + 2])
            let y = Int(payload[offset + 3]) * 256 + Int(payload[offset + 4])
            guard (1...50000).contains(x), (1...50000).contains(y) else {
                throw MouseQueryError.malformed("DPI 数值超出此型号公开实现的范围")
            }
            stages.append(MouseDPIStage(x: x, y: y))
        }
        return MouseDPIState(activeStage: active, stages: stages)
    }
}
