import Foundation
import Testing
@testable import RazerLiteCore

struct MenuBatterySummaryTests {
    @Test func zeroBatteryKeepsItsOwnSourceAndTimestamp() {
        let now = Date(timeIntervalSince1970: 12345)
        let mouse = MouseTelemetry(deviceID: "m", interfaceID: 1, readAt: now,
            batteryPercent: 0, dpi: nil, issues: [MouseReadIssue(field: "dpi", message: "timeout")])
        let cached = SystemBatteryReading(deviceID: "m", interfaceIDs: [1], acquiredAt: now.addingTimeInterval(10),
            percent: 80, source: .hidRegistry, issue: nil)
        let summary = MenuBatterySummary.choose(mouse: mouse, system: cached, keyboard: nil)
        #expect(summary?.percent == 0 && summary?.acquiredAt == now)
        #expect(summary?.source == "设备响应")
    }

    @Test func systemValueRequiresSourceAndKeepsCacheLabel() {
        let now = Date()
        let valid = SystemBatteryReading(deviceID: "m", interfaceIDs: [], acquiredAt: now,
            percent: 45, source: .macOSBluetoothSnapshot, issue: nil)
        let invalid = SystemBatteryReading(deviceID: "m", interfaceIDs: [], acquiredAt: now,
            percent: 45, source: nil, issue: nil)
        #expect(MenuBatterySummary.choose(mouse: nil, system: valid, keyboard: nil)?.source.contains("系统缓存") == true)
        #expect(MenuBatterySummary.choose(mouse: nil, system: invalid, keyboard: nil) == nil)
    }

    @Test func keyboardFailureDoesNotBecomeAValueAndZeroRemainsValid() {
        let valid = KeyboardPowerReading(deviceID: "k", interfaceID: 1, field: .battery, readAt: Date(),
            batteryPercent: 0, chargingState: nil, issue: nil)
        let invalid = KeyboardPowerReading(deviceID: "k", interfaceID: 1, field: .battery, readAt: Date(),
            batteryPercent: 90, chargingState: nil, issue: MouseReadIssue(field: "battery", message: "failed"))
        #expect(MenuBatterySummary.choose(mouse: nil, system: nil, keyboard: valid)?.percent == 0)
        #expect(MenuBatterySummary.choose(mouse: nil, system: nil, keyboard: invalid) == nil)
        #expect(MenuBatterySummary.choose(mouse: nil, system: nil, keyboard: nil) == nil)
    }
}
