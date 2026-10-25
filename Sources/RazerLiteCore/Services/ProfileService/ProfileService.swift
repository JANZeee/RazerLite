import Combine
import Foundation

/// A stable, deliberately narrow target for a local profile. It never contains a
/// registry ID, USB parent ID, serial number, or other session identity.
public struct ProfileDeviceTarget: Codable, Equatable, Hashable, Sendable {
    public static var viperV4ProDPI: Self { Self() }
    public var displayName: String { "Viper V4 Pro · USB" }

    private init() {
        kind = .viperV4ProDPI
        vendorID = 0x1532
        productID = 0x00E6
        transport = "USB"
    }
    public enum Kind: String, Codable, Sendable {
        case viperV4ProDPI = "viper-v4-pro-dpi"
    }

    public let kind: Kind
    public let vendorID: Int
    public let productID: Int
    public let transport: String

    public init(kind: Kind, vendorID: Int, productID: Int, transport: String) throws {
        guard vendorID == 0x1532, productID == 0x00E6, transport == "USB", kind == .viperV4ProDPI else {
            throw ProfileLibraryError.unsupportedTarget
        }
        self.kind = kind
        self.vendorID = vendorID
        self.productID = productID
        self.transport = transport
    }

    public init?(device: DeviceInfo) {
        guard !device.isVirtual, device.vendorID == 0x1532, device.productID == 0x00E6, device.transport == "USB" else {
            return nil
        }
        // A DPI profile is only offered where the same strict control-interface
        // matcher used by the query/write services accepts the current session.
        guard MouseReadService.canRead(device) else { return nil }
        do {
            try self.init(kind: .viperV4ProDPI, vendorID: 0x1532, productID: 0x00E6, transport: "USB")
        } catch { return nil }
    }

    private enum CodingKeys: String, CodingKey { case kind, vendorID, productID, transport }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(kind: container.decode(Kind.self, forKey: .kind),
                      vendorID: container.decode(Int.self, forKey: .vendorID),
                      productID: container.decode(Int.self, forKey: .productID),
                      transport: container.decode(String.self, forKey: .transport))
    }

    public var storageKey: String { "\(kind.rawValue):\(vendorID):\(productID):\(transport)" }

    public func matches(_ device: DeviceInfo) -> Bool {
        !device.isVirtual && device.vendorID == vendorID && device.productID == productID && device.transport == transport
            && ProfileDeviceTarget(device: device) == self
    }
}

/// A local DPI preset. Selecting it never sends a HID report; it merely makes a
/// target available to the editor, which still requires its normal review and
/// explicit device-write confirmation.
public struct MouseDPIProfile: Codable, Equatable, Identifiable, Sendable {
    public static let maximumNameLength = 48
    public let id: UUID
    public let name: String
    public let target: ProfileDeviceTarget
    public let x: Int
    public let y: Int
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: UUID = UUID(), name: String, target: ProfileDeviceTarget, x: Int, y: Int,
                createdAt: Date = Date(), updatedAt: Date = Date()) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maximumNameLength, trimmed.rangeOfCharacter(from: .newlines) == nil else {
            throw ProfileLibraryError.invalidName
        }
        guard (100...50000).contains(x), (100...50000).contains(y), x % 50 == 0, y % 50 == 0 else {
            throw ProfileLibraryError.invalidDPI
        }
        self.id = id
        self.name = trimmed
        self.target = target
        self.x = x
        self.y = y
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, name, target, x, y, createdAt, updatedAt }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: container.decode(UUID.self, forKey: .id),
                      name: container.decode(String.self, forKey: .name),
                      target: container.decode(ProfileDeviceTarget.self, forKey: .target),
                      x: container.decode(Int.self, forKey: .x), y: container.decode(Int.self, forKey: .y),
                      createdAt: container.decode(Date.self, forKey: .createdAt),
                      updatedAt: container.decode(Date.self, forKey: .updatedAt))
    }
}

