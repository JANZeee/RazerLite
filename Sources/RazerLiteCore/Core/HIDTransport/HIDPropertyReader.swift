import Foundation
import IOKit
import IOKit.hid

enum HIDPropertyReader {
    static func read(_ device: IOHIDDevice) -> HIDInterface? {
        let service = IOHIDDeviceGetService(device)
        guard service != 0, let id = registryID(service) else { return nil }
        func number(_ key: String) -> Int? { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue }
        func string(_ key: String) -> String? { IOHIDDeviceGetProperty(device, key as CFString) as? String }
        let ancestors = usbAncestors(service)
        let product = string(kIOHIDProductKey) ?? "未命名 HID 设备"
        let className = registryClass(service)
        let virtual = className.localizedCaseInsensitiveContains("virtual")
            || product.localizedCaseInsensitiveContains("virtual")
        let usages = (IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] ?? [])
            .compactMap { pair -> HIDUsage? in
                guard let page = pair[kIOHIDDeviceUsagePageKey] as? Int,
                      let usage = pair[kIOHIDDeviceUsageKey] as? Int else { return nil }
                return HIDUsage(page: page, usage: usage)
            }
        let drivers = driverNames(service)
        return HIDInterface(id: id, vendorID: number(kIOHIDVendorIDKey), productID: number(kIOHIDProductIDKey),
                            product: product, manufacturer: string(kIOHIDManufacturerKey), transport: string(kIOHIDTransportKey),
                            locationID: number(kIOHIDLocationIDKey), versionNumber: number(kIOHIDVersionNumberKey),
                            usbDeviceID: ancestors.deviceID, usbInterfaceNumber: ancestors.interfaceNumber,
                            usbDeviceRelease: ancestors.release, primaryUsagePage: number(kIOHIDPrimaryUsagePageKey),
                            primaryUsage: number(kIOHIDPrimaryUsageKey), usages: usages,
                            maxInputReportSize: number(kIOHIDMaxInputReportSizeKey),
                            maxOutputReportSize: number(kIOHIDMaxOutputReportSizeKey),
                            maxFeatureReportSize: number(kIOHIDMaxFeatureReportSizeKey), registryClass: className,
                            observedDrivers: drivers, isVirtual: virtual)
    }

    static func registryID(_ service: io_registry_entry_t) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS ? id : nil
    }

    private static func registryClass(_ service: io_registry_entry_t) -> String {
        IOObjectCopyClass(service)?.takeRetainedValue() as String? ?? "未知"
    }

    private static func property(_ service: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func usbAncestors(_ service: io_registry_entry_t) -> (deviceID: UInt64?, interfaceNumber: Int?, release: Int?) {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        var interfaceNumber: Int?
        // Bounded traversal with a matching release for every acquired registry object.
        for _ in 0..<16 {
            if IOObjectConformsTo(current, "IOUSBHostInterface") != 0 {
                interfaceNumber = (property(current, "bInterfaceNumber") as? NSNumber)?.intValue
            }
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 {
                return (registryID(current), interfaceNumber, (property(current, "bcdDevice") as? NSNumber)?.intValue)
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(current)
            current = parent
        }
        return (nil, interfaceNumber, nil)
    }

    private static func driverNames(_ service: io_registry_entry_t) -> [String] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result = Set<String>()
        while case let child = IOIteratorNext(iterator), child != 0 {
            if let userClass = property(child, "IOUserClass") as? String, userClass.localizedCaseInsensitiveContains("razer") {
                result.insert(userClass)
            }
            if let bundle = property(child, "CFBundleIdentifier") as? String, bundle.localizedCaseInsensitiveContains("razer") {
                result.insert(bundle)
            }
            IOObjectRelease(child)
        }
        return result.sorted()
    }
}
