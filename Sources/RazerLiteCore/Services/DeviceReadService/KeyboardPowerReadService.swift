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
            && interfaceID == KeyboardPowerReadService.controlInterface(in: device)?.id
    }
}

public protocol KeyboardPowerReadingService: Sendable {
    func read(_ device: DeviceInfo, field: KeyboardPowerField) async -> KeyboardPowerReading
}

/// Manual exact-model queries. No input subscription, mode setup, periodic reads, or setting commands.
public final class KeyboardPowerReadService: KeyboardPowerReadingService, Sendable {
    private let transportFactory: @Sendable (HIDInterface) throws -> any HIDFeatureTransport
    private let wait: @Sendable () -> Void
    private let reclusaTransactions = ReclusaPowerTransactions()
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
        KeyboardPowerRoute.resolve(device)?.interface
    }
    public static func canRead(_ device: DeviceInfo) -> Bool { controlInterface(in: device) != nil }

    public func read(_ device: DeviceInfo, field: KeyboardPowerField) async -> KeyboardPowerReading {
        await withCheckedContinuation { continuation in
            HIDOperationExecutor.queue.async {
                let route = KeyboardPowerRoute.resolve(device)
                let interface = route?.interface
                var battery: Int?
                var charging: DeviceChargingState?
                var issue: MouseReadIssue?
                do {
                    guard let route, let interface else { throw DeviceQueryError.unavailableInterface }
                    let transport = try self.transportFactory(interface)
                    defer { transport.close() }
                    switch route {
                    case .blackWidow:
                        let payload = try self.query(BlackWidowPowerProtocol.request(field), transport: transport) {
                            try BlackWidowPowerProtocol.reply($0, field: field)
                        }
                        switch field {
                        case .battery: battery = try BlackWidowPowerProtocol.batteryPercent(payload)
                        case .charging: charging = try BlackWidowPowerProtocol.chargingState(payload)
                        }
                    case .reclusa:
                        let transaction = self.reclusaTransactions.next()
                        let payload = try self.query(ReclusaPowerProtocol.request(field, transaction: transaction), transport: transport) {
                            try ReclusaPowerProtocol.reply($0, field: field, transaction: transaction)
                        }
                        switch field {
                        case .battery: battery = try ReclusaPowerProtocol.batteryPercent(payload)
                        case .charging: charging = try ReclusaPowerProtocol.chargingState(payload)
                        }
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

    private func query(_ request: [UInt8], transport: any HIDFeatureTransport,
                       decode: ([UInt8]) throws -> RazerReportCodec.Reply) throws -> [UInt8] {
        try transport.send(request, reportID: 0)
        wait()
        for attempt in 0..<16 {
            let frame = try transport.receive(reportID: 0, length: RazerReportCodec.length)
            switch try decode(frame) {
            case let .payload(payload): return payload
            case .busy:
                if attempt < 15 { wait() }
            }
        }
        throw DeviceQueryError.busyTimeout
    }
}

/// Protected independently of the serial HID executor so the sequence remains safe if scheduling changes.
private final class ReclusaPowerTransactions: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt8 = 0

    func next() -> UInt8 {
        lock.lock(); defer { lock.unlock() }
        let transaction = 0x80 | sequence
        sequence = sequence == 30 ? 0 : sequence + 1
        return transaction
    }
}
