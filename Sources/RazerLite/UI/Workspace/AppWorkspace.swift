import Combine
import Foundation
import RazerLiteCore

struct DeviceNavigationRequest: Identifiable {
    let id = UUID()
    let deviceID: String
    let page: DevicePage
    var profileLoad: DPIProfileLoadRequest? = nil
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
    @Published var requestsConnectionCheck = false
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

    /// Called only after the local profile selection succeeds. A new request
    /// makes choosing the same preset again an explicit draft replacement.
    func loadProfile(_ profile: MouseDPIProfile, for device: DeviceInfo) {
        section = .devices
        selectedDeviceID = device.id
        navigationRequest = DeviceNavigationRequest(deviceID: device.id, page: .controls,
            profileLoad: DPIProfileLoadRequest(profile: profile))
    }
}
