import Foundation
import Testing
@testable import RazerLiteCore

@MainActor
struct AppPreferencesTests {
    @Test func defaultsArePassiveAndOnlyOrdinaryUIStateIsSaved() throws {
        let domain = "RazerLite.PreferenceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.appearance == .system && preferences.closeBehavior == .menuBar)
        #expect(preferences.section == .devices)
        #expect(defaults.persistentDomain(forName: domain)?.isEmpty != false)
        preferences.appearance = .dark
        preferences.closeBehavior = .quit
        preferences.section = .profiles
        let restored = AppPreferences(defaults: defaults)
        #expect(restored.appearance == .dark && restored.closeBehavior == .quit)
        #expect(restored.section == .profiles)
        let saved = try #require(defaults.persistentDomain(forName: domain))
        #expect(Set(saved.keys) == ["ui.appearance", "ui.closeBehavior", "ui.section"])
    }

    @Test func invalidAndFuturePreferencesFallBackWithoutOverwritingStoredData() throws {
        let domain = "RazerLite.PreferenceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("future", forKey: "ui.appearance")
        defaults.set(["invalid"], forKey: "ui.closeBehavior")
        defaults.set(42, forKey: "ui.section")
        let before = defaults.persistentDomain(forName: domain)
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.appearance == .system && preferences.closeBehavior == .menuBar)
        #expect(preferences.section == .devices)
        #expect(NSDictionary(dictionary: defaults.persistentDomain(forName: domain) ?? [:])
            == NSDictionary(dictionary: before ?? [:]))
    }

    @Test func simulationPreferencesCannotAlterAnotherStore() throws {
        let firstDomain = "RazerLite.PreferenceTests.Live.\(UUID())"
        let secondDomain = "RazerLite.PreferenceTests.Simulated.\(UUID())"
        let first = try #require(UserDefaults(suiteName: firstDomain))
        let second = try #require(UserDefaults(suiteName: secondDomain))
        defer {
            first.removePersistentDomain(forName: firstDomain)
            second.removePersistentDomain(forName: secondDomain)
        }
        let live = AppPreferences(defaults: first), simulated = AppPreferences(defaults: second)
        simulated.appearance = .light
        simulated.closeBehavior = .quit
        #expect(live.appearance == .system && live.closeBehavior == .menuBar)
        #expect(AppPreferences(defaults: first).section == .devices)
    }
}
