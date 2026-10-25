import Foundation
import Testing
@testable import RazerLiteCore

@MainActor
private final class FakeLoginItemService: LoginItemServicing {
    var status = LoginItemStatus.notRegistered
    var registrationResult = LoginItemStatus.enabled
    var failure: (any Error)?
    var registrations = 0
    var unregistrations = 0
    func register() throws {
        registrations += 1
        if let failure { throw failure }
        status = registrationResult
    }
    func unregister() async throws {
        unregistrations += 1
        if let failure { throw failure }
        status = .notRegistered
    }
}

@MainActor
struct LoginItemControllerTests {
    @Test func initializationAndRefreshNeverChangeSystemRegistration() {
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service, installationIssue: nil)
        controller.refresh()
        #expect(controller.status == .notRegistered)
        service.status = .requiresApproval
        controller.refresh()
        #expect(controller.status == .requiresApproval && controller.status.isRegistered)
        #expect(service.registrations == 0 && service.unregistrations == 0)
    }

    @Test func successfulActionsUseActualSystemStateAndAreIdempotent() async {
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service, installationIssue: nil)
        await controller.setEnabled(true)
        await controller.setEnabled(true)
        #expect(controller.status == .enabled && service.registrations == 1)
        await controller.setEnabled(false)
        await controller.setEnabled(false)
        #expect(controller.status == .notRegistered && service.unregistrations == 1)
        #expect(!controller.isUpdating && controller.issue == nil)
    }

    @Test func requiresApprovalIsNotReportedAsEnabled() async {
        let service = FakeLoginItemService()
        service.registrationResult = .requiresApproval
        let controller = LoginItemController(service: service, installationIssue: nil)
        await controller.setEnabled(true)
        #expect(controller.status == .requiresApproval)
        #expect(controller.issue == nil)
    }

    @Test func registrationFailurePreservesActualStateAndDoesNotRetryOnRefresh() async {
        let service = FakeLoginItemService()
        service.failure = CocoaError(.fileWriteNoPermission)
        let controller = LoginItemController(service: service, installationIssue: nil)
        await controller.setEnabled(true)
        controller.refresh()
        #expect(controller.status == .notRegistered && controller.issue != nil)
        #expect(!controller.isUpdating && service.registrations == 1)
    }

    @Test func unstableInstallationBlocksRegisterButAllowsRemovingExistingItem() async {
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service, installationIssue: "开发位置")
        await controller.setEnabled(true)
        #expect(!controller.canEnable && service.registrations == 0 && controller.issue != nil)
        service.status = .enabled
        controller.refresh()
        await controller.setEnabled(false)
        #expect(service.unregistrations == 1 && controller.status == .notRegistered)
    }

    @Test func unregisterFailureCannotPretendDisabled() async {
        let service = FakeLoginItemService()
        service.status = .enabled
        service.failure = CocoaError(.fileWriteNoPermission)
        let controller = LoginItemController(service: service, installationIssue: nil)
        await controller.setEnabled(false)
        #expect(controller.status == .enabled && controller.issue != nil && !controller.isUpdating)
    }

    @Test func installationPolicyRejectsCachesLookalikeDirectoriesAndSimulation() {
        let home = URL(fileURLWithPath: "/Users/tester")
        func reason(_ path: String, simulated: Bool = false) -> String? {
            LoginItemInstallation.blockingReason(bundleURL: URL(fileURLWithPath: path), homeURL: home, isSimulation: simulated)
        }
        #expect(reason("/Applications/RazerLite.app") == nil)
        #expect(reason("/Users/tester/Applications/RazerLite.app") == nil)
        #expect(reason("/ApplicationsOther/RazerLite.app") != nil)
        #expect(reason("/Users/tester/Library/Caches/RazerLite.app") != nil)
        #expect(reason("/Applications/RazerLite.app", simulated: true) != nil)
        #expect(reason("/Applications/RazerLite") != nil)
    }
}
