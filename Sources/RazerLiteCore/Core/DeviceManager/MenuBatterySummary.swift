import Foundation

/// Presentation only: building a menu never starts a read. Each displayed value
/// keeps its own source and acquisition time; macOS caches are labelled as such.
public struct MenuBatterySummary: Equatable, Sendable {
    public let percent: Int
    public let source: String
    public let acquiredAt: Date

    public static func choose(mouse: MouseTelemetry?, system: SystemBatteryReading?,
                              keyboard: KeyboardPowerReading?) -> MenuBatterySummary? {
        if let mouse, let percent = mouse.batteryPercent, (0...100).contains(percent) {
            return Self(percent: percent, source: "设备响应", acquiredAt: mouse.readAt)
        }
        if let system, let percent = system.percent, (0...100).contains(percent), let source = system.source {
            return Self(percent: percent, source: "\(source.title) · 系统缓存", acquiredAt: system.acquiredAt)
        }
        if let keyboard, keyboard.hasValue, let percent = keyboard.batteryPercent {
            return Self(percent: percent, source: "设备响应", acquiredAt: keyboard.readAt)
        }
        return nil
    }
}
