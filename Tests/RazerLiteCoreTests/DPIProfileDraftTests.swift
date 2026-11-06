import Testing
@testable import RazerLiteCore

struct DPIProfileDraftTests {
    @Test func ordinaryUpdatesPreserveEditedTextIncludingUpdatesToTheSameProfile() throws {
        let profile = try MouseDPIProfile(name: "办公", target: .viperV4ProDPI, x: 800, y: 1600)
        var draft = DPIProfileDraft()
        draft.synchronize(profile: profile, isBusy: false)
        #expect(draft.input.x == "800" && draft.input.y == "1600" && !draft.input.axesLinked)
        draft.input.editX("1200")
        draft.synchronize(profile: profile, isBusy: false)
        let updated = try MouseDPIProfile(id: profile.id, name: profile.name, target: profile.target, x: 2400, y: 2400)
        draft.synchronize(profile: updated, isBusy: false)
        #expect(draft.input.x == "1200" && draft.input.y == "1600")
    }

    @Test func explicitlyChoosingTheSameProfileAgainReplacesTheDraftOnce() throws {
        let profile = try MouseDPIProfile(name: "办公", target: .viperV4ProDPI, x: 800, y: 800)
        var draft = DPIProfileDraft()
        draft.synchronize(profile: profile, isBusy: false)
        draft.input.editX("1600")
        let request = DPIProfileLoadRequest(profile: profile)
        draft.synchronize(profile: profile, request: request, isBusy: false)
        #expect(draft.input.x == "800" && draft.input.y == "800")
        draft.input.editY("2400")
        draft.synchronize(profile: profile, request: request, isBusy: false)
        #expect(draft.input.x == "2400" && draft.input.y == "2400")
        draft.synchronize(profile: profile, request: .init(profile: profile), isBusy: false)
        #expect(draft.input.x == "800" && draft.input.y == "800")
    }

    @Test func busySelectionCannotReplaceTheDraftOrReplayAfterTheOperationFinishes() throws {
        let first = try MouseDPIProfile(name: "办公", target: .viperV4ProDPI, x: 800, y: 800)
        let second = try MouseDPIProfile(name: "游戏", target: .viperV4ProDPI, x: 1600, y: 1600)
        var draft = DPIProfileDraft()
        draft.synchronize(profile: first, isBusy: false)
        draft.input.editX("1200")
        let request = DPIProfileLoadRequest(profile: second)
        draft.synchronize(profile: second, request: request, isBusy: true)
        draft.synchronize(profile: second, request: request, isBusy: false)
        draft.reload(second, isBusy: true)
        #expect(draft.input.x == "1200" && draft.loadedProfileID == first.id)
        draft.synchronize(profile: second, request: .init(profile: second), isBusy: false)
        #expect(draft.input.x == "1600" && draft.loadedProfileID == second.id)
    }

    @Test func mismatchedRequestDoesNotLoadOrFallBackToAnotherSelection() throws {
        let first = try MouseDPIProfile(name: "办公", target: .viperV4ProDPI, x: 800, y: 800)
        let second = try MouseDPIProfile(name: "游戏", target: .viperV4ProDPI, x: 1600, y: 1600)
        var draft = DPIProfileDraft()
        draft.synchronize(profile: first, isBusy: false)
        draft.input.editX("1200")
        let stale = DPIProfileLoadRequest(profile: first)
        draft.synchronize(profile: second, request: stale, isBusy: false)
        draft.synchronize(profile: second, request: stale, isBusy: false)
        #expect(draft.input.x == "1200" && draft.loadedProfileID == first.id)
        // Ordinary navigation clears the request, allowing a genuinely new selection.
        draft.synchronize(profile: second, isBusy: false)
        #expect(draft.input.x == "1600" && draft.loadedProfileID == second.id)
    }
}
