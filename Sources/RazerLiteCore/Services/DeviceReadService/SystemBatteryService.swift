import Foundation
import IOKit
import CoreFoundation

public enum SystemBatterySource: String, Codable, Sendable {
    case hidRegistry
    case macOSBluetoothSnapshot

    public var title: String {
        switch self {
        case .hidRegistry: "macOS HID 属性"
        case .macOSBluetoothSnapshot: "macOS 蓝牙系统快照"
        }
    }
}

/// Values reported by macOS, not a direct device measurement. No Bluetooth address is retained here.
public struct SystemBatteryReading: Codable, Equatable, Sendable {
    public let deviceID: String
    public let interfaceIDs: [UInt64]
    public let acquiredAt: Date
    /// A validated macOS-reported value. Nil is unknown, never a device power-state claim.
    public let percent: Int?
    /// The successful value's stable origin. It is never used to describe a failure.
    public let source: SystemBatterySource?
    /// Existing human-readable diagnostic text.
    public let issue: String?
    /// Stable category for an unsuccessful read; nil keeps older export compatibility.
    public let failureKind: ReadFailureKind?

    public init(deviceID: String, interfaceIDs: [UInt64], acquiredAt: Date,
                percent: Int?, source: SystemBatterySource?, issue: String?,
                failureKind: ReadFailureKind? = nil) {
        self.deviceID = deviceID
        self.interfaceIDs = interfaceIDs
        self.acquiredAt = acquiredAt
        self.percent = percent
        self.source = source
        self.issue = issue
        self.failureKind = failureKind
    }

    public func matches(_ device: DeviceInfo) -> Bool {
        deviceID == device.id && interfaceIDs == device.interfaces.map(\.id).sorted()
            && SystemBatteryService.canRead(device)
    }
}

public protocol SystemBatteryReadingService: Sendable {
    func read(_ device: DeviceInfo) async -> SystemBatteryReading
}

enum SystemBatteryError: LocalizedError {
    case unavailable, deviceChanged, missingAddress, invalidSnapshot, disconnected, ambiguous, identityMismatch, noBattery
    var errorDescription: String? {
        switch self {
        case .unavailable: "此连接没有系统蓝牙电量读取后端。"
        case .deviceChanged: "HID 接口已断开或身份发生变化，请刷新设备后重试。"
        case .missingAddress: "系统未提供可用于精确关联的蓝牙地址；未按设备名称猜测电量。"
        case .invalidSnapshot: "无法识别 macOS 蓝牙系统快照格式。"
        case .disconnected: "系统快照中没有这台已连接设备，请刷新连接状态后重试。"
        case .ambiguous: "系统返回多个匹配项或冲突的电量，未采用其中任意一个。"
        case .identityMismatch: "系统快照与 HID 的 VID/PID 不一致，已停止关联。"
        case .noBattery: "系统未发布此设备的电量。标准蓝牙服务或厂商查询仍需独立验证。"
        }
    }
}

struct SystemBatteryTarget: Sendable {
    let address: String?
    let registryPercent: Int?
}

protocol SystemBatteryTargetResolving: Sendable {
    func resolve(_ device: DeviceInfo) throws -> SystemBatteryTarget
}

struct HIDSystemBatteryResolver: SystemBatteryTargetResolving {
    func resolve(_ device: DeviceInfo) throws -> SystemBatteryTarget {
        guard SystemBatteryService.canRead(device) else { throw SystemBatteryError.unavailable }
        var addresses = Set<String>()
        var percentages = Set<Int>()
        for interface in device.interfaces {
            let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(interface.id))
            guard entry != 0 else { throw SystemBatteryError.deviceChanged }
            defer { IOObjectRelease(entry) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard (property("VendorID") as? NSNumber)?.intValue == interface.vendorID,
                  (property("ProductID") as? NSNumber)?.intValue == interface.productID,
                  property("Transport") as? String == interface.transport,
                  property("Product") as? String == interface.product else { throw SystemBatteryError.deviceChanged }
            // Observed OS properties; absence is normal. Do not traverse unrelated registry nodes.
            if let raw = property("DeviceAddress") as? String, let address = BluetoothBatterySnapshot.address(raw) {
                addresses.insert(address)
            }
            if let number = property("BatteryPercent") as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID(),
               number.doubleValue == Double(number.intValue), (0...100).contains(number.intValue) {
                percentages.insert(number.intValue)
            }
        }
        guard addresses.count <= 1, percentages.count <= 1 else { throw SystemBatteryError.ambiguous }
        return SystemBatteryTarget(address: addresses.first, registryPercent: percentages.first)
    }
}

