import Foundation
import Testing
@testable import RazerLiteCore

struct LowBatteryAlertPolicyTests {
    private let session = UUID()
    private func observation(_ percent: Int?, at: TimeInterval, source: BatteryValueSource = .device, issue: MouseReadIssue? = nil) -> BatteryObservation {
        let target = BatteryRefreshTarget(deviceID: "test", sessionID: session, backend: .viperV4USB)
        return .init(target: target, deviceName: "测试鼠标", reading: .init(deviceID: "test", interfaceIDs: [3], backend: .viperV4USB,
            percent: percent, acquiredAt: Date(timeIntervalSince1970: at), source: source, issue: issue), origin: .manual, simulation: true)
    }
    @Test func firstLowValueIncludingZeroDeduplicatesUntilHysteresisRecovery() throws {
        var policy = LowBatteryAlertPolicy()
        func consider(_ percent: Int, _ at: TimeInterval) -> LowBatteryNotice? {
            policy.consider(observation(percent, at: at), threshold: 20, now: Date(timeIntervalSince1970: at))
        }
        #expect(consider(30, 1) == nil)
        let notice = try #require(consider(0, 2))
        #expect(consider(0, 3) == nil) // A delivery in progress is reserved too.
        policy.complete(notice, delivered: true)
        #expect(consider(19, 4) == nil)
        #expect(consider(21, 5) == nil)
        #expect(consider(19, 6) == nil)
        #expect(consider(25, 7) == nil)
        #expect(consider(20, 8) != nil)
    }
    @Test func invalidCachedStaleFutureAndRepeatedSamplesNeverNotify() {
        var policy = LowBatteryAlertPolicy()
        let now = Date(timeIntervalSince1970: 1000)
        for value in [observation(nil, at: 1000), observation(-1, at: 1000), observation(101, at: 1000),
                      observation(0, at: 1000, source: .systemCache), observation(0, at: 879), observation(0, at: 1001),
                      observation(0, at: 1000, issue: .init(field: "battery", message: "拒绝", kind: .timeout))] {
            #expect(policy.consider(value, threshold: 20, now: now) == nil)
        }
        let value = observation(10, at: 1000)
        let notice = policy.consider(value, threshold: 20, now: now)
        #expect(notice != nil)
        #expect(policy.consider(value, threshold: 20, now: now) == nil)
    }
    @Test func deliveryFailureRetriesOnlyOnANewSampleAndDisconnectInvalidatesPendingNotice() throws {
        var policy = LowBatteryAlertPolicy()
        let firstValue = policy.consider(observation(10, at: 1), threshold: 20, now: Date(timeIntervalSince1970: 1))
        let first = try #require(firstValue)
        policy.complete(first, delivered: false)
        #expect(policy.consider(observation(10, at: 1), threshold: 20, now: Date(timeIntervalSince1970: 1)) == nil)
        let retryValue = policy.consider(observation(10, at: 2), threshold: 20, now: Date(timeIntervalSince1970: 2))
        let retry = try #require(retryValue)
        policy.reconcile([])
        #expect(!policy.isCurrent(retry))
    }
}

@MainActor private final class FakeBatteryNotificationService: BatteryNotificationServicing {
    var status: BatteryNotificationAuthorization = .authorized
    var requests = 0
    var posts: [LowBatteryNotice] = []
    var removals = 0
    var removedIDs: [UUID] = []
    var pendingIDs: Set<UUID> = []
    var holdAuthorization = false
    var holdPosts = false
    var pending: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    var postWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var pendingPosts: [UUID: CheckedContinuation<Void, Never>] = [:]
    func authorization() async -> BatteryNotificationAuthorization {
        if holdAuthorization {
            await withCheckedContinuation { pending = $0; started?.resume(); started = nil }
        }
        return status
    }
    func requestAuthorization() async throws { requests += 1 }
    func post(_ notice: LowBatteryNotice) async throws {
        posts.append(notice); pendingIDs.insert(notice.id)
        let ready = postWaiters.filter { $0.0 <= posts.count }
        postWaiters.removeAll { $0.0 <= posts.count }
        ready.forEach { $0.1.resume() }
        if holdPosts { await withCheckedContinuation { pendingPosts[notice.id] = $0 } }
    }
    func waitForPost(_ count: Int = 1) async {
        if posts.count >= count { return }
        await withCheckedContinuation { postWaiters.append((count, $0)) }
    }
    func removePending(id: UUID) { removedIDs.append(id); pendingIDs.remove(id) }
    func removePending() { removals += 1; pendingIDs.removeAll() }
    func waitForAuthorization() async { if pending != nil { return }; await withCheckedContinuation { started = $0 } }
    func release() { holdAuthorization = false; pending?.resume(); pending = nil }
    func releasePost(_ id: UUID) { pendingPosts.removeValue(forKey: id)?.resume() }
    func releaseAll() {
        release(); holdPosts = false
        let pending = pendingPosts; pendingPosts.removeAll()
        pending.values.forEach { $0.resume() }
    }
}

