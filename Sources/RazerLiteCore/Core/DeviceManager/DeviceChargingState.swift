import Foundation

/// A charging flag does not establish whether a full battery is discharging.
public enum DeviceChargingState: Equatable, Sendable {
    case charging, notCharging
    case unknown(UInt8)

    public var title: String {
        switch self {
        case .charging: return "充电中"
        case .notCharging: return "未充电"
        case let .unknown(raw): return "未知充电状态（\(raw)）"
        }
    }
}

/// Preserve the historical string encoding for known states and retain an unknown wire value.
extension DeviceChargingState: RawRepresentable, Codable {
    public init?(rawValue: String) {
        switch rawValue {
        case "charging": self = .charging
        case "notCharging": self = .notCharging
        default:
            guard rawValue.hasPrefix("unknown:"), let raw = UInt8(rawValue.dropFirst(8)) else { return nil }
            self = .unknown(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .charging: return "charging"
        case .notCharging: return "notCharging"
        case let .unknown(raw): return "unknown:\(raw)"
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid charging state")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Compatibility name for the mouse read API introduced in 0.7.
public typealias MouseChargingState = DeviceChargingState
