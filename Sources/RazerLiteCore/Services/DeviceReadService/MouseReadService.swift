import Foundation

public struct MouseReadIssue: Codable, Equatable, Sendable {
    public let field: String
    public let message: String
    /// Stable category when this issue came from a failed read; nil keeps older export compatibility.
    public let kind: ReadFailureKind?

    public init(field: String, message: String, kind: ReadFailureKind? = nil) {
        self.field = field
        self.message = message
        self.kind = kind
    }
}

public struct MouseTelemetry: Codable, Equatable, Sendable {
    public let deviceID: String
    public let interfaceID: UInt64?
    public let readAt: Date
    public let batteryPercent: Int?
    public let dpi: MouseDPIState?
    public let issues: [MouseReadIssue]
    public var isComplete: Bool { batteryPercent != nil && dpi != nil && issues.isEmpty }
}

public protocol MouseStatusReading: Sendable {
    func read(_ device: DeviceInfo) async -> MouseTelemetry
}

/// Explicit queries, serialized across this process, with bounded busy retries.
/// Synchronous IOKit transfers run on this worker; their underlying timeouts belong to the OS/driver.
public final class MouseReadService: MouseStatusReading, Sendable {
    private let transportFactory: @Sendable (HIDInterface) throws -> any HIDFeatureTransport

    public init() { transportFactory = { try NativeHIDFeatureTransport(interface: $0) } }
    init(transportFactory: @escaping @Sendable (HIDInterface) throws -> any HIDFeatureTransport) {
        self.transportFactory = transportFactory
    }

    public static func canRead(_ device: DeviceInfo) -> Bool { DeviceReadRegistry.backends(for: device).contains(.viperV4USB) }
    public static func interfaceID(for device: DeviceInfo) -> UInt64? { ViperV4Adapter.controlInterface(in: device)?.id }

    static func failureKind(for error: any Error) -> ReadFailureKind { ReadFailureClassifier.classify(error) }

    public func read(_ device: DeviceInfo) async -> MouseTelemetry {
        await withCheckedContinuation { continuation in
            HIDOperationExecutor.queue.async {
                continuation.resume(returning: Self.performRead(device, factory: self.transportFactory))
            }
        }
    }

    private static func performRead(_ device: DeviceInfo,
                                    factory: (HIDInterface) throws -> any HIDFeatureTransport) -> MouseTelemetry {
        let interface = ViperV4Adapter.controlInterface(in: device)
        var battery: Int?
        var dpi: MouseDPIState?
        var issues: [MouseReadIssue] = []
        var field = "interface"
        do {
            guard let interface else { throw MouseQueryError.unavailableInterface }
            let transport = try factory(interface)
            defer { transport.close() }
            let client = ViperV4ControlClient(transport: transport)
            field = "battery"
            battery = try ViperV4ReadProtocol.batteryPercent(client.query(.battery))
            field = "dpi"
            dpi = try ViperV4ReadProtocol.dpiState(client.query(.dpiStages))
        } catch {
            // On any transport/protocol failure stop issuing further commands; preserve validated partial data.
            issues.append(MouseReadIssue(field: field, message: error.localizedDescription, kind: failureKind(for: error)))
        }
        return MouseTelemetry(deviceID: device.id, interfaceID: interface?.id, readAt: Date(),
                              batteryPercent: battery, dpi: dpi, issues: issues)
    }
}
