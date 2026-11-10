import Foundation

/// A profile-scoped configuration value, not a measurement of active keyboard illumination.
public struct KeyboardBrightnessReading: Codable, Equatable, Sendable {
    public let deviceID: String
    public let interfaceID: UInt64?
    public let profileID: UInt8
    public let regionID: UInt8?
    public let rawBrightness: UInt8?
    public let percent: Int?
    public let issue: MouseReadIssue?
    public let readAt: Date

    public var hasValue: Bool {
        guard issue == nil, interfaceID != nil, profileID == ReclusaBrightnessProtocol.profileID,
              let regionID, regionID != 0, let rawBrightness else { return false }
        return percent == ReclusaBrightnessProtocol.percent(rawBrightness)
    }
}

public protocol KeyboardBrightnessReadingService: Sendable {
    func read(_ device: DeviceInfo) async -> KeyboardBrightnessReading
}

/// Manual two-command read: enumerate the single lighting region, then read profile 1.
/// No discovery-time query, automatic refresh, setting, mode change or default-region fallback.
public final class ReclusaBrightnessReadService: KeyboardBrightnessReadingService, Sendable {
    private let factory: @Sendable (HIDInterface) throws -> any HIDFeatureTransport
    private let wait: @Sendable () -> Void

    public init() {
        factory = { try NativeHIDFeatureTransport(interface: $0) }
        wait = { Thread.sleep(forTimeInterval: 0.035) }
    }

    init(factory: @escaping @Sendable (HIDInterface) throws -> any HIDFeatureTransport,
         wait: @escaping @Sendable () -> Void = { Thread.sleep(forTimeInterval: 0.035) }) {
        self.factory = factory
        self.wait = wait
    }

    public static func canRead(_ device: DeviceInfo) -> Bool {
        ReclusaLightingAdapter.controlInterface(in: device) != nil
    }

    public func read(_ device: DeviceInfo) async -> KeyboardBrightnessReading {
        await withCheckedContinuation { continuation in
            HIDOperationExecutor.queue.async {
                let interface = ReclusaLightingAdapter.controlInterface(in: device)
                var regionID: UInt8?
                var raw: UInt8?
                var issue: MouseReadIssue?
                do {
                    guard let interface else { throw DeviceQueryError.unavailableInterface }
                    let transport = try self.factory(interface)
                    defer { transport.close() }
                    let client = ReclusaBrightnessClient(transport: transport, wait: self.wait)
                    let region = try client.region()
                    regionID = region
                    raw = try client.brightness(regionID: region)
                } catch {
                    raw = nil
                    issue = MouseReadIssue(field: "brightness", message: error.localizedDescription,
                                           kind: ReadFailureClassifier.classify(error))
                }
                continuation.resume(returning: KeyboardBrightnessReading(deviceID: device.id, interfaceID: interface?.id,
                    profileID: ReclusaBrightnessProtocol.profileID, regionID: regionID, rawBrightness: raw,
                    percent: raw.map(ReclusaBrightnessProtocol.percent), issue: issue, readAt: Date()))
            }
        }
    }

}
