import Foundation

public struct PollingRatePlan: Identifiable, Sendable {
    public let id = UUID()
    public let deviceID: String
    public let deviceName: String
    public let before: Int
    public let after: Int
    public let createdAt = Date()
    let interface: HIDInterface
    let issuedAt: ContinuousClock.Instant
    let route: PollingRateRoute
    let permit = DeviceWritePermit()
    var isUsable: Bool { permit.isUsable && issuedAt.duration(to: .now) < .seconds(60) }
    func invalidate() { permit.invalidate() }

    init(deviceID: String, deviceName: String, before: Int, after: Int, interface: HIDInterface,
         issuedAt: ContinuousClock.Instant, route: PollingRateRoute = .viperV4) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.before = before
        self.after = after
        self.interface = interface
        self.issuedAt = issuedAt
        self.route = route
    }
}

public enum PollingWriteOutcome: String, Codable, Sendable { case verified, notSent, uncertain }

public struct PollingRateWriteResult: Codable, Sendable {
    public let deviceID: String
    public let interfaceID: UInt64
    public let completedAt: Date
    public let outcome: PollingWriteOutcome
    public let attemptedWrite: Bool
    public let readback: Int?
    public let message: String
}

public protocol PollingRateControlling: Sendable {
    func prepare(_ device: DeviceInfo, hertz: Int) async throws -> PollingRatePlan
    func apply(_ plan: PollingRatePlan) async -> PollingRateWriteResult
}

/// Uses the same serial executor and exact interface whitelist as read-only operations.
public final class PollingRateControlService: PollingRateControlling, Sendable {
    public static let supportedRates = ViperV4PollingWriteProtocol.rates
    private let factory: @Sendable (HIDInterface) throws -> any HIDFeatureTransport
    private let wait: @Sendable () -> Void
    public init() {
        factory = { try NativeHIDFeatureTransport(interface: $0) }
        wait = { Thread.sleep(forTimeInterval: 0.035) }
    }
    init(factory: @escaping @Sendable (HIDInterface) throws -> any HIDFeatureTransport) {
        self.factory = factory
        wait = { Thread.sleep(forTimeInterval: 0.035) }
    }
    init(factory: @escaping @Sendable (HIDInterface) throws -> any HIDFeatureTransport,
         wait: @escaping @Sendable () -> Void) {
        self.factory = factory
        self.wait = wait
    }

    public static func controlInterface(in device: DeviceInfo) -> HIDInterface? {
        PollingRateRoute.resolve(device)?.interface
    }
    public static func canControl(_ device: DeviceInfo) -> Bool { controlInterface(in: device) != nil }
    public static func supportedRates(for device: DeviceInfo) -> [Int] {
        PollingRateRoute.resolve(device)?.route.supportedRates ?? []
    }

    public func prepare(_ device: DeviceInfo, hertz: Int) async throws -> PollingRatePlan {
        guard let selection = PollingRateRoute.resolve(device) else { throw MouseQueryError.unavailableInterface }
        try selection.route.validateTarget(hertz)
        return try await withCheckedThrowingContinuation { continuation in
            HIDOperationExecutor.queue.async {
                do {
                    let interface = selection.interface
                    let transport = try self.factory(interface)
                    defer { transport.close() }
                    let before = try selection.route.read(transport, wait: self.wait)
                    guard before != hertz else { throw MouseQueryError.malformed("目标回报率与设备相同，无需写入") }
                    continuation.resume(returning: PollingRatePlan(deviceID: device.id, deviceName: device.product,
                        before: before, after: hertz, interface: interface, issuedAt: .now, route: selection.route))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func apply(_ plan: PollingRatePlan) async -> PollingRateWriteResult {
        await withCheckedContinuation { continuation in
            HIDOperationExecutor.queue.async { continuation.resume(returning: self.performApply(plan)) }
        }
    }

    private func performApply(_ plan: PollingRatePlan) -> PollingRateWriteResult {
        var attempted = false
        var readback: Int?
        do {
            guard plan.isUsable else { throw MouseQueryError.malformed("确认已失效，请重新检查变更") }
            try plan.route.validateTarget(plan.after)
            let transport = try factory(plan.interface)
            defer { transport.close() }
            let current = try plan.route.read(transport, wait: wait)
            guard current == plan.before else { throw MouseQueryError.malformed("设备回报率已变化，已中止；请重新检查") }
            guard plan.isUsable, plan.permit.consume() else { throw MouseQueryError.malformed("确认已取消、过期或使用") }
            attempted = true
            try plan.route.set(plan.after, transport: transport, wait: wait)
            readback = try plan.route.read(transport, transaction: 0x82, wait: wait)
            guard readback == plan.after else { throw MouseQueryError.malformed("设备读回 \(readback ?? 0) Hz，与目标 \(plan.after) Hz 不一致") }
            return .init(deviceID: plan.deviceID, interfaceID: plan.interface.id, completedAt: Date(), outcome: .verified,
                attemptedWrite: true, readback: readback, message: "已读回 \(plan.after) Hz 配置；不是实际输入频率测量。")
        } catch {
            plan.invalidate()
            return .init(deviceID: plan.deviceID, interfaceID: plan.interface.id, completedAt: Date(),
                outcome: attempted ? .uncertain : .notSent, attemptedWrite: attempted, readback: readback,
                message: attempted ? "设置可能已到达设备，但未完成验证。\(error.localizedDescription) 不会自动重试或回滚，请手动读取回报率。"
                    : "未发送设置命令。\(error.localizedDescription)")
        }
    }
}
