import Foundation

/// One UI-originated target, revoked when its gesture/session becomes invalid.
/// This is never stored in preferences or recreated for a reconnect.
public final class LiveBrightnessPermit: @unchecked Sendable {
    private let permit = DeviceWritePermit()
    private let issuedAt: ContinuousClock.Instant
    init(issuedAt: ContinuousClock.Instant = .now) { self.issuedAt = issuedAt }
    var isUsable: Bool { permit.isUsable && issuedAt.duration(to: .now) < .seconds(5) }
    func consume() -> Bool { isUsable && permit.consume() }
    func invalidate() { permit.invalidate() }
}

public protocol KeyboardBrightnessLiveControlling: Sendable {
    func set(_ device: DeviceInfo, percent: Int, permit: LiveBrightnessPermit) async -> KeyboardBrightnessWriteResult
}

/// A bounded live-slider transaction: check region/value, one SET if needed, then read back.
/// It shares the normal HID executor and never opens or captures input interfaces.
public final class ReclusaLiveBrightnessService: KeyboardBrightnessLiveControlling, Sendable {
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

    public func set(_ device: DeviceInfo, percent: Int, permit: LiveBrightnessPermit) async -> KeyboardBrightnessWriteResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                HIDOperationExecutor.queue.async {
                    continuation.resume(returning: self.perform(device, percent: percent, permit: permit))
                }
            }
        } onCancel: { permit.invalidate() }
    }

    private func perform(_ device: DeviceInfo, percent: Int, permit: LiveBrightnessPermit) -> KeyboardBrightnessWriteResult {
        let interface = ReclusaLightingAdapter.controlInterface(in: device)
        var attempted = false
        defer { permit.invalidate() }
        do {
            let target = try ReclusaBrightnessProtocol.raw(forPercent: percent)
            guard permit.isUsable else { throw DeviceQueryError.malformed("亮度操作已取消或过期") }
            guard let interface else { throw DeviceQueryError.unavailableInterface }
            let transport = try factory(interface)
            defer { transport.close() }
            let client = ReclusaBrightnessClient(transport: transport, wait: wait)
            let before = try client.read(deviceID: device.id, interfaceID: interface.id)
            guard permit.isUsable else { throw DeviceQueryError.malformed("亮度操作已取消或过期") }
            if before.rawBrightness == target {
                return .init(deviceID: device.id, interfaceID: interface.id, completedAt: .now,
                             outcome: .verified, attemptedWrite: false, readback: before,
                             message: "亮度已为 \(percent)%")
            }
            guard let region = before.regionID, permit.consume() else {
                throw DeviceQueryError.malformed("亮度操作已取消、过期或使用")
            }
            attempted = true
            try client.setBrightness(raw: target)
            let raw = try client.brightness(regionID: region, transaction: 0x83)
            guard raw == target else { throw DeviceQueryError.malformed("亮度读回与目标不一致") }
            let reading = KeyboardBrightnessReading(deviceID: device.id, interfaceID: interface.id,
                profileID: before.profileID, regionID: region, rawBrightness: raw,
                percent: ReclusaBrightnessProtocol.percent(raw), issue: nil, readAt: .now)
            return .init(deviceID: device.id, interfaceID: interface.id, completedAt: .now,
                         outcome: .verified, attemptedWrite: true, readback: reading,
                         message: "已调至 \(percent)%")
        } catch {
            return .init(deviceID: device.id, interfaceID: interface?.id ?? 0, completedAt: .now,
                         outcome: attempted ? .uncertain : .notSent, attemptedWrite: attempted, readback: nil,
                         message: attempted ? "亮度可能已改变，但读回未完成。\(error.localizedDescription) 请重新读取亮度。"
                             : "未修改亮度。\(error.localizedDescription)")
        }
    }
}
