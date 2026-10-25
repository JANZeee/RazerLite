import Foundation

public enum BatteryReadingOrigin: String, Sendable { case manual, automatic }
public enum BatteryValueSource: String, Codable, Sendable {
    case device, systemCache
    public var title: String { self == .device ? "设备响应" : "系统缓存 · 设备采样时间未知" }
}

public struct BatteryReading: Codable, Equatable, Sendable {
    public let deviceID: String
    public let interfaceIDs: [UInt64]
    public let backend: DeviceReadBackend
    public let percent: Int?
    public let acquiredAt: Date
    public let source: BatteryValueSource
    public let issue: MouseReadIssue?
    public var isValid: Bool { issue == nil && percent.map { (0...100).contains($0) } == true }

    func matches(_ device: DeviceInfo) -> Bool {
        device.id == deviceID && device.interfaces.map(\.id).sorted() == interfaceIDs
            && DeviceReadRegistry.backends(for: device).contains(backend)
    }
}

public struct BatteryObservation: Sendable {
    public let target: BatteryRefreshTarget
    public let deviceName: String
    public let reading: BatteryReading
    public let origin: BatteryReadingOrigin
    public let simulation: Bool
}

public protocol BatteryReadingService: Sendable {
    func read(_ device: DeviceInfo) async -> BatteryReading
}

/// Uses only the already reviewed Viper battery GET. Never queries DPI or charging.
public final class ViperBatteryReadService: BatteryReadingService, Sendable {
    private let transportFactory: @Sendable (HIDInterface) throws -> any HIDFeatureTransport
    public init() { transportFactory = { try NativeHIDFeatureTransport(interface: $0) } }
    init(transportFactory: @escaping @Sendable (HIDInterface) throws -> any HIDFeatureTransport) { self.transportFactory = transportFactory }
    public func read(_ device: DeviceInfo) async -> BatteryReading {
        await withCheckedContinuation { continuation in
            HIDOperationExecutor.queue.async {
                var percent: Int?
                var issue: MouseReadIssue?
                do {
                    guard let interface = ViperV4Adapter.controlInterface(in: device) else { throw MouseQueryError.unavailableInterface }
                    let transport = try self.transportFactory(interface)
                    defer { transport.close() }
                    percent = try ViperV4ReadProtocol.batteryPercent(ViperV4ControlClient(transport: transport).query(.battery))
                } catch { issue = .init(field: "battery", message: error.localizedDescription, kind: ReadFailureClassifier.classify(error)) }
                continuation.resume(returning: .init(deviceID: device.id, interfaceIDs: device.interfaces.map(\.id).sorted(),
                    backend: .viperV4USB, percent: percent, acquiredAt: .now, source: .device, issue: issue))
            }
        }
    }
}
