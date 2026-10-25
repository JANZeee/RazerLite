import Combine
import Foundation
import RazerLiteCore

struct DeviceNavigationRequest: Identifiable {
    let id = UUID()
    let deviceID: String
    let page: DevicePage
}

/// Only the top-level ordinary page is restored. Registry IDs and detail
/// navigation requests are transient and never enter preferences.
@MainActor
final class AppWorkspace: ObservableObject {
    typealias Section = WorkspaceSection
    private let preferences: AppPreferences
    @Published var selectedDeviceID: String?
    @Published var section: Section {
        didSet { preferences.section = section }
    }
    @Published var navigationRequest: DeviceNavigationRequest?

    init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
        section = preferences.section
    }

    func select(_ device: DeviceInfo, page: DevicePage = .overview) {
        section = .devices
        selectedDeviceID = device.id
        navigationRequest = DeviceNavigationRequest(deviceID: device.id, page: page)
    }
}
