import Foundation

/// A transient request to replace editor text. Never persisted or used as a write permit.
public struct DPIProfileLoadRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let profile: MouseDPIProfile

    public init(profile: MouseDPIProfile, id: UUID = UUID()) {
        self.id = id
        self.profile = profile
    }
}

/// Keeps ordinary view updates separate from the user's explicit "load" action.
public struct DPIProfileDraft: Sendable {
    public var input = ViperDPIInput()
    public private(set) var loadedProfileID: UUID?
    private var handledLoadRequestID: UUID?

    public init() {}

    public mutating func synchronize(profile: MouseDPIProfile?, request: DPIProfileLoadRequest? = nil, isBusy: Bool) {
        if let request {
            guard request.id != handledLoadRequestID else { return }
            // Consume rejected requests too; finishing a device operation must
            // never replay an earlier attempt to replace its draft.
            handledLoadRequestID = request.id
            guard !isBusy, let profile, profile == request.profile else { return }
            load(profile)
            return
        }
        guard !isBusy, let profile, loadedProfileID != profile.id else { return }
        load(profile)
    }

    public mutating func reload(_ profile: MouseDPIProfile, isBusy: Bool) {
        guard !isBusy else { return }
        load(profile)
    }

    private mutating func load(_ profile: MouseDPIProfile) {
        input = ViperDPIInput(x: profile.x, y: profile.y)
        loadedProfileID = profile.id
    }
}
