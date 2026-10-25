import Combine
import Foundation

@MainActor protocol BatteryRefreshClock {
    var now: TimeInterval { get }
    func sleep(until deadline: TimeInterval) async throws
}
@MainActor private struct MonotonicBatteryClock: BatteryRefreshClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sleep(until deadline: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(0, deadline - now)))
    }
}

@MainActor public final class BatteryRefreshController: ObservableObject {
    @Published public private(set) var status = "自动刷新已关闭"
    @Published public private(set) var eligibleDeviceCount = 0
    @Published public private(set) var nextRefreshAt: Date?
    private weak var manager: DeviceManager?
    private let preferences: AppPreferences
    private let clock: any BatteryRefreshClock
    private var policy = BatteryRefreshPolicy()
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var timerDeadline: TimeInterval?
    private var queued = false
    private var stopped = false

    public convenience init(manager: DeviceManager, preferences: AppPreferences) {
        self.init(manager: manager, preferences: preferences, clock: MonotonicBatteryClock())
    }
    init(manager: DeviceManager, preferences: AppPreferences, clock: any BatteryRefreshClock) {
        self.manager = manager; self.preferences = preferences; self.clock = clock
        manager.objectWillChange.sink { [weak self] _ in self?.queueReconcile() }.store(in: &subscriptions)
        preferences.objectWillChange.sink { [weak self] _ in self?.queueReconcile() }.store(in: &subscriptions)
        manager.batteryObservations.sink { [weak self] observation in
            guard let self, observation.origin == .manual else { return }
            self.policy.observed(observation.target, failure: observation.reading.isValid ? nil : observation.reading.issue?.kind ?? .invalidData, now: self.clock.now)
            self.queueReconcile()
        }.store(in: &subscriptions)
        reconcile()
    }
    public func stop() {
        stopped = true; timer?.cancel(); timer = nil; worker?.cancel()
        subscriptions.removeAll(); nextRefreshAt = nil
    }
    private func queueReconcile() {
        guard !queued, !stopped else { return }
        queued = true
        Task { @MainActor [weak self] in self?.queued = false; self?.reconcile() }
    }
    private func reconcile() {
        guard !stopped, let manager else { return }
        let targets = manager.batteryTargets.filter { BatteryRefreshEligibility.allows($0.backend, simulation: manager.isSimulation) }
        eligibleDeviceCount = targets.count
        let paused = manager.isSuspended || !manager.isMonitoring
        policy.configure(targets: targets, enabled: preferences.automaticBatteryRefresh, paused: paused,
                         interval: preferences.batteryRefreshInterval, now: clock.now)
        if !preferences.automaticBatteryRefresh || paused { worker?.cancel() }
        let busy = Set(targets.filter { manager.isDeviceBusy($0.deviceID) }.map(\.deviceID))
        let deadline = policy.nextDeadline(busy: busy)
        if !preferences.automaticBatteryRefresh { status = "自动刷新已关闭" }
        else if paused { status = "自动刷新已暂停" }
        else if targets.isEmpty { status = manager.isSimulation ? "等待模拟设备" : "当前后端待自动刷新真机验收" }
        else if policy.inFlight != nil { status = "正在刷新电量" }
        else if deadline == nil { status = "等待设备可用或手动重试" }
        else { status = "已安排低频刷新" }
        nextRefreshAt = deadline.map { Date().addingTimeInterval(max(0, $0 - clock.now)) }
        guard deadline != timerDeadline else { return }
        timer?.cancel(); timer = nil; timerDeadline = deadline
        guard let deadline else { return }
        let clock = clock
        timer = Task { @MainActor [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            self?.timerDeadline = nil; self?.timer = nil
            self?.tick()
        }
    }
    private func tick() {
        guard !stopped, let manager else { return }
        guard preferences.automaticBatteryRefresh, manager.isMonitoring, !manager.isSuspended else { reconcile(); return }
        let busy = Set(manager.batteryTargets.filter { manager.isDeviceBusy($0.deviceID) }.map(\.deviceID))
        guard let target = policy.beginDue(now: clock.now, busy: busy) else { reconcile(); return }
        worker = Task { @MainActor [weak self, weak manager] in
            let value: BatteryReading?
            if !Task.isCancelled, self?.preferences.automaticBatteryRefresh == true,
               manager?.batteryTargets.contains(target) == true {
                value = await manager?.readBattery(for: target.deviceID, origin: .automatic)
            } else { value = nil }
            guard let self else { return }
            let failure: ReadFailureKind? = value.map { $0.isValid ? nil : $0.issue?.kind ?? .invalidData } ?? .cancelled
            self.policy.finish(target, failure: failure, now: self.clock.now)
            self.worker = nil
            self.reconcile()
        }
        reconcile()
    }
}
