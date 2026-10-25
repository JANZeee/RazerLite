import Foundation

/// Exact 02D2 USB receiver route reviewed against PR #2912 and the saved local HID snapshot.
enum BlackWidowLowProfileAdapter {
    static func controlInterface(in device: DeviceInfo) -> HIDInterface? {
        AdapterManifestCatalog.keyboard.controlInterface(in: device)
    }
}
