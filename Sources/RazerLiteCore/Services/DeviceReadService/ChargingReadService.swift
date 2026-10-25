import Foundation

public struct MouseChargingReading: Codable, Equatable, Sendable {
    public let deviceID: String
    public let interfaceID: UInt64?
    public let readAt: Date
    public let state: MouseChargingState?
    public let issue: MouseReadIssue?
}

public protocol MouseChargingReadingService: Sendable {
    func read(_ device: DeviceInfo) async -> MouseChargingReading
}

/// A separate explicit operation on the reviewed 00E6 interface; never enables other PIDs or Bluetooth.
public final class ChargingReadService: MouseChargingReadingService, Sendable {
    private let transportFactory: @Sendable (HIDInterface) throws -> any HIDFeatureTransport
    public init() { transportFactory = { try NativeHIDFeatureTransport(interface: $0) } }
    init(transportFactory: @escaping @Sendable (HIDInterface) throws -> any HIDFeatureTransport) {
        self.transportFactory = transportFactory
    }
    public static func canRead(_ device: DeviceInfo) -> Bool { MouseReadService.canRead(device) }

    public func read(_ device: DeviceInfo) async -> MouseChargingReading {
        await withCheckedContinuation { continuation in
            HIDOperationExecutor.queue.async {
                let interface = ViperV4Adapter.controlInterface(in: device)
                var state: MouseChargingState?
                var issue: MouseReadIssue?
                do {
                    guard let interface else { throw MouseQueryError.unavailableInterface }
                    let transport = try self.transportFactory(interface)
                    defer { transport.close() }
                    let client = ViperV4ControlClient(transport: transport)
                    state = try ViperV4ReadProtocol.chargingState(client.query(.charging))
                } catch {
                    issue = MouseReadIssue(field: "charging", message: error.localizedDescription,
                                           kind: ReadFailureClassifier.classify(error))
                }
                continuation.resume(returning: MouseChargingReading(deviceID: device.id, interfaceID: interface?.id,
                                                                     readAt: Date(), state: state, issue: issue))
            }
        }
    }
}
