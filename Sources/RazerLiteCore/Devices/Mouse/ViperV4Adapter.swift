import Foundation

enum ViperV4Adapter {
    static func controlInterface(in device: DeviceInfo) -> HIDInterface? {
        AdapterManifestCatalog.viper.controlInterface(in: device)
    }

    static func isSameInterface(_ current: HIDInterface, expected: HIDInterface) -> Bool {
        current.matchesSession(expected)
    }
}