@MainActor private final class AlertTestClock {
    var now = Date(timeIntervalSince1970: 1000)
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct LowBatteryAlertControllerTests {
    private let domain = "RazerLite.BatteryAlertsTests.\(UUID())"
    private func preferences() throws -> AppPreferences {
        return AppPreferences(defaults: try #require(UserDefaults(suiteName: domain)))
    }
    private func observation(_ target: BatteryRefreshTarget, percent: Int = 10, at: Date) -> BatteryObservation {
        .init(target: target, deviceName: "测试鼠标", reading: .init(deviceID: target.deviceID, interfaceIDs: [],
            backend: target.backend, percent: percent, acquiredAt: at, source: .device, issue: nil),
            origin: .manual, simulation: true)
    }
    #if DEBUG
    @Test func permissionIsRequestedOnlyOnExplicitEnableAndDenialCannotPretendEnabled() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let session = try OfflineScenarioSession(), preferences = try preferences(), service = FakeBatteryNotificationService()
        let controller = LowBatteryAlertController(manager: session.manager, preferences: preferences, service: service)
        await session.load(.keyboard)
        await controller.refreshAuthorization()
        #expect(service.requests == 0 && service.posts.isEmpty && controller.authorization == .notChecked)
        service.status = .denied
        await controller.setEnabled(true)
        #expect(service.requests == 1 && !controller.isEnabled && controller.authorization == .denied)
        #expect(controller.issue != nil)
        controller.stop(); session.manager.stop()
    }
    @Test func explicitEnableDoesNotReplayExistingReadingsAndDisableCancelsAnAwaitedPermission() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let session = try OfflineScenarioSession(), preferences = try preferences(), service = FakeBatteryNotificationService()
        await session.load(.keyboard)
        let controller = LowBatteryAlertController(manager: session.manager, preferences: preferences, service: service)
        await controller.setEnabled(true)
        #expect(service.posts.isEmpty)
        await controller.setEnabled(false)
        service.holdAuthorization = true
        let enabling = Task { await controller.setEnabled(true) }
        await service.waitForAuthorization()
        await controller.setEnabled(false)
        service.release(); await enabling.value
        #expect(!controller.isEnabled && service.posts.isEmpty)
        controller.stop(); session.manager.stop()
    }
    @Test func disconnectWhileCheckingPermissionPreventsNotification() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let session = try OfflineScenarioSession(), preferences = try preferences(), service = FakeBatteryNotificationService()
        let controller = LowBatteryAlertController(manager: session.manager, preferences: preferences, service: service)
        await session.load(.unread)
        await controller.setEnabled(true)
        service.holdAuthorization = true
        let id = try #require(session.manager.devices.first?.id)
        await session.manager.readBattery(for: id)
        await service.waitForAuthorization()
        session.disconnect()
        service.release()
        // refreshAuthorization runs after the queued delivery check on the same executor.
        await controller.refreshAuthorization()
        #expect(service.posts.isEmpty)
        controller.stop(); session.manager.stop()
    }
    @Test func freshManualBatteryDeliversOnceAndPermissionRevocationPreventsLaterAlerts() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let session = try OfflineScenarioSession(), preferences = try preferences(), service = FakeBatteryNotificationService()
        let controller = LowBatteryAlertController(manager: session.manager, preferences: preferences, service: service)
        await session.load(.unread)
        await controller.setEnabled(true)
        let id = try #require(session.manager.devices.first?.id)
        await session.manager.readBattery(for: id)
        await service.waitForPost()
        #expect(service.posts.count == 1 && service.posts.first?.percent == 15)
        await session.manager.readBattery(for: id)
        await controller.refreshAuthorization()
        #expect(service.posts.count == 1)
        service.status = .denied
        await session.load(.keyboard) // A fresh 0% sample from a different session.
        await controller.refreshAuthorization()
        #expect(service.posts.count == 1 && controller.authorization == .denied)
        controller.stop(); session.manager.stop()
    }

    @Test func expiredAuthorizationCheckReleasesTheEpisodeForAFreshSample() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let session = try OfflineScenarioSession(), preferences = try preferences(), service = FakeBatteryNotificationService()
        await session.load(.unread)
        let clock = AlertTestClock()
        let controller = LowBatteryAlertController(manager: session.manager, preferences: preferences, service: service, now: { clock.now })
        defer { service.releaseAll(); controller.stop(); session.manager.stop() }
        await controller.setEnabled(true)
        let target = try #require(session.manager.batteryTargets.first)
        service.holdAuthorization = true
        let first = try #require(controller.receive(observation(target, at: clock.now)))
        await service.waitForAuthorization()
        clock.now.addTimeInterval(LowBatteryAlertPolicy.maximumAge + 1)
        service.release()
        await first.value
        #expect(service.posts.isEmpty)
        let fresh = try #require(controller.receive(observation(target, at: clock.now)))
        await fresh.value
        #expect(service.posts.count == 1 && service.posts.first?.acquiredAt == clock.now)
    }

    @Test func expiredPostReleasesTheEpisodeAndRemovesOnlyItsOwnRequest() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let session = try OfflineScenarioSession(), preferences = try preferences(), service = FakeBatteryNotificationService()
        await session.load(.unread)
        let clock = AlertTestClock()
        let controller = LowBatteryAlertController(manager: session.manager, preferences: preferences, service: service, now: { clock.now })
        defer { service.releaseAll(); controller.stop(); session.manager.stop() }
        await controller.setEnabled(true)
        let target = try #require(session.manager.batteryTargets.first)
        service.holdPosts = true
        let first = try #require(controller.receive(observation(target, at: clock.now)))
        await service.waitForPost()
        let staleID = try #require(service.posts.first?.id)
        clock.now.addTimeInterval(LowBatteryAlertPolicy.maximumAge + 1)
        service.releasePost(staleID)
        await first.value
        #expect(service.removedIDs == [staleID] && service.removals == 0 && service.pendingIDs.isEmpty)
        service.holdPosts = false
        let fresh = try #require(controller.receive(observation(target, at: clock.now)))
        await fresh.value
        #expect(service.posts.count == 2 && service.posts.last?.acquiredAt == clock.now)
    }

    @Test func latePostCannotRemoveAnotherDeviceOrANewerEpisode() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        for anotherDevice in [false, true] {
            let session = try OfflineScenarioSession(), preferences = try preferences(), service = FakeBatteryNotificationService()
            await session.load(.twinMice)
            let clock = AlertTestClock()
            let controller = LowBatteryAlertController(manager: session.manager, preferences: preferences, service: service, now: { clock.now })
            defer { service.releaseAll(); controller.stop(); session.manager.stop() }
            await controller.setEnabled(true)
            let targets = session.manager.batteryTargets
            #expect(targets.count == 2)
            let firstTarget = try #require(targets.first), nextTarget = try #require(anotherDevice ? targets.last : targets.first)
            service.holdPosts = true
            let first = try #require(controller.receive(observation(firstTarget, at: clock.now)))
            await service.waitForPost()
            let staleID = try #require(service.posts.first?.id)
            clock.now.addTimeInterval(1)
            #expect(controller.receive(observation(firstTarget, percent: 30, at: clock.now)) == nil)
            clock.now.addTimeInterval(1)
            let next = try #require(controller.receive(observation(nextTarget, at: clock.now)))
            await service.waitForPost(2)
            let currentID = try #require(service.posts.last?.id)
            service.releasePost(staleID)
            await first.value
            #expect(service.removedIDs == [staleID] && service.removals == 0)
            #expect(service.pendingIDs == [currentID])
            service.releasePost(currentID)
            await next.value
            clock.now.addTimeInterval(1)
            #expect(controller.receive(observation(nextTarget, at: clock.now)) == nil)
        }
    }
    #endif
}
