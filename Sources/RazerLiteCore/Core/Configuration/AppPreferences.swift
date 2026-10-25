import Combine
import Foundation

public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }
    public var title: String {
        switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" }
    }
}

public enum WindowCloseBehavior: String, CaseIterable, Identifiable, Sendable {
    case menuBar, quit
    public var id: String { rawValue }
    public var title: String { self == .menuBar ? "保留菜单栏" : "退出 RazerLite" }
}

public enum WorkspaceSection: String, Sendable { case devices, profiles, catalog }

/// Only ordinary UI preferences belong here. Device identities, readouts,
/// selected profiles and one-shot write permits remain session-local.
@MainActor
public final class AppPreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published public var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "ui.appearance") }
    }
    @Published public var closeBehavior: WindowCloseBehavior {
        didSet { defaults.set(closeBehavior.rawValue, forKey: "ui.closeBehavior") }
    }
    @Published public var section: WorkspaceSection {
        didSet { defaults.set(section.rawValue, forKey: "ui.section") }
    }
    @Published public var automaticBatteryRefresh: Bool {
        didSet { defaults.set(automaticBatteryRefresh, forKey: "battery.automaticRefresh") }
    }
    @Published public var batteryRefreshInterval: BatteryRefreshInterval {
        didSet { defaults.set(batteryRefreshInterval.rawValue, forKey: "battery.interval") }
    }
    @Published public var lowBatteryAlerts: Bool {
        didSet { defaults.set(lowBatteryAlerts, forKey: "battery.alerts") }
    }
    @Published public var lowBatteryThreshold: Int {
        didSet {
            if ![10, 15, 20].contains(lowBatteryThreshold) { lowBatteryThreshold = 20 }
            defaults.set(lowBatteryThreshold, forKey: "battery.threshold")
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: "ui.appearance").flatMap(AppAppearance.init(rawValue:)) ?? .system
        closeBehavior = defaults.string(forKey: "ui.closeBehavior").flatMap(WindowCloseBehavior.init(rawValue:)) ?? .menuBar
        section = defaults.string(forKey: "ui.section").flatMap(WorkspaceSection.init(rawValue:)) ?? .devices
        automaticBatteryRefresh = (defaults.object(forKey: "battery.automaticRefresh") as? Bool) ?? false
        batteryRefreshInterval = BatteryRefreshInterval(rawValue: defaults.integer(forKey: "battery.interval")) ?? .fiveMinutes
        lowBatteryAlerts = (defaults.object(forKey: "battery.alerts") as? Bool) ?? false
        let threshold = defaults.integer(forKey: "battery.threshold")
        lowBatteryThreshold = [10, 15, 20].contains(threshold) ? threshold : 20
    }
}
