import Foundation

public struct KeyboardBrightnessPlan: Identifiable, Sendable {
    public let id = UUID()
    public let deviceID: String
    public let deviceName: String
    public let before: KeyboardBrightnessReading
    public let afterPercent: Int
    public let afterRaw: UInt8
    public let createdAt = Date()
    let interface: HIDInterface
    let issuedAt: ContinuousClock.Instant
    let permit = DeviceWritePermit()
    var isUsable: Bool { permit.isUsable && issuedAt.duration(to: .now) < .seconds(60) }
    func invalidate() { permit.invalidate() }
}

public enum KeyboardBrightnessWriteOutcome: String, Codable, Sendable { case verified, notSent, uncertain }

public struct KeyboardBrightnessWriteResult: Codable, Sendable {
    public let deviceID: String
    public let interfaceID: UInt64
    public let completedAt: Date
    public let outcome: KeyboardBrightnessWriteOutcome
    public let attemptedWrite: Bool
    public let readback: KeyboardBrightnessReading?
    public let message: String
}

public protocol KeyboardBrightnessControlling: Sendable {
    func prepare(_ device: DeviceInfo, percent: Int) async throws -> KeyboardBrightnessPlan
    func apply(_ plan: KeyboardBrightnessPlan) async -> KeyboardBrightnessWriteResult
}

/// Requires an explicit, expiring confirmation. A write is never retried or rolled back.
public final class ReclusaBrightnessControlService: KeyboardBrightnessControlling, Sendable {
    private let factory: @Sendable (HIDInterface) throws -> any HIDFeatureTransport
    private let wait: @Sendable () -> Void

    public init() {
        factory = { try NativeHIDFeatureTransport(interface: $0) }
        wait = { Thread.sleep(forTimeInterval: 0.035) }
    }

    init(factory: @escaping @Sendable (HIDInterface) throws -> any HIDFeatureTransport,
         wait: @escaping @Sendable () -> Void = { Thread.sleep(forTimeInterval: 0.035) }) {
        self.factory = factory; self.wait = wait
    }

    public static func canControl(_ device: DeviceInfo) -> Bool { ReclusaBrightnessReadService.canRead(device) }

    public func prepare(_ device: DeviceInfo, percent: Int) async throws -> KeyboardBrightnessPlan {
        let target = try ReclusaBrightnessProtocol.raw(forPercent: percent)
        return try await withCheckedThrowingContinuation { continuation in
            HIDOperationExecutor.queue.async {
                do {
                    guard let interface = ReclusaLightingAdapter.controlInterface(in: device) else {
                        throw DeviceQueryError.unavailableInterface
                    }
                    let transport = try self.factory(interface)
                    defer { transport.close() }
                    let before = try ReclusaBrightnessClient(transport: transport, wait: self.wait)
                        .read(deviceID: device.id, interfaceID: interface.id)
                    guard before.rawBrightness != target else { throw DeviceQueryError.malformed("目标亮度与配置相同，无需写入") }
                    continuation.resume(returning: KeyboardBrightnessPlan(deviceID: device.id, deviceName: device.product,
                        before: before, afterPercent: percent, afterRaw: target, interface: interface, issuedAt: .now))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func apply(_ plan: KeyboardBrightnessPlan) async -> KeyboardBrightnessWriteResult {
        await withCheckedContinuation { continuation in
            HIDOperationExecutor.queue.async { continuation.resume(returning: self.performApply(plan)) }
        }
    }

    private func performApply(_ plan: KeyboardBrightnessPlan) -> KeyboardBrightnessWriteResult {
        var attempted = false
        do {
            guard plan.isUsable else { throw DeviceQueryError.malformed("亮度确认已取消、过期或使用，请重新检查变更") }
            guard plan.before.hasValue, plan.before.deviceID == plan.deviceID,
                  plan.before.interfaceID == plan.interface.id,
                  try ReclusaBrightnessProtocol.raw(forPercent: plan.afterPercent) == plan.afterRaw,
                  plan.before.rawBrightness != plan.afterRaw else {
                throw DeviceQueryError.malformed("亮度确认的基线或目标不完整")
            }
            let transport = try factory(plan.interface)
            defer { transport.close() }
            let client = ReclusaBrightnessClient(transport: transport, wait: wait)
            let current = try client.read(deviceID: plan.deviceID, interfaceID: plan.interface.id)
            guard current.profileID == plan.before.profileID, current.regionID == plan.before.regionID,
                  current.rawBrightness == plan.before.rawBrightness else {
                throw DeviceQueryError.malformed("灯区或亮度配置已变化，已中止；请重新检查变更")
            }
            guard plan.isUsable, plan.permit.consume() else {
                throw DeviceQueryError.malformed("亮度确认已取消、过期或使用，请重新检查变更")
            }
            attempted = true
            try client.setBrightness(raw: plan.afterRaw)
            let readback = try client.read(deviceID: plan.deviceID, interfaceID: plan.interface.id,
                                           regionTransaction: 0x83, brightnessTransaction: 0x84)
            guard readback.profileID == plan.before.profileID, readback.regionID == plan.before.regionID,
                  readback.rawBrightness == plan.afterRaw else {
                throw DeviceQueryError.malformed("亮度读回与确认的目标或灯区不一致")
            }
            return .init(deviceID: plan.deviceID, interfaceID: plan.interface.id, completedAt: Date(),
                         outcome: .verified, attemptedWrite: true, readback: readback,
                         message: "已读回 \(plan.afterPercent)% 亮度配置；请观察键盘灯光是否变化。")
        } catch {
            plan.invalidate()
            return .init(deviceID: plan.deviceID, interfaceID: plan.interface.id, completedAt: Date(),
                         outcome: attempted ? .uncertain : .notSent, attemptedWrite: attempted, readback: nil,
                         message: attempted ? "设置可能已到达设备，但未完成读回验证。\(error.localizedDescription) 不会自动重试或回滚，请手动读取亮度。"
                             : "未发送亮度设置命令。\(error.localizedDescription)")
        }
    }
}
