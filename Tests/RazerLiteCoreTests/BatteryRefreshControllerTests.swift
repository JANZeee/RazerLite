import Combine
import Foundation
import Testing
@testable import RazerLiteCore

@MainActor private final class VirtualBatteryClock: BatteryRefreshClock {
    var now: TimeInterval = 0
    private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, any Error>)] = [:]
    private var observers: [(TimeInterval, CheckedContinuation<Void, Never>)] = []
    var count: Int { sleepers.count }
    func sleep(until deadline: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = (deadline, continuation)
                let ready = observers.filter { $0.0 == deadline }
                observers.removeAll { $0.0 == deadline }
                ready.forEach { $0.1.resume() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
        }
    }
    func advance(to value: TimeInterval) {
        now = value
        let due = sleepers.filter { $0.value.0 <= now }
        for (id, entry) in due { sleepers.removeValue(forKey: id); entry.1.resume() }
    }
    func waitForSleep(at deadline: TimeInterval) async {
        if sleepers.values.contains(where: { $0.0 == deadline }) { return }
        await withCheckedContinuation { observers.append((deadline, $0)) }
    }
    func cancelAll() {
        let pending = sleepers; sleepers.removeAll()
        pending.values.forEach { $0.1.resume(throwing: CancellationError()) }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct BatteryRefreshControllerTests {
    #if DEBUG
    @Test func disabledHasNoTimerAndVirtualDeadlineRunsOnlyBatteryThenManualReadPostponesIt() async throws {
        let domain = "RazerLite.RefreshTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = AppPreferences(defaults: defaults), clock = VirtualBatteryClock()
        let session = try OfflineScenarioSession()
        await session.load(.unread)
        let controller = BatteryRefreshController(manager: session.manager, preferences: preferences, clock: clock)
        defer { controller.stop(); clock.cancelAll(); session.manager.stop() }
        #expect(clock.count == 0 && controller.nextRefreshAt == nil)
        #expect(await session.services.operations.isEmpty)
        preferences.automaticBatteryRefresh = true
        await clock.waitForSleep(at: 300)
        var subscription: AnyCancellable?
        let observation: BatteryObservation = await withCheckedContinuation { continuation in
            subscription = session.manager.batteryObservations.first().sink { continuation.resume(returning: $0) }
            clock.advance(to: 300)
        }
        subscription?.cancel()
        #expect(observation.origin == .automatic && observation.reading.percent == 15)
        await clock.waitForSleep(at: 600)
        #expect((await session.services.operations).allSatisfy { $0.hasPrefix("battery-only:") })
        #expect(await session.services.operations.count == 1)
        clock.advance(to: 400)
        await session.manager.readBattery(for: observation.target.deviceID)
        await clock.waitForSleep(at: 700)
        #expect(await session.services.operations.count == 2)
        clock.advance(to: 500)
        session.manager.suspend()
        session.manager.resume()
        await clock.waitForSleep(at: 800)
        #expect(await session.services.operations.count == 2)
    }
    @Test func disablingAtTheDeadlineCannotStartAnAutomaticRead() async throws {
        let domain = "RazerLite.RefreshRaceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = AppPreferences(defaults: defaults), clock = VirtualBatteryClock()
        let session = try OfflineScenarioSession()
        await session.load(.unread)
        preferences.automaticBatteryRefresh = true
        let controller = BatteryRefreshController(manager: session.manager, preferences: preferences, clock: clock)
        defer { controller.stop(); clock.cancelAll(); session.manager.stop() }
        await clock.waitForSleep(at: 300)
        var subscription: AnyCancellable?
        await withCheckedContinuation { continuation in
            subscription = controller.$status.filter { $0 == "自动刷新已关闭" }.first().sink { _ in continuation.resume() }
            clock.advance(to: 300)
            preferences.automaticBatteryRefresh = false
        }
        subscription?.cancel()
        #expect(await session.services.operations.isEmpty)
        #expect(controller.nextRefreshAt == nil)
    }
    #endif
    @Test func onlyBatteryPreferencesPersistAndInvalidIntervalsFallBackWithoutWritingOnLaunch() throws {
        let domain = "RazerLite.BatteryPreferenceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: "battery.interval")
        defaults.set(90, forKey: "battery.threshold")
        let initial = defaults.persistentDomain(forName: domain)
        let preferences = AppPreferences(defaults: defaults)
        #expect(!preferences.automaticBatteryRefresh && !preferences.lowBatteryAlerts)
        #expect(preferences.batteryRefreshInterval == .fiveMinutes && preferences.lowBatteryThreshold == 20)
        #expect(NSDictionary(dictionary: initial ?? [:]) == NSDictionary(dictionary: defaults.persistentDomain(forName: domain) ?? [:]))
        preferences.automaticBatteryRefresh = true
        preferences.batteryRefreshInterval = .tenMinutes
        preferences.lowBatteryThreshold = 15
        let restored = AppPreferences(defaults: defaults)
        #expect(restored.automaticBatteryRefresh && restored.batteryRefreshInterval == .tenMinutes && restored.lowBatteryThreshold == 15)
        #expect(Set(defaults.persistentDomain(forName: domain)?.keys.map { $0 } ?? []) == ["battery.interval", "battery.threshold", "battery.automaticRefresh"])
    }
}
