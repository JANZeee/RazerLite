import Foundation

/// Exact route for manual brightness reads and explicitly confirmed single writes.
/// Product identity and interface 3 are reviewed against the official 756/757 DualLink bundle;
/// the macOS HID shape is from the local 02F5 observation. No adjacent PID inherits this route.
enum ReclusaLightingAdapter {
    static func controlInterface(in device: DeviceInfo) -> HIDInterface? {
        guard device.isRazer, !device.isVirtual, !device.interfaces.isEmpty,
              let usbDeviceID = device.interfaces.first?.usbDeviceID,
              device.interfaces.allSatisfy({
                  !$0.isVirtual && $0.vendorID == 0x1532 && $0.productID == 0x02F5 && $0.transport == "USB"
                      && $0.usbDeviceID == usbDeviceID
                      && $0.product.trimmingCharacters(in: .whitespacesAndNewlines)
                          .caseInsensitiveCompare("Razer Reclusa Mini 65%") == .orderedSame
              }),
              device.interfaces.contains(where: {
                  ($0.primaryUsagePage == 1 && $0.primaryUsage == 6)
                      || $0.usages.contains(HIDUsage(page: 1, usage: 6))
              }) else { return nil }
        let candidates = device.interfaces.filter {
            $0.usbDeviceID != nil && $0.usbInterfaceNumber == 3
                && $0.primaryUsagePage == 0x0C && $0.primaryUsage == 1
                && $0.maxInputReportSize == 0 && $0.maxOutputReportSize == 0 && $0.maxFeatureReportSize == 90
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