enum BluetoothBatterySnapshot {
    static func address(_ raw: String) -> String? {
        let compact = raw.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
        guard compact.utf8.count == 12, compact.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { return nil }
        return compact
    }

    static func percent(_ data: Data, address target: String, vendorID: Int?, productID: Int?) throws -> Int {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]],
              !sections.isEmpty else { throw SystemBatteryError.invalidSnapshot }
        var matches: [[String: Any]] = []
        for section in sections {
            guard let value = section["device_connected"] else { continue }
            guard let devices = value as? [[String: [String: Any]]] else { throw SystemBatteryError.invalidSnapshot }
            for device in devices {
                for fields in device.values {
                    if let raw = fields["device_address"] as? String, address(raw) == target { matches.append(fields) }
                }
            }
        }
        guard !matches.isEmpty else { throw SystemBatteryError.disconnected }
        guard matches.count == 1, let fields = matches.first else { throw SystemBatteryError.ambiguous }
        func hex(_ value: Any?) -> Int? {
            guard let value = value as? String, value.lowercased().hasPrefix("0x") else { return nil }
            return Int(value.dropFirst(2), radix: 16)
        }
        guard let vendorID, let productID,
              hex(fields["device_vendorID"]) == vendorID, hex(fields["device_productID"]) == productID else {
            throw SystemBatteryError.identityMismatch
        }
        guard let raw = fields["device_batteryLevelMain"] as? String, raw.hasSuffix("%") else { throw SystemBatteryError.noBattery }
        let digits = raw.dropLast()
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(digits), (0...100).contains(value) else { throw SystemBatteryError.noBattery }
        return value
    }
}

/// Explicit OS metadata reads only: no HID reports, Bluetooth scanning, private API or polling timer.
public struct SystemBatteryService: SystemBatteryReadingService {
    private let resolver: any SystemBatteryTargetResolving
    private let loader: any BluetoothSnapshotLoading

    public init() { resolver = HIDSystemBatteryResolver(); loader = SystemProfilerSnapshotLoader() }
    init(resolver: any SystemBatteryTargetResolving, loader: any BluetoothSnapshotLoading) {
        self.resolver = resolver; self.loader = loader
    }
    public static func canRead(_ device: DeviceInfo) -> Bool {
        DeviceReadRegistry.backends(for: device).contains(.macOSBluetoothBattery)
    }

    static func failureKind(for error: any Error) -> ReadFailureKind { ReadFailureClassifier.classify(error) }

    public func read(_ device: DeviceInfo) async -> SystemBatteryReading {
        var value: Int?
        var source: SystemBatterySource?
        var issue: String?
        var failureKind: ReadFailureKind?
        do {
            try Task.checkCancellation()
            let target = try resolver.resolve(device)
            if let percent = target.registryPercent {
                value = percent; source = .hidRegistry
            } else {
                guard let address = target.address else { throw SystemBatteryError.missingAddress }
                let data = try await loader.load()
                try Task.checkCancellation()
                value = try BluetoothBatterySnapshot.percent(data, address: address, vendorID: device.vendorID, productID: device.productID)
                // A disconnected/replaced interface must not receive an earlier OS snapshot.
                let current = try resolver.resolve(device)
                guard current.address == address else { throw SystemBatteryError.deviceChanged }
                source = .macOSBluetoothSnapshot
            }
        } catch {
            value = nil
            source = nil
            issue = error.localizedDescription
            failureKind = Self.failureKind(for: error)
        }
        return SystemBatteryReading(deviceID: device.id, interfaceIDs: device.interfaces.map(\.id).sorted(),
                                    acquiredAt: Date(), percent: value, source: source, issue: issue, failureKind: failureKind)
    }
}
