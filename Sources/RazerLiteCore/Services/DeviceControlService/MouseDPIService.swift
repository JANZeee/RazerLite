import Foundation

/// Only an issued, uncancelled plan can grant a single write attempt.
final class DPIWritePermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private var used = false
    var isUsable: Bool { lock.lock(); defer { lock.unlock() }; return valid && !used }
    func invalidate() { lock.lock(); defer { lock.unlock() }; valid = false }
    func consume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard valid && !used else { return false }
        used = true
        return true
    }
}

public struct MouseDPIPlan: Identifiable, Sendable {
    public let id = UUID()
    public let deviceID: String
    public let deviceName: String
    public let before: MouseDPIState
    public let after: MouseDPIState
    public let createdAt = Date()
    let interface: HIDInterface
    let issuedAt: ContinuousClock.Instant
    let permit = DPIWritePermit()
    var isUsable: Bool { permit.isUsable && issuedAt.duration(to: .now) < .seconds(60) }
    func invalidate() { permit.invalidate() }
}

public enum DPIWriteOutcome: String, Codable, Sendable {
    case verified
    case notSent
    case uncertain
}

public struct MouseDPIWriteResult: Codable, Sendable {
    public let deviceID: String
    public let interfaceID: UInt64
    public let completedAt: Date
    public let outcome: DPIWriteOutcome
    public let attemptedWrite: Bool
    public let readback: MouseDPIState?
    public let message: String
}

public protocol MouseDPIControlling: Sendable {
    func prepare(_ device: DeviceInfo, x: Int, y: Int) async throws -> MouseDPIPlan
    func apply(_ plan: MouseDPIPlan) async -> MouseDPIWriteResult
}

/// Preparation is read-only; apply is reserved for the explicit confirmation button.
/// All feature I/O shares the read service's serial executor.
public final class MouseDPIService: MouseDPIControlling, Sendable {
    private let factory: @Sendable (HIDInterface) throws -> any HIDFeatureTransport
    public init() { factory = { try NativeHIDFeatureTransport(interface: $0) } }
    init(factory: @escaping @Sendable (HIDInterface) throws -> any HIDFeatureTransport) { self.factory = factory }

    public func prepare(_ device: DeviceInfo, x: Int, y: Int) async throws -> MouseDPIPlan {
        try ViperV4DPIProtocol.validateTarget(x: x, y: y)
        return try await withCheckedThrowingContinuation { continuation in
            HIDOperationExecutor.queue.async {
                do {
                    guard let interface = ViperV4Adapter.controlInterface(in: device) else { throw MouseQueryError.unavailableInterface }
                    let transport = try self.factory(interface)
                    defer { transport.close() }
                    let before = try ViperV4DPIProtocol.writableBaseline(ViperV4ControlClient(transport: transport).query(.dpiStages))
                    let after = try ViperV4DPIProtocol.replacingCurrent(in: before, x: x, y: y)
                    guard before != after else { throw MouseQueryError.malformed("目标值与当前档位相同，无需写入") }
                    continuation.resume(returning: MouseDPIPlan(deviceID: device.id, deviceName: device.product,
                                                                before: before, after: after, interface: interface, issuedAt: .now))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func apply(_ plan: MouseDPIPlan) async -> MouseDPIWriteResult {
        await withCheckedContinuation { continuation in
            HIDOperationExecutor.queue.async {
                continuation.resume(returning: self.performApply(plan))
            }
        }
    }

    private func performApply(_ plan: MouseDPIPlan) -> MouseDPIWriteResult {
        var attempted = false
        var readback: MouseDPIState?
        do {
            guard plan.isUsable else { throw MouseQueryError.malformed("确认计划已取消、过期或使用，请重新准备") }
            let transport = try factory(plan.interface)
            defer { transport.close() }
            let client = ViperV4ControlClient(transport: transport)
            let current = try ViperV4DPIProtocol.writableBaseline(client.query(.dpiStages))
            guard current == plan.before else { throw MouseQueryError.malformed("设备档位已变化，已中止；请重新读取并确认") }
            guard plan.isUsable, plan.permit.consume() else { throw MouseQueryError.malformed("确认计划已失效，未发送设置命令") }
            // From here on even an I/O error cannot prove the device did not accept the request.
            attempted = true
            try client.setDPI(plan.after)
            readback = try ViperV4ReadProtocol.dpiState(client.query(.dpiStages))
            guard readback == plan.after else { throw MouseQueryError.malformed("读回的完整档位表与目标不一致") }
            return MouseDPIWriteResult(deviceID: plan.deviceID, interfaceID: plan.interface.id, completedAt: Date(), outcome: .verified,
                                       attemptedWrite: true, readback: readback, message: "设备已读回目标 DPI，全部档位校验通过。")
        } catch {
            plan.invalidate()
            return MouseDPIWriteResult(deviceID: plan.deviceID, interfaceID: plan.interface.id, completedAt: Date(), outcome: attempted ? .uncertain : .notSent,
                                       attemptedWrite: attempted, readback: readback,
                                       message: attempted ? "设置请求可能已到达设备，但未完成验证。\(error.localizedDescription) 不会自动重试或回滚，请手动读取状态。"
                                       : "未发送设置命令。\(error.localizedDescription)")
        }
    }
}
