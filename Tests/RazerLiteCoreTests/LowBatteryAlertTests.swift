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
    var holdAuthorization = false
    var pending: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    var postWaiter: CheckedContinuation<Void, Never>?
    func authorization() async -> BatteryNotificationAuthorization {
        if holdAuthorization {
            await withCheckedContinuation { pending = $0; started?.resume(); started = nil }
        }
        return status
    }
    func requestAuthorization() async throws { requests += 1 }
    func post(_ notice: LowBatteryNotice) async throws { posts.append(notice); postWaiter?.resume(); postWaiter = nil }
    func waitForPost() async { if !posts.isEmpty { return }; await withCheckedContinuation { postWaiter = $0 } }
    func removePending() { removals += 1 }
    func waitForAuthorization() async { if pending != nil { return }; await withCheckedContinuation { started = $0 } }
    func release() { holdAuthorization = false; pending?.resume(); pending = nil }
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct LowBatteryAlertControllerTests {
    private let domain = "RazerLite.BatteryAlertsTests.\(UUID())"
    private func preferences() throws -> AppPreferences {
        return AppPreferences(defaults: try #require(UserDefaults(suiteName: domain)))
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
    #endif
}
