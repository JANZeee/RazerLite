import Foundation

public struct KeyboardPowerReading: Codable, Equatable, Sendable {
    public let deviceID: String
    public let interfaceID: UInt64?
    public let field: KeyboardPowerField
    public let readAt: Date
    public let batteryPercent: Int?
    public let chargingState: DeviceChargingState?
    public let issue: MouseReadIssue?

    public var hasValue: Bool {
        guard issue == nil else { return false }
        switch field {
        case .battery: return batteryPercent.map { (0...100).contains($0) } == true && chargingState == nil
        case .charging: return chargingState != nil && batteryPercent == nil
        }
    }

    func matches(_ device: DeviceInfo, field: KeyboardPowerField) -> Bool {
        self.field == field && deviceID == device.id && interfaceID != nil
            && interfaceID == BlackWidowLowProfileAdapter.controlInterface(in: device)?.id
    }
}

public protocol KeyboardPowerReadingService: Sendable {
    func read(_ device: DeviceInfo, field: KeyboardPowerField) async -> KeyboardPowerReading
}

/// Manual exact-model queries. No input subscription, mode setup, periodic reads, or setting commands.
public final class KeyboardPowerReadService: KeyboardPowerReadingService, Sendable {
    private let transportFactory: @Sendable (HIDInterface) throws -> any HIDFeatureTransport
    public init() { transportFactory = { try NativeHIDFeatureTransport(interface: $0) } }
    init(transportFactory: @escaping @Sendable (HIDInterface) throws -> any HIDFeatureTransport) {
        self.transportFactory = transportFactory
    }
    public static func canRead(_ device: DeviceInfo) -> Bool { BlackWidowLowProfileAdapter.controlInterface(in: device) != nil }

    public func read(_ device: DeviceInfo, field: KeyboardPowerField) async -> KeyboardPowerReading {
        await withCheckedContinuation { continuation in
            HIDOperationExecutor.queue.async {
                let interface = BlackWidowLowProfileAdapter.controlInterface(in: device)
                var battery: Int?
                var charging: DeviceChargingState?
                var issue: MouseReadIssue?
                do {
                    guard let interface else { throw DeviceQueryError.unavailableInterface }
                    let transport = try self.transportFactory(interface)
                    defer { transport.close() }
                    let payload = try Self.query(field, transport: transport)
                    switch field {
                    case .battery: battery = try BlackWidowPowerProtocol.batteryPercent(payload)
                    case .charging: charging = try BlackWidowPowerProtocol.chargingState(payload)
                    }
                } catch {
                    issue = MouseReadIssue(field: field.rawValue, message: error.localizedDescription,
                                           kind: ReadFailureClassifier.classify(error))
                }
                continuation.resume(returning: KeyboardPowerReading(deviceID: device.id, interfaceID: interface?.id,
                    field: field, readAt: Date(), batteryPercent: battery, chargingState: charging, issue: issue))
            }
        }
    }

    private static func query(_ field: KeyboardPowerField, transport: any HIDFeatureTransport) throws -> [UInt8] {
        try transport.send(BlackWidowPowerProtocol.request(field), reportID: 0)
        Thread.sleep(forTimeInterval: 0.035)
        for attempt in 0..<16 {
            let frame = try transport.receive(reportID: 0, length: RazerReportCodec.length)
            switch try BlackWidowPowerProtocol.reply(frame, field: field) {
            case let .payload(payload): return payload
            case .busy:
                if attempt < 15 { Thread.sleep(forTimeInterval: 0.035) }
            }
        }
        throw DeviceQueryError.busyTimeout
    }
}