public struct MouseDPIProfileExport: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumDataBytes = 1_048_576
    public let schemaVersion: Int
    public let exportedAt: Date
    public let profiles: [MouseDPIProfile]

    public init(profiles: [MouseDPIProfile], exportedAt: Date = Date()) throws {
        guard profiles.count <= ProfileLibrary.maximumProfiles else { throw ProfileLibraryError.tooManyProfiles }
        try ProfileLibrary.validate(profiles: profiles)
        self.schemaVersion = Self.schemaVersion
        self.exportedAt = exportedAt
        self.profiles = profiles
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumDataBytes else { throw ProfileLibraryError.fileTooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> MouseDPIProfileExport {
        guard data.count <= maximumDataBytes else { throw ProfileLibraryError.fileTooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(Self.self, from: data)
        guard value.schemaVersion == Self.schemaVersion else { throw ProfileLibraryError.unsupportedSchema(value.schemaVersion) }
        guard value.profiles.count <= ProfileLibrary.maximumProfiles else { throw ProfileLibraryError.tooManyProfiles }
        try ProfileLibrary.validate(profiles: value.profiles)
        return value
    }
}

public struct ProfileImportSummary: Equatable, Sendable {
    public let added: Int
    public let skipped: Int
    public let conflicts: Int
    public init(added: Int, skipped: Int, conflicts: Int = 0) {
        self.added = added
        self.skipped = skipped
        self.conflicts = conflicts
    }
}

public enum ProfileLibraryError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedTarget
    case invalidName
    case invalidDPI
    case unsupportedSchema(Int)
    case duplicateIdentifier
    case tooManyProfiles
    case profileNotFound
    case profileDoesNotMatchDevice
    case malformedSelection
    case profileChanged
    case fileTooLarge
    case invalidImportFile
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedTarget: "该设备或连接方式尚不支持本地 DPI 档案。"
        case .invalidName: "档案名称不能为空、不能换行，且最多 48 个字符。"
        case .invalidDPI: "档案 DPI 必须在 100–50000 之间，且为 50 的整数倍。"
        case let .unsupportedSchema(version): "不支持的档案格式版本 \(version)。"
        case .duplicateIdentifier: "档案中包含重复标识。"
        case .tooManyProfiles: "档案数量超过此版本的安全上限。"
        case .profileNotFound: "找不到所选档案。"
        case .profileDoesNotMatchDevice: "该档案不适用于当前设备或连接方式。"
        case .malformedSelection: "档案的已选状态与设备目标不一致。"
        case .profileChanged: "此预设已被修改，请关闭当前操作并重新打开。"
        case .fileTooLarge: "档案文件超过 1 MiB，未载入。"
        case .invalidImportFile: "请选择本机可读取的普通 JSON 文件。"
        case let .storage(message): "本地档案存储失败：\(message)"
        }
    }
}

/// Codable payload for Application Support. Kept separate from export files so
/// importing can never overwrite a user's local selected-profile state.
struct ProfileLibrary: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumProfiles = 128
    var schemaVersion: Int = Self.schemaVersion
    var profiles: [MouseDPIProfile] = []
    var selectedProfileIDs: [String: UUID] = [:]

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        profiles = try container.decode([MouseDPIProfile].self, forKey: .profiles)
        selectedProfileIDs = try container.decodeIfPresent([String: UUID].self, forKey: .selectedProfileIDs) ?? [:]
        guard schemaVersion == Self.schemaVersion else { throw ProfileLibraryError.unsupportedSchema(schemaVersion) }
        guard profiles.count <= Self.maximumProfiles else { throw ProfileLibraryError.tooManyProfiles }
        try Self.validate(profiles: profiles)
        for (key, id) in selectedProfileIDs {
            guard let profile = profiles.first(where: { $0.id == id }), profile.target.storageKey == key else {
                throw ProfileLibraryError.malformedSelection
            }
        }
    }

    static func validate(profiles: [MouseDPIProfile]) throws {
        guard Set(profiles.map(\.id)).count == profiles.count else { throw ProfileLibraryError.duplicateIdentifier }
        for profile in profiles {
            _ = try MouseDPIProfile(id: profile.id, name: profile.name, target: profile.target, x: profile.x, y: profile.y,
                                    createdAt: profile.createdAt, updatedAt: profile.updatedAt)
        }
    }
}

