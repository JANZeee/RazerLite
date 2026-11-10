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
    private let wait: @Sendable () -> Void
    public init() {
        transportFactory = { try NativeHIDFeatureTransport(interface: $0) }
        wait = { Thread.sleep(forTimeInterval: 0.035) }
    }
    init(transportFactory: @escaping @Sendable (HIDInterface) throws -> any HIDFeatureTransport) {
        self.transportFactory = transportFactory
        wait = { Thread.sleep(forTimeInterval: 0.035) }
    }
    init(transportFactory: @escaping @Sendable (HIDInterface) throws -> any HIDFeatureTransport,
         wait: @escaping @Sendable () -> Void) {
        self.transportFactory = transportFactory
        self.wait = wait
    }
    public static func controlInterface(in device: DeviceInfo) -> HIDInterface? {
        PollingRateRoute.resolve(device)?.interface
    }
    public static func canRead(_ device: DeviceInfo) -> Bool { controlInterface(in: device) != nil }

    public func read(_ device: DeviceInfo) async -> MousePollingReading {
        await withCheckedContinuation { continuation in
            HIDOperationExecutor.queue.async {
                let selection = PollingRateRoute.resolve(device)
                let interface = selection?.interface
                var hertz: Int?
                var issue: MouseReadIssue?
                do {
                    guard let selection else { throw MouseQueryError.unavailableInterface }
                    let transport = try self.transportFactory(selection.interface)
                    defer { transport.close() }
                    hertz = try selection.route.read(transport, wait: self.wait)
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
