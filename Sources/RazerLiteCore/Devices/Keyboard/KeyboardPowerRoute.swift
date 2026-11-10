import Foundation

/// Only routes with independently reviewed battery and charging commands are eligible.
/// Sharing a framing envelope or a lighting route alone does not grant a power backend.
enum KeyboardPowerRoute {
    case blackWidow(HIDInterface)
    case reclusa(HIDInterface)

    static func resolve(_ device: DeviceInfo) -> Self? {
        if let interface = BlackWidowLowProfileAdapter.controlInterface(in: device) {
            return .blackWidow(interface)
        }
        if let interface = ReclusaLightingAdapter.controlInterface(in: device) {
            return .reclusa(interface)
        }
        return nil
    }

    var interface: HIDInterface {
        switch self {
        case let .blackWidow(interface), let .reclusa(interface): return interface
        }
    }

    var backend: DeviceReadBackend {
        switch self {
        case .blackWidow: return .blackWidowLowProfileUSB
        case .reclusa: return .reclusaMini65USB
        }
    }
}
