import Foundation

public struct HIDUsage: Codable, Hashable, Sendable {
    public let page: Int
    public let usage: Int
}

/// A session identity, not a persistent profile identifier. No input data is stored.
public struct HIDInterface: Codable, Equatable, Identifiable, Sendable {
    public let id: UInt64
    public let vendorID: Int?
    public let productID: Int?
    public let product: String
    public let manufacturer: String?
    public let transport: String?
    public let locationID: Int?
    public let versionNumber: Int?
    public let usbDeviceID: UInt64?
    public let usbInterfaceNumber: Int?
    public let usbDeviceRelease: Int?
    public let primaryUsagePage: Int?
    public let primaryUsage: Int?
    public let usages: [HIDUsage]
    public let maxInputReportSize: Int?
    public let maxOutputReportSize: Int?
    public let maxFeatureReportSize: Int?
    public let registryClass: String
    public let observedDrivers: [String]
    public let isVirtual: Bool

    /// 068E is Razer's Bluetooth SIG identifier, not its USB VID.
    /// Keep the transport qualifier: USB 068E belongs to a different vendor.
    public var isRazer: Bool {
        vendorID == 0x1532 || (vendorID == 0x068E && transport?.hasPrefix("Bluetooth") == true)
    }
    public var groupID: String {
        // Only a shared USB ancestor proves that interfaces belong to one device.
        // Missing identities stay separate, including devices with zero serial/location.
        if !isVirtual, let usbDeviceID { return "usb-\(usbDeviceID)" }
        return "hid-\(id)"
    }
}

public struct DeviceInfo: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let interfaces: [HIDInterface]

    public var product: String { interfaces.first?.product ?? "未知设备" }
    public var vendorID: Int? { interfaces.first?.vendorID }
    public var productID: Int? { interfaces.first?.productID }
    public var transport: String { interfaces.first?.transport ?? "未知" }
    public var isVirtual: Bool { interfaces.contains(where: \.isVirtual) }
    public var isRazer: Bool { interfaces.contains(where: \.isRazer) }
    public var observedDrivers: [String] { Array(Set(interfaces.flatMap(\.observedDrivers))).sorted() }

    public var modelReference: RazerModelReference? {
        guard !isVirtual else { return nil }
        return RazerModelCatalog.lookup(vendorID: vendorID, productID: productID)
    }

    /// Presentation classification only. Never used to select a private command.
    public var kind: RazerDeviceKind {
        guard !isVirtual else { return .unknown }
        if vendorID == 0x1532, productID == 0x00E6 { return .mouse }
        if vendorID == 0x1532, productID == 0x02D2 { return .keyboard }
        if let modelReference { return modelReference.kind }
        // A BLE mouse may also expose keyboard usages for its extra buttons.
        if !interfaces.isEmpty, interfaces.allSatisfy({ $0.primaryUsagePage == 1 && $0.primaryUsage == 2 }) { return .mouse }
        if !interfaces.isEmpty, interfaces.allSatisfy({ $0.primaryUsagePage == 1 && $0.primaryUsage == 6 }) { return .keyboard }
        let collections = interfaces.flatMap { item in
            item.usages + [HIDUsage(page: item.primaryUsagePage ?? -1, usage: item.primaryUsage ?? -1)]
        }
        let mouse = collections.contains { $0.page == 1 && $0.usage == 2 }
        let keyboard = collections.contains { $0.page == 1 && $0.usage == 6 }
        // Composite receivers can expose both; do not guess from interface order.
        if mouse && !keyboard { return .mouse }
        if keyboard && !mouse { return .keyboard }
        return .unknown
    }

    public static func group(_ interfaces: [HIDInterface]) -> [DeviceInfo] {
        Dictionary(grouping: interfaces, by: \.groupID).map { key, values in
            DeviceInfo(id: key, interfaces: values.sorted {
                ($0.usbInterfaceNumber ?? Int.max, $0.id) < ($1.usbInterfaceNumber ?? Int.max, $1.id)
            })
        }.sorted {
            if $0.isVirtual != $1.isVirtual { return !$0.isVirtual }
            if $0.product != $1.product { return $0.product < $1.product }
            return $0.id < $1.id
        }
    }
}

public func hexID(_ value: Int?, width: Int = 4) -> String {
    guard let value else { return "未知" }
    return String(format: "0x%0*llX", width, Int64(value))
}
