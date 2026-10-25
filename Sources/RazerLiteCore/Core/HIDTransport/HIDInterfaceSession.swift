import Foundation

extension HIDInterface {
    /// Session fingerprint shared by transports; it grants no model-specific protocol capability.
    func matchesSession(_ expected: HIDInterface) -> Bool {
        id == expected.id && usbDeviceID == expected.usbDeviceID
            && vendorID == expected.vendorID && productID == expected.productID
            && transport == expected.transport && usbInterfaceNumber == expected.usbInterfaceNumber
            && primaryUsagePage == expected.primaryUsagePage && primaryUsage == expected.primaryUsage
            && maxFeatureReportSize == expected.maxFeatureReportSize
            && maxInputReportSize == expected.maxInputReportSize && maxOutputReportSize == expected.maxOutputReportSize
            && versionNumber == expected.versionNumber && usbDeviceRelease == expected.usbDeviceRelease
            && locationID == expected.locationID && registryClass == expected.registryClass && usages == expected.usages
            && !isVirtual && !expected.isVirtual
    }
}
