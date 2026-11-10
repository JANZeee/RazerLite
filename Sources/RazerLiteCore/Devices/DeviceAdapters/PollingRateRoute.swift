import Foundation

/// Exact-model route shared by polling reads and confirmed writes. A PID alone never selects a route.
enum PollingRateRoute: Sendable {
    case viperV4
    case reclusaReceiver

    static func resolve(_ device: DeviceInfo) -> (route: Self, interface: HIDInterface)? {
        if let interface = ViperV4Adapter.controlInterface(in: device) {
            return (.viperV4, interface)
        }
        if let interface = ReclusaLightingAdapter.controlInterface(in: device) {
            return (.reclusaReceiver, interface)
        }
        return nil
    }

    var supportedRates: [Int] {
        switch self {
        case .viperV4: ViperV4PollingWriteProtocol.rates
        case .reclusaReceiver: ReclusaPollingProtocol.writableRates
        }
    }

    func validateTarget(_ hertz: Int) throws {
        switch self {
        case .viperV4: _ = try ViperV4PollingWriteProtocol.code(for: hertz)
        case .reclusaReceiver: _ = try ReclusaPollingProtocol.writableCode(for: hertz)
        }
    }

    func read(_ transport: any HIDFeatureTransport, transaction: UInt8 = 0x80,
              wait: @escaping @Sendable () -> Void) throws -> Int {
        switch self {
        case .viperV4:
            return try ViperV4ReadProtocol.pollingRate(ViperV4ControlClient(transport: transport).query(.pollingRate))
        case .reclusaReceiver:
            return try ReclusaPollingClient(transport: transport, wait: wait).pollingRate(transaction: transaction)
        }
    }

    func set(_ hertz: Int, transport: any HIDFeatureTransport, wait: @escaping @Sendable () -> Void) throws {
        switch self {
        case .viperV4: try ViperV4ControlClient(transport: transport).setPollingRate(hertz)
        case .reclusaReceiver: try ReclusaPollingClient(transport: transport, wait: wait).setPollingRate(hertz)
        }
    }
}
