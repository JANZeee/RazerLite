import Foundation

public enum BatteryRefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case fiveMinutes = 300, tenMinutes = 600, fifteenMinutes = 900
    public var id: Int { rawValue }
    public var title: String { "每 \(rawValue / 60) 分钟" }
}

public struct BatteryRefreshTarget: Equatable, Sendable {
    public let deviceID: String
    public let sessionID: UUID
    public let backend: DeviceReadBackend
    public init(deviceID: String, sessionID: UUID, backend: DeviceReadBackend) {
        self.deviceID = deviceID; self.sessionID = sessionID; self.backend = backend
    }
}

/// A backend being readable is not evidence that repeated reads are safe or cheap.
public enum BatteryRefreshEligibility {
    public static func allows(_ backend: DeviceReadBackend, simulation: Bool) -> Bool {
        // Hardware and resource-cost acceptance is still pending for all three backends.
        simulation
    }
}

/// Pure scheduling decisions on monotonic seconds; no timers, device I/O or wall-clock dates.
struct BatteryRefreshPolicy {
    private struct Entry {
        let target: BatteryRefreshTarget
        var due: TimeInterval
        var failures = 0
        var blocked = false
    }
    private var entries: [String: Entry] = [:]
    private var interval: TimeInterval = 300
    private var running = false
    private var lastSystemStart: TimeInterval?
    private(set) var inFlight: BatteryRefreshTarget?
    static let systemBudget: TimeInterval = 900

    mutating func configure(targets: [BatteryRefreshTarget], enabled: Bool, paused: Bool,
                            interval: BatteryRefreshInterval, now: TimeInterval) {
        let active = enabled && !paused
        let reset = active != running || self.interval != Double(interval.rawValue)
        running = active
        self.interval = Double(interval.rawValue)
        let old = entries
        entries = Dictionary(uniqueKeysWithValues: targets.map { target in
            if !reset, let entry = old[target.deviceID], entry.target == target { return (target.deviceID, entry) }
            return (target.deviceID, Entry(target: target, due: now + cadence(target)))
        })
    }

    func nextDeadline(busy: Set<String>) -> TimeInterval? {
        guard running, inFlight == nil else { return nil }
        return entries.values.filter { !$0.blocked && !busy.contains($0.target.deviceID) }.map { due($0) }.min()
    }

    mutating func beginDue(now: TimeInterval, busy: Set<String>) -> BatteryRefreshTarget? {
        guard running, inFlight == nil,
              let entry = entries.values.filter({ !$0.blocked && !busy.contains($0.target.deviceID) && due($0) <= now })
                .sorted(by: { (due($0), $0.target.deviceID) < (due($1), $1.target.deviceID) }).first else { return nil }
        inFlight = entry.target
        if entry.target.backend == .macOSBluetoothBattery { lastSystemStart = now }
        return entry.target
    }

    mutating func finish(_ target: BatteryRefreshTarget, failure: ReadFailureKind?, now: TimeInterval) {
        guard inFlight == target else { return }
        inFlight = nil
        record(target, failure: failure, now: now)
    }

    /// An explicit read postpones the next automatic read, including recovery from a blocked backend.
    mutating func observed(_ target: BatteryRefreshTarget, failure: ReadFailureKind?, now: TimeInterval) {
        if target.backend == .macOSBluetoothBattery { lastSystemStart = now }
        record(target, failure: failure, now: now)
    }

    private mutating func record(_ target: BatteryRefreshTarget, failure: ReadFailureKind?, now: TimeInterval) {
        guard var entry = entries[target.deviceID], entry.target == target else { return }
        if failure == .cancelled {
            entry.due = now + cadence(target); entries[target.deviceID] = entry; return
        }
        if let failure {
            entry.failures = min(entry.failures + 1, 5)
            entry.blocked = [.permissionDenied, .unsupported, .protocolMismatch, .invalidData, .unavailable].contains(failure)
        } else { entry.failures = 0; entry.blocked = false }
        let delay = min(cadence(target) * pow(2, Double(entry.failures)), 3600)
        entry.due = now + delay
        entries[target.deviceID] = entry
    }

    private func cadence(_ target: BatteryRefreshTarget) -> TimeInterval {
        target.backend == .macOSBluetoothBattery ? max(interval, Self.systemBudget) : interval
    }
    private func due(_ entry: Entry) -> TimeInterval {
        guard entry.target.backend == .macOSBluetoothBattery, let lastSystemStart else { return entry.due }
        return max(entry.due, lastSystemStart + Self.systemBudget)
    }
}
