import Foundation
import UserNotifications
import RazerLiteCore

@MainActor final class NativeBatteryNotificationService: NSObject, BatteryNotificationServicing, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }
    func authorization() async -> BatteryNotificationAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .unavailable
        }
    }
    func requestAuthorization() async throws { _ = try await center.requestAuthorization(options: [.alert]) }
    func post(_ notice: LowBatteryNotice) async throws {
        guard !notice.simulation else {
            throw NSError(domain: "local.RazerLite.Notification", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "模拟数据不能提交系统通知。"])
        }
        let content = UNMutableNotificationContent()
        content.title = "\(notice.deviceName) 电量偏低"
        content.body = "设备读数 \(notice.percent)% · \(notice.acquiredAt.formatted(date: .omitted, time: .shortened))"
        try await center.add(.init(identifier: "battery-\(notice.id.uuidString)", content: content, trigger: nil))
    }
    func removePending() { center.removeAllPendingNotificationRequests() }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

/// Never requests real OS permission or sends a real notification.
@MainActor final class OfflineBatteryNotificationService: BatteryNotificationServicing {
    private var allowed = false
    func authorization() async -> BatteryNotificationAuthorization { allowed ? .authorized : .notDetermined }
    func requestAuthorization() async throws { allowed = true }
    func post(_ notice: LowBatteryNotice) async throws {}
    func removePending() {}
}
