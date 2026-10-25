import Foundation
import Testing
@testable import RazerLiteCore

struct BatteryRefreshPolicyTests {
    private func target(_ id: String = "mouse", _ backend: DeviceReadBackend = .viperV4USB) -> BatteryRefreshTarget {
        .init(deviceID: id, sessionID: UUID(), backend: backend)
    }
    @Test func defaultDisabledAndBusyHaveNoDeadlineAndNoImmediateReadOnEnable() throws {
        var policy = BatteryRefreshPolicy()
        let device = target()
        policy.configure(targets: [device], enabled: false, paused: false, interval: .fiveMinutes, now: 0)
        #expect(policy.nextDeadline(busy: []) == nil)
        policy.configure(targets: [device], enabled: true, paused: false, interval: .fiveMinutes, now: 10)
        #expect(policy.nextDeadline(busy: []) == 310)
        #expect(policy.beginDue(now: 309, busy: []) == nil)
        #expect(policy.nextDeadline(busy: [device.deviceID]) == nil)
        #expect(policy.beginDue(now: 400, busy: [device.deviceID]) == nil)
        #expect(policy.beginDue(now: 400, busy: []) == device)
        #expect(policy.nextDeadline(busy: []) == nil)
    }
    @Test func longOperationNeverOverlapsAndFailureBackoffIsBounded() {
        var policy = BatteryRefreshPolicy()
        let device = target()
        policy.configure(targets: [device], enabled: true, paused: false, interval: .fiveMinutes, now: 0)
        #expect(policy.beginDue(now: 300, busy: []) == device)
        #expect(policy.beginDue(now: 10000, busy: []) == nil)
        policy.finish(device, failure: .timeout, now: 10000)
        #expect(policy.nextDeadline(busy: []) == 10600)
        for now in [10600.0, 11800, 14200] {
            #expect(policy.beginDue(now: now, busy: []) == device)
            policy.finish(device, failure: .busy, now: now)
        }
        #expect(policy.nextDeadline(busy: []) == 17800)
        policy.observed(device, failure: nil, now: 15000)
        #expect(policy.nextDeadline(busy: []) == 15300)
    }
    @Test func permissionFailureStopsUntilExplicitSuccessAndSessionChangesDiscardOldCompletion() {
        var policy = BatteryRefreshPolicy()
        let old = target()
        policy.configure(targets: [old], enabled: true, paused: false, interval: .fiveMinutes, now: 0)
        #expect(policy.beginDue(now: 300, busy: []) == old)
        let new = target()
        policy.configure(targets: [new], enabled: true, paused: false, interval: .fiveMinutes, now: 400)
        policy.finish(old, failure: .permissionDenied, now: 500)
        #expect(policy.nextDeadline(busy: []) == 700)
        #expect(policy.beginDue(now: 700, busy: []) == new)
        policy.finish(new, failure: .permissionDenied, now: 700)
        #expect(policy.nextDeadline(busy: []) == nil)
        policy.observed(new, failure: nil, now: 800)
        #expect(policy.nextDeadline(busy: []) == 1100)
    }
    @Test func sleepPauseDisconnectAndIntervalChangeDoNotCatchUpInBursts() {
        var policy = BatteryRefreshPolicy()
        let device = target()
        policy.configure(targets: [device], enabled: true, paused: false, interval: .fiveMinutes, now: 0)
        policy.configure(targets: [device], enabled: true, paused: true, interval: .fiveMinutes, now: 100)
        #expect(policy.nextDeadline(busy: []) == nil)
        policy.configure(targets: [device], enabled: true, paused: false, interval: .fiveMinutes, now: 10000)
        #expect(policy.nextDeadline(busy: []) == 10300)
        policy.configure(targets: [device], enabled: true, paused: false, interval: .tenMinutes, now: 10100)
        #expect(policy.nextDeadline(busy: []) == 10700)
        policy.configure(targets: [], enabled: true, paused: false, interval: .tenMinutes, now: 10200)
        #expect(policy.nextDeadline(busy: []) == nil)
    }
    @Test func systemSnapshotsHaveIndependentGlobalBudgetAndOnlyOneReadAtATime() {
        var policy = BatteryRefreshPolicy()
        let first = target("bt1", .macOSBluetoothBattery), second = target("bt2", .macOSBluetoothBattery)
        policy.configure(targets: [first, second], enabled: true, paused: false, interval: .fiveMinutes, now: 0)
        #expect(policy.nextDeadline(busy: []) == 900)
        #expect(policy.beginDue(now: 900, busy: []) == first)
        policy.finish(first, failure: nil, now: 905)
        #expect(policy.nextDeadline(busy: []) == 1800)
        #expect(policy.beginDue(now: 1800, busy: []) == second)
    }
    @Test func hardwareEligibilityIsNeverGrantedByModelCatalogOrSimulationEvidence() {
        for backend: DeviceReadBackend in [.viperV4USB, .blackWidowLowProfileUSB, .macOSBluetoothBattery] {
            #expect(!BatteryRefreshEligibility.allows(backend, simulation: false))
            #expect(BatteryRefreshEligibility.allows(backend, simulation: true))
        }
    }
}
