import Foundation
import ServiceManagement
import RazerLiteCore

@MainActor
final class NativeLoginItemService: LoginItemServicing {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unavailable
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() async throws { try await SMAppService.mainApp.unregister() }
}

@MainActor
final class OfflineLoginItemService: LoginItemServicing {
    var status: LoginItemStatus { .notRegistered }
    func register() throws { throw CocoaError(.featureUnsupported) }
    func unregister() async throws { throw CocoaError(.featureUnsupported) }
}