/// Local-only profile library. It observes no HID input, performs no network
/// requests, and deliberately has no automatic device-apply path.
@MainActor
public final class ProfileService: ObservableObject {
    @Published public private(set) var profiles: [MouseDPIProfile] = []
    @Published public private(set) var selectedProfileIDs: [String: UUID] = [:]
    @Published public private(set) var lastError: String?
    public let storageURL: URL

    private var library = ProfileLibrary()
    private let fileManager: FileManager
    private var storageIsUsable = true
    public var canModify: Bool { storageIsUsable }

    public init(storageURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.storageURL = storageURL ?? Self.defaultStorageURL(fileManager: fileManager)
        load()
    }

    public func profiles(for device: DeviceInfo) -> [MouseDPIProfile] {
        profiles.filter { $0.target.matches(device) }
    }

    public func selectedProfile(for device: DeviceInfo) -> MouseDPIProfile? {
        guard let target = ProfileDeviceTarget(device: device), let id = selectedProfileIDs[target.storageKey] else { return nil }
        return profiles.first { $0.id == id && $0.target == target }
    }

    @discardableResult
    public func save(name: String, for device: DeviceInfo, x: Int, y: Int) throws -> MouseDPIProfile {
        guard let target = ProfileDeviceTarget(device: device) else { throw ProfileLibraryError.unsupportedTarget }
        return try create(name: name, target: target, x: x, y: y, selectLocally: true)
    }

    /// An offline target value, never a claim about any connected device's state.
    @discardableResult
    public func create(name: String, target: ProfileDeviceTarget, x: Int, y: Int) throws -> MouseDPIProfile {
        try create(name: name, target: target, x: x, y: y, selectLocally: false)
    }

    private func create(name: String, target: ProfileDeviceTarget, x: Int, y: Int, selectLocally: Bool) throws -> MouseDPIProfile {
        let profile = try MouseDPIProfile(name: name, target: target, x: x, y: y)
        var candidate = library
        guard candidate.profiles.count < ProfileLibrary.maximumProfiles else { throw ProfileLibraryError.tooManyProfiles }
        candidate.profiles.append(profile)
        if selectLocally { candidate.selectedProfileIDs[target.storageKey] = profile.id }
        try commit(candidate)
        return profile
    }

    @discardableResult
    public func update(_ profile: MouseDPIProfile, name: String, x: Int, y: Int) throws -> MouseDPIProfile {
        let index = try currentIndex(for: profile)
        let updated = try MouseDPIProfile(id: profile.id, name: name, target: profile.target, x: x, y: y,
            createdAt: library.profiles[index].createdAt, updatedAt: Date())
        var candidate = library
        candidate.profiles[index] = updated
        try commit(candidate)
        return updated
    }

    @discardableResult
    public func duplicate(_ profile: MouseDPIProfile) throws -> MouseDPIProfile {
        _ = try currentIndex(for: profile)
        var suffix = " 副本"
        var number = 2
        let names = Set(library.profiles.map(\.name))
        while names.contains(String(profile.name.prefix(MouseDPIProfile.maximumNameLength - suffix.count)) + suffix) {
            suffix = " 副本 \(number)"
            number += 1
        }
        let name = String(profile.name.prefix(MouseDPIProfile.maximumNameLength - suffix.count)) + suffix
        return try create(name: name, target: profile.target, x: profile.x, y: profile.y)
    }

    private func currentIndex(for profile: MouseDPIProfile) throws -> Int {
        guard let index = library.profiles.firstIndex(where: { $0.id == profile.id }) else { throw ProfileLibraryError.profileNotFound }
        let current = library.profiles[index]
        guard current.name == profile.name, current.target == profile.target, current.x == profile.x, current.y == profile.y else {
            throw ProfileLibraryError.profileChanged
        }
        return index
    }

    public func select(_ profile: MouseDPIProfile, for device: DeviceInfo) throws {
        guard profile.target.matches(device) else { throw ProfileLibraryError.profileDoesNotMatchDevice }
        var candidate = library
        _ = try currentIndex(for: profile)
        candidate.selectedProfileIDs[profile.target.storageKey] = profile.id
        try commit(candidate)
    }

