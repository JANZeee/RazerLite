import Foundation

/// Configured report rate returned by the device. This is not a measurement of input-event frequency.
public struct MousePollingReading: Codable, Equatable, Sendable {
    public let deviceID: String
    public let interfaceID: UInt64?
    public let readAt: Date
    public let configuredHertz: Int?
    public let issue: MouseReadIssue?
}

public protocol MousePollingReadingService: Sendable {
    func read(_ device: DeviceInfo) async -> MousePollingReading
}

/// Separate opt-in operation: does not depend on battery/DPI and never sends a rate-setting command.
public final class PollingRateReadService: MousePollingReadingService, Sendable {
    private let transportFactory: @Sendable (HIDInterface) throws -> any HIDFeatureTransport
    public init() { transportFactory = { try NativeHIDFeatureTransport(interface: $0) } }
    init(transportFactory: @escaping @Sendable (HIDInterface) throws -> any HIDFeatureTransport) {
        self.transportFactory = transportFactory
    }
    public static func canRead(_ device: DeviceInfo) -> Bool { MouseReadService.canRead(device) }

    public func read(_ device: DeviceInfo) async -> MousePollingReading {
        await withCheckedContinuation { continuation in
            HIDOperationExecutor.queue.async {
                let interface = ViperV4Adapter.controlInterface(in: device)
                var hertz: Int?
                var issue: MouseReadIssue?
                do {
                    guard let interface else { throw MouseQueryError.unavailableInterface }
                    let transport = try self.transportFactory(interface)
                    defer { transport.close() }
                    let client = ViperV4ControlClient(transport: transport)
                    hertz = try ViperV4ReadProtocol.pollingRate(client.query(.pollingRate))
                } catch {
                    issue = MouseReadIssue(field: "pollingRate", message: error.localizedDescription,
                                           kind: ReadFailureClassifier.classify(error))
                }
                continuation.resume(returning: MousePollingReading(deviceID: device.id, interfaceID: interface?.id,
                                                                    readAt: Date(), configuredHertz: hertz, issue: issue))
            }
        }
    }
}
