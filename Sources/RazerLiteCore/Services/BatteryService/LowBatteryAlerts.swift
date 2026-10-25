import Combine
import Foundation

public enum BatteryNotificationAuthorization: Sendable {
    case notChecked, notDetermined, authorized, denied, unavailable
    public var title: String {
        switch self {
        case .notChecked: "尚未检查"
        case .notDetermined: "尚未授权"
        case .authorized: "已允许"
        case .denied: "未允许"
        case .unavailable: "状态不可用"
        }
    }
}

public struct LowBatteryNotice: Sendable {
    public let id: UUID
    public let target: BatteryRefreshTarget
    public let deviceName: String
    public let percent: Int
    public let acquiredAt: Date
    public let simulation: Bool
}

@MainActor public protocol BatteryNotificationServicing {
    func authorization() async -> BatteryNotificationAuthorization
    func requestAuthorization() async throws
    func post(_ notice: LowBatteryNotice) async throws
    func removePending()
}

/// Episodes are scoped to a connection; no persistent device identifiers or battery history.
struct LowBatteryAlertPolicy {
    private struct Episode {
        let session: UUID
        var lastSample: Date = .distantPast
        var delivered = false
        var pending: UUID?
    }
    private var episodes: [String: Episode] = [:]
    static let maximumAge: TimeInterval = 120

    mutating func reconcile(_ targets: [BatteryRefreshTarget]) {
        let sessions = Dictionary(uniqueKeysWithValues: targets.map { ($0.deviceID, $0.sessionID) })
        episodes = episodes.filter { sessions[$0.key] == $0.value.session }
    }
    mutating func clear() { episodes.removeAll() }
    mutating func consider(_ observation: BatteryObservation, threshold: Int, now: Date) -> LowBatteryNotice? {
        let value = observation.reading
        guard value.isValid, value.source == .device, let percent = value.percent,
              value.deviceID == observation.target.deviceID, value.backend == observation.target.backend,
              (0...Self.maximumAge).contains(now.timeIntervalSince(value.acquiredAt)) else { return nil }
        var episode = episodes[value.deviceID].flatMap { $0.session == observation.target.sessionID ? $0 : nil }
            ?? Episode(session: observation.target.sessionID)
        guard value.acquiredAt > episode.lastSample else { return nil }
        episode.lastSample = value.acquiredAt
        if percent >= threshold + 5 { episode.delivered = false; episode.pending = nil }
        guard percent <= threshold, !episode.delivered, episode.pending == nil else {
            episodes[value.deviceID] = episode
            return nil
        }
        let id = UUID()
        episode.pending = id
        episodes[value.deviceID] = episode
        return .init(id: id, target: observation.target, deviceName: observation.deviceName, percent: percent,
                     acquiredAt: value.acquiredAt, simulation: observation.simulation)
    }
    func isCurrent(_ notice: LowBatteryNotice) -> Bool {
        episodes[notice.target.deviceID]?.session == notice.target.sessionID
            && episodes[notice.target.deviceID]?.pending == notice.id
    }
    mutating func complete(_ notice: LowBatteryNotice, delivered: Bool) {
        guard isCurrent(notice) else { return }
        episodes[notice.target.deviceID]?.pending = nil
        episodes[notice.target.deviceID]?.delivered = delivered
    }
}

@MainActor public final class LowBatteryAlertController: ObservableObject {
    @Published public private(set) var authorization: BatteryNotificationAuthorization = .notChecked
    @Published public private(set) var isUpdating = false
    @Published public private(set) var issue: String?
    private let preferences: AppPreferences
    private let service: any BatteryNotificationServicing
    private weak var manager: DeviceManager?
    private let now: () -> Date
    private var policy = LowBatteryAlertPolicy()
    private var generation = UUID()
    private var observations: AnyCancellable?
    private var lifecycle: AnyCancellable?
    private var threshold: Int
    private var stopped = false
    private var reconcileQueued = false
    public var isEnabled: Bool { preferences.lowBatteryAlerts }

    public init(manager: DeviceManager, preferences: AppPreferences, service: any BatteryNotificationServicing,
                now: @escaping () -> Date = { .now }) {
        self.manager = manager; self.preferences = preferences; self.service = service; self.now = now
        threshold = preferences.lowBatteryThreshold
        observations = manager.batteryObservations.sink { [weak self] in self?.receive($0) }
        lifecycle = manager.objectWillChange.sink { [weak self] _ in
            guard let self, !self.reconcileQueued else { return }
            self.reconcileQueued = true
            Task { @MainActor [weak self] in self?.reconcileQueued = false; self?.reconcile() }
        }
    }

    /// Initialization and refresh never request OS permission or reprocess cached readouts.
    public func refreshAuthorization() async {
        guard isEnabled, !stopped else { return }
        authorization = await service.authorization()
    }
    public func setEnabled(_ enabled: Bool) async {
        if !enabled {
            generation = UUID(); preferences.lowBatteryAlerts = false; isUpdating = false
            policy.clear(); service.removePending(); issue = nil
            return
        }
        guard !stopped, !isUpdating else { return }
        isUpdating = true; issue = nil
        let token = generation
        do {
            try await service.requestAuthorization()
            let status = await service.authorization()
            guard token == generation, !stopped else { return }
            authorization = status
            preferences.lowBatteryAlerts = status == .authorized
            if status != .authorized { issue = "请在 macOS 通知设置中允许 RazerLite 提醒。" }
        } catch {
            guard token == generation else { return }
            preferences.lowBatteryAlerts = false; issue = error.localizedDescription
        }
        if token == generation { isUpdating = false }
    }
    public func stop() {
        stopped = true; generation = UUID(); policy.clear()
        observations?.cancel(); lifecycle?.cancel(); service.removePending()
    }
    private func reconcile() {
        guard let manager else { policy.clear(); return }
        policy.reconcile(manager.batteryTargets)
        if threshold != preferences.lowBatteryThreshold {
            threshold = preferences.lowBatteryThreshold; policy.clear()
        }
    }
    private func receive(_ observation: BatteryObservation) {
        reconcile()
        guard !stopped, isEnabled, let manager, manager.batteryTargets.contains(observation.target),
              let notice = policy.consider(observation, threshold: threshold, now: now()) else { return }
        let token = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = await self.service.authorization()
            guard self.valid(notice, token: token) else { return }
            self.authorization = status
            guard status == .authorized else { self.policy.complete(notice, delivered: false); return }
            do {
                try await self.service.post(notice)
                if self.valid(notice, token: token) { self.policy.complete(notice, delivered: true) }
                else { self.service.removePending() }
            } catch {
                guard token == self.generation else { return }
                self.policy.complete(notice, delivered: false); self.issue = error.localizedDescription
            }
        }
    }
    private func valid(_ notice: LowBatteryNotice, token: UUID) -> Bool {
        !stopped && isEnabled && generation == token && policy.isCurrent(notice)
            && preferences.lowBatteryThreshold == threshold
            && manager?.batteryTargets.contains(notice.target) == true
            && (0...LowBatteryAlertPolicy.maximumAge).contains(now().timeIntervalSince(notice.acquiredAt))
    }
}
