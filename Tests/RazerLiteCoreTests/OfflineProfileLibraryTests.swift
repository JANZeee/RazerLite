import Foundation
import Testing
@testable import RazerLiteCore

@MainActor
struct OfflineProfileLibraryTests {
    private func storage() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RazerLiteOfflineProfiles-\(UUID())")
            .appendingPathComponent("profiles.json")
    }

    @Test func offlineCreateEditCopyAndReloadPreserveSchemaWithoutSelectingADevice() throws {
        let url = storage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let service = ProfileService(storageURL: url)
        let first = try service.create(name: "办公", target: .viperV4ProDPI, x: 1600, y: 1800)
        #expect(service.selectedProfileIDs.isEmpty)
        let edited = try service.update(first, name: "办公新版", x: 2000, y: 2200)
        #expect(edited.id == first.id && edited.createdAt == first.createdAt)
        let copy = try service.duplicate(edited)
        #expect(copy.id != edited.id && copy.name == "办公新版 副本")
        #expect(copy.x == edited.x && copy.y == edited.y)
        let reloaded = ProfileService(storageURL: url)
        #expect(reloaded.canModify && reloaded.profiles.count == 2)
        #expect(reloaded.profiles.first?.name == "办公新版")
        #expect(reloaded.selectedProfileIDs.isEmpty)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        try reloaded.delete(copy)
        #expect(ProfileService(storageURL: url).profiles.count == 1)
    }

    @Test func duplicateNamesStayWithinLimitAndStaleEditsNeverOverwriteNewContent() throws {
        let url = storage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let service = ProfileService(storageURL: url)
        let first = try service.create(name: String(repeating: "测", count: 48), target: .viperV4ProDPI, x: 800, y: 800)
        let a = try service.duplicate(first), b = try service.duplicate(first)
        #expect(a.name.count <= 48 && b.name.count <= 48 && a.name != b.name)
        let updated = try service.update(first, name: "已修改", x: 1000, y: 1000)
        let before = try Data(contentsOf: url)
        #expect(throws: ProfileLibraryError.profileChanged) { try service.update(first, name: "旧编辑器", x: 1200, y: 1200) }
        #expect(throws: ProfileLibraryError.profileChanged) { try service.delete(first) }
        #expect(throws: ProfileLibraryError.profileChanged) { try service.duplicate(first) }
        #expect(try Data(contentsOf: url) == before)
        #expect(service.profiles.first?.name == updated.name)
    }

    @Test func invalidOfflineChangesAndStorageFailureKeepMemoryAndFileIntact() throws {
        let url = storage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let service = ProfileService(storageURL: url)
        let first = try service.create(name: "保留", target: .viperV4ProDPI, x: 800, y: 800)
        let before = try Data(contentsOf: url)
        #expect(throws: ProfileLibraryError.invalidDPI) { try service.update(first, name: "无效", x: 2846, y: 800) }
        #expect(throws: ProfileLibraryError.invalidName) { try service.create(name: "换\r行", target: .viperV4ProDPI, x: 800, y: 800) }
        #expect(try Data(contentsOf: url) == before)
        let blockedURL = url.appendingPathComponent("impossible.json")
        let blocked = ProfileService(storageURL: blockedURL)
        #expect(throws: ProfileLibraryError.self) { try blocked.create(name: "不能保存", target: .viperV4ProDPI, x: 800, y: 800) }
        #expect(blocked.profiles.isEmpty)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func importPreviewIsReadOnlyAndConflictsBecomeCopies() throws {
        let url = storage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let service = ProfileService(storageURL: url)
        let first = try service.create(name: "原值", target: .viperV4ProDPI, x: 800, y: 800)
        let conflict = try MouseDPIProfile(id: first.id, name: "新值", target: first.target, x: 1600, y: 1600)
        let data = try MouseDPIProfileExport(profiles: [conflict]).jsonData()
        let before = try Data(contentsOf: url)
        #expect(try service.previewImport(data) == ProfileImportSummary(added: 1, skipped: 0, conflicts: 1))
        #expect(service.profiles.count == 1 && service.selectedProfileIDs.isEmpty)
        #expect(try Data(contentsOf: url) == before)
        let actual = try service.importData(data)
        #expect(actual.conflicts == 1 && service.profiles.count == 2)
        #expect(service.profiles.contains { $0.id == first.id && $0.x == 800 })
        #expect(service.profiles.contains { $0.id != first.id && $0.x == 1600 })
        let noOpBefore = try Data(contentsOf: url)
        #expect(try service.importData(data).skipped == 1)
        #expect(try Data(contentsOf: url) == noOpBefore)
    }

    @Test func overLimitImportCannotPartiallyCommit() throws {
        let url = storage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let service = ProfileService(storageURL: url)
        let seed = try (0..<127).map { try MouseDPIProfile(name: "预设 \($0)", target: .viperV4ProDPI, x: 800, y: 800) }
        try service.importData(MouseDPIProfileExport(profiles: seed).jsonData())
        let before = try Data(contentsOf: url)
        let incoming = try (0..<2).map { try MouseDPIProfile(name: "新增 \($0)", target: .viperV4ProDPI, x: 1600, y: 1600) }
        let data = try MouseDPIProfileExport(profiles: incoming).jsonData()
        #expect(throws: ProfileLibraryError.tooManyProfiles) { try service.previewImport(data) }
        #expect(throws: ProfileLibraryError.tooManyProfiles) { try service.importData(data) }
        #expect(service.profiles.count == 127)
        #expect(try Data(contentsOf: url) == before)
        var invalidObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var invalidProfiles = try #require(invalidObject["profiles"] as? [[String: Any]])
        invalidProfiles[1]["x"] = 123
        invalidObject["profiles"] = invalidProfiles
        let invalidData = try JSONSerialization.data(withJSONObject: invalidObject)
        #expect(throws: ProfileLibraryError.invalidDPI) { try service.importData(invalidData) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func boundedFileReadingAndOversizedDataAreRejectedBeforeImport() throws {
        let url = storage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oversized = Data(repeating: 32, count: MouseDPIProfileExport.maximumDataBytes + 1)
        try oversized.write(to: url)
        #expect(throws: ProfileLibraryError.fileTooLarge) { try ProfileService.readImportFile(url) }
        #expect(throws: ProfileLibraryError.fileTooLarge) { try MouseDPIProfileExport.decode(oversized) }
        let blocked = ProfileService(storageURL: url)
        #expect(!blocked.canModify && blocked.lastError != nil)
        #expect(throws: ProfileLibraryError.self) { try blocked.create(name: "不得覆盖", target: .viperV4ProDPI, x: 800, y: 800) }
        #expect(try Data(contentsOf: url) == oversized)
        #expect(throws: ProfileLibraryError.invalidImportFile) { try ProfileService.readImportFile(url.deletingLastPathComponent()) }
    }

    @Test func aSingleLargeGraphemeCannotCreateAnUnreadableLibrary() throws {
        let url = storage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let service = ProfileService(storageURL: url)
        _ = try service.create(name: "保留", target: .viperV4ProDPI, x: 800, y: 800)
        let before = try Data(contentsOf: url)
        // Character count alone does not bound UTF-8 or the encoded file size.
        let name = "a" + String(repeating: "\u{0301}", count: MouseDPIProfileExport.maximumDataBytes)
        #expect(name.count == 1)
        #expect(throws: ProfileLibraryError.fileTooLarge) { try service.create(name: name, target: .viperV4ProDPI, x: 800, y: 800) }
        #expect(service.profiles.count == 1)
        #expect(try Data(contentsOf: url) == before)
    }

    #if DEBUG
    @Test func offlineOperationsAndEditorSelectionNeverInvokeADeviceService() async throws {
        let session = try OfflineScenarioSession()
        await session.load(.twinMice)
        let calls = await session.services.operations
        let profile = try session.profiles.create(name: "离线创建", target: .viperV4ProDPI, x: 1600, y: 1800)
        let edited = try session.profiles.update(profile, name: "离线编辑", x: 2000, y: 2200)
        _ = try session.profiles.duplicate(edited)
        try session.profiles.select(edited, for: session.manager.devices[1])
        #expect(session.profiles.selectedProfile(for: session.manager.devices[1])?.x == 2000)
        #expect(session.manager.pendingDPIChanges.isEmpty)
        #expect(await session.services.operations == calls)
        session.disconnect()
        #expect(session.profiles.profiles.contains { $0.id == profile.id })
        #expect(session.manager.devices.isEmpty)
    }
    #endif
}
