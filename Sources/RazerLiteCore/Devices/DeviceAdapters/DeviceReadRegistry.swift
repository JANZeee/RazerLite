import Foundation

public enum DeviceReadBackend: String, Codable, Sendable {
    case macOSBluetoothBattery
    case viperV4USB
    case blackWidowLowProfileUSB
}

/// Executable read backends only. A name in RazerModelCatalog never enables a backend.
/// Transport and interface conditions remain separate from product presentation.
public enum DeviceReadRegistry {
    public static func backends(for device: DeviceInfo) -> [DeviceReadBackend] {
        guard device.isRazer, !device.isVirtual else { return [] }
        var result: [DeviceReadBackend] = []
        if AdapterManifestCatalog.manifest(for: device)?.id == DeviceReadBackend.macOSBluetoothBattery.rawValue {
            result.append(.macOSBluetoothBattery)
        }
        if ViperV4Adapter.controlInterface(in: device) != nil { result.append(.viperV4USB) }
        if BlackWidowLowProfileAdapter.controlInterface(in: device) != nil { result.append(.blackWidowLowProfileUSB) }
        return result
    }
}