    public func delete(_ profile: MouseDPIProfile) throws {
        var candidate = library
        _ = try currentIndex(for: profile)
        candidate.profiles.removeAll { $0.id == profile.id }
        candidate.selectedProfileIDs = candidate.selectedProfileIDs.filter { $0.value != profile.id }
        try commit(candidate)
    }

    public func exportData(for profiles: [MouseDPIProfile]) throws -> Data {
        try MouseDPIProfileExport(profiles: profiles).jsonData()
    }

    @discardableResult
    public func importData(_ data: Data) throws -> ProfileImportSummary {
        let (candidate, summary) = try mergedImport(data)
        // Even a no-op import must not hide an unusable local library.
        guard storageIsUsable else { throw ProfileLibraryError.storage("现有档案未通过校验，已保留原文件。") }
        if summary.added > 0 { try commit(candidate) }
        return summary
    }

    /// Validation and conflict analysis only; neither files nor selection change.
    public func previewImport(_ data: Data) throws -> ProfileImportSummary {
        try mergedImport(data).1
    }

    /// Read at most the configured limit + 1 byte, before decoding a user-selected file.
    public static func readImportFile(_ url: URL) throws -> Data {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ProfileLibraryError.invalidImportFile
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = MouseDPIProfileExport.maximumDataBytes
        var data = Data()
        while data.count <= limit {
            guard let chunk = try handle.read(upToCount: min(65_536, limit + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= limit else { throw ProfileLibraryError.fileTooLarge }
        return data
    }

    private func mergedImport(_ data: Data) throws -> (ProfileLibrary, ProfileImportSummary) {
        let imported = try MouseDPIProfileExport.decode(data)
        var candidate = library
        var added = 0
        var skipped = 0
        var conflicts = 0
        for profile in imported.profiles {
            if candidate.profiles.contains(where: { $0.target == profile.target && $0.name == profile.name && $0.x == profile.x && $0.y == profile.y }) {
                skipped += 1
                continue
            }
            guard candidate.profiles.count < ProfileLibrary.maximumProfiles else { throw ProfileLibraryError.tooManyProfiles }
            let conflict = candidate.profiles.contains(where: { $0.id == profile.id })
            if conflict { conflicts += 1 }
            let id = conflict ? UUID() : profile.id
            candidate.profiles.append(try MouseDPIProfile(id: id, name: profile.name, target: profile.target, x: profile.x, y: profile.y,
                                                          createdAt: profile.createdAt, updatedAt: Date()))
            added += 1
        }
        return (candidate, ProfileImportSummary(added: added, skipped: skipped, conflicts: conflicts))
    }

    public func clearError() { lastError = nil }

    private func load() {
        guard fileManager.fileExists(atPath: storageURL.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = try decoder.decode(ProfileLibrary.self, from: Self.readImportFile(storageURL))
            library = loaded
            publish()
        } catch {
            storageIsUsable = false
            lastError = "本地档案未加载：\(error.localizedDescription)"
        }
    }

    private func commit(_ candidate: ProfileLibrary) throws {
        do {
            guard storageIsUsable else {
                throw ProfileLibraryError.storage("现有档案文件未通过校验，已保留原文件；请先修复或移走它。")
            }
            try ProfileLibrary.validate(profiles: candidate.profiles)
            let directory = storageURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(candidate)
            guard data.count <= MouseDPIProfileExport.maximumDataBytes else { throw ProfileLibraryError.fileTooLarge }
            try data.write(to: storageURL, options: .atomic)
            library = candidate
            publish()
        } catch {
            let wrapped = error as? ProfileLibraryError ?? .storage(error.localizedDescription)
            lastError = wrapped.localizedDescription
            throw wrapped
        }
    }

    private func publish() {
        profiles = library.profiles
        selectedProfileIDs = library.selectedProfileIDs
        lastError = nil
    }

    private static func defaultStorageURL(fileManager: FileManager) -> URL {
        let directory = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: false))
            ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "/tmp", isDirectory: true)
        return directory.appendingPathComponent("RazerLite", isDirectory: true).appendingPathComponent("profiles.json")
    }
}
