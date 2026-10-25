import Foundation
import Testing
@testable import RazerLiteCore

struct ProfileServiceTests {
    private func device(id: UInt64 = 3, usbID: UInt64 = 100) -> DeviceInfo {
        let interface = HIDInterface(id: id, vendorID: 0x1532, productID: 0x00E6, product: "Viper fixture", manufacturer: nil,
                                     transport: "USB", locationID: 0, versionNumber: 0x0101, usbDeviceID: usbID,
                                     usbInterfaceNumber: 3, usbDeviceRelease: 0x0101, primaryUsagePage: 12, primaryUsage: 1,
                                     usages: [], maxInputReportSize: 0, maxOutputReportSize: 0, maxFeatureReportSize: 90,
                                     registryClass: "Fixture", observedDrivers: [], isVirtual: false)
        return DeviceInfo.group([interface])[0]
    }

    private func temporaryStorage() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RazerLiteProfileTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("profiles.json")
    }

    @Test func profileTargetUsesStableCompatibilityRatherThanSessionIdentity() throws {
        let first = device(id: 3, usbID: 100)
        let second = device(id: 33, usbID: 200)
        let target = try #require(ProfileDeviceTarget(device: first))
        #expect(target.matches(second))
        #expect(!target.storageKey.contains("usb-"))
        #expect(!target.storageKey.contains("100"))
        #expect(throws: ProfileLibraryError.self) {
            try ProfileDeviceTarget(kind: .viperV4ProDPI, vendorID: 0x1532, productID: 0x00E6, transport: "Bluetooth")
        }
    }

    @Test func invalidNamesAndValuesNeverCreateAProfile() throws {
        let target = try #require(ProfileDeviceTarget(device: device()))
        #expect(throws: ProfileLibraryError.self) { try MouseDPIProfile(name: "   ", target: target, x: 800, y: 800) }
        #expect(throws: ProfileLibraryError.self) { try MouseDPIProfile(name: "Line\nBreak", target: target, x: 800, y: 800) }
        #expect(throws: ProfileLibraryError.self) { try MouseDPIProfile(name: "Invalid", target: target, x: 2846, y: 800) }
        #expect(throws: ProfileLibraryError.self) { try MouseDPIProfile(name: "Invalid", target: target, x: 50050, y: 800) }
    }

    @Test @MainActor func savingSelectingAndDeletingPersistsOnlyLocalData() throws {
        let storage = temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage.deletingLastPathComponent()) }
        #expect(!FileManager.default.fileExists(atPath: storage.deletingLastPathComponent().path))
        let service = ProfileService(storageURL: storage)
        let fixture = device()
        let profile = try service.save(name: "办公", for: fixture, x: 800, y: 800)
        #expect(service.selectedProfile(for: fixture) == profile)
        #expect(FileManager.default.fileExists(atPath: storage.path))

        let reloaded = ProfileService(storageURL: storage)
        let restored = try #require(reloaded.profiles.first)
        #expect(restored.id == profile.id)
        #expect(restored.name == profile.name)
        #expect(restored.target == profile.target)
        #expect(restored.x == profile.x && restored.y == profile.y)
        #expect(reloaded.selectedProfile(for: fixture)?.id == profile.id)
        try reloaded.delete(profile)
        #expect(reloaded.profiles.isEmpty)
        #expect(reloaded.selectedProfile(for: fixture) == nil)
    }

    @Test @MainActor func profileExportImportMergesWithoutOverwritingExistingProfile() throws {
        let originalStorage = temporaryStorage()
        let importedStorage = temporaryStorage()
        defer {
            try? FileManager.default.removeItem(at: originalStorage.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: importedStorage.deletingLastPathComponent())
        }
        let fixture = device()
        let source = ProfileService(storageURL: originalStorage)
        let original = try source.save(name: "竞技", for: fixture, x: 2800, y: 2800)
        let data = try source.exportData(for: source.profiles(for: fixture))
        let export = try MouseDPIProfileExport.decode(data)
        let decoded = try #require(export.profiles.first)
        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.target == original.target)
        #expect(decoded.x == original.x && decoded.y == original.y)
        #expect(!String(decoding: data, as: UTF8.self).contains("usb-100"))

        let destination = ProfileService(storageURL: importedStorage)
        let first = try destination.importData(data)
        #expect(first == ProfileImportSummary(added: 1, skipped: 0))
        let duplicate = try destination.importData(data)
        #expect(duplicate == ProfileImportSummary(added: 0, skipped: 1))

        let changed = try MouseDPIProfile(id: original.id, name: "竞技", target: original.target, x: 4000, y: 4000,
                                          createdAt: original.createdAt, updatedAt: original.updatedAt)
        let changedData = try MouseDPIProfileExport(profiles: [changed]).jsonData()
        let conflict = try destination.importData(changedData)
        #expect(conflict == ProfileImportSummary(added: 1, skipped: 0, conflicts: 1))
        #expect(destination.profiles.count == 2)
        #expect(Set(destination.profiles.map(\.id)).count == 2)
        #expect(destination.profiles.contains { $0.name == "竞技" && $0.x == 2800 })
        #expect(destination.profiles.contains { $0.name == "竞技" && $0.x == 4000 })
    }

    @Test @MainActor func badStoredDataIsNotSilentlyReplaced() throws {
        let storage = temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data("{not json".utf8)
        try invalid.write(to: storage)
        let service = ProfileService(storageURL: storage)
        #expect(service.profiles.isEmpty)
        #expect(service.lastError != nil)
        #expect(throws: ProfileLibraryError.self) { try service.save(name: "不得覆盖", for: device(), x: 800, y: 800) }
        #expect(try Data(contentsOf: storage) == invalid)
    }

    @Test func futureSchemaAndUnsupportedTargetAreRejectedOnImport() throws {
        let future = Data("""
        {"schemaVersion":2,"exportedAt":"2026-10-18T00:00:00Z","profiles":[]}
        """.utf8)
        #expect(throws: ProfileLibraryError.unsupportedSchema(2)) { try MouseDPIProfileExport.decode(future) }

        let unsupported = Data("""
        {"schemaVersion":1,"exportedAt":"2026-10-18T00:00:00Z","profiles":[{"id":"00000000-0000-0000-0000-000000000001","name":"Bad","target":{"kind":"viper-v4-pro-dpi","vendorID":5426,"productID":229,"transport":"USB"},"x":800,"y":800,"createdAt":"2026-10-18T00:00:00Z","updatedAt":"2026-10-18T00:00:00Z"}]}
        """.utf8)
        #expect(throws: ProfileLibraryError.unsupportedTarget) { try MouseDPIProfileExport.decode(unsupported) }
    }
}
