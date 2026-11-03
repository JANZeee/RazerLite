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
    let permit = DeviceWritePermit()
    var isUsable: Bool { permit.isUsable && issuedAt.duration(to: .now) < .seconds(60) }
    func invalidate() { permit.invalidate() }
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
    public init() { factory = { try NativeHIDFeatureTransport(interface: $0) } }
    init(factory: @escaping @Sendable (HIDInterface) throws -> any HIDFeatureTransport) { self.factory = factory }

    public func prepare(_ device: DeviceInfo, hertz: Int) async throws -> PollingRatePlan {
        _ = try ViperV4PollingWriteProtocol.code(for: hertz)
        return try await withCheckedThrowingContinuation { continuation in
            HIDOperationExecutor.queue.async {
                do {
                    guard let interface = ViperV4Adapter.controlInterface(in: device) else { throw MouseQueryError.unavailableInterface }
                    let transport = try self.factory(interface)
                    defer { transport.close() }
                    let before = try ViperV4ReadProtocol.pollingRate(ViperV4ControlClient(transport: transport).query(.pollingRate))
                    guard before != hertz else { throw MouseQueryError.malformed("目标回报率与设备相同，无需写入") }
                    continuation.resume(returning: PollingRatePlan(deviceID: device.id, deviceName: device.product,
                        before: before, after: hertz, interface: interface, issuedAt: .now))
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
            let transport = try factory(plan.interface)
            defer { transport.close() }
            let client = ViperV4ControlClient(transport: transport)
            let current = try ViperV4ReadProtocol.pollingRate(client.query(.pollingRate))
            guard current == plan.before else { throw MouseQueryError.malformed("设备回报率已变化，已中止；请重新检查") }
            guard plan.isUsable, plan.permit.consume() else { throw MouseQueryError.malformed("确认已取消、过期或使用") }
            attempted = true
            try client.setPollingRate(plan.after)
            readback = try ViperV4ReadProtocol.pollingRate(client.query(.pollingRate))
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
