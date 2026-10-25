import Foundation

/// A charging flag does not establish whether a full battery is discharging.
public enum DeviceChargingState: String, Codable, Equatable, Sendable {
    case charging, notCharging
    public var title: String { self == .charging ? "充电中" : "未充电" }
}

/// Compatibility name for the mouse read API introduced in 0.7.
public typealias MouseChargingState = DeviceChargingState
