import Foundation

public enum DeviceReadState: String, Codable, Sendable {
    case discovered, reading, waiting, cancelled, deviceResponse, systemMetadata, partial, unconfirmed, suspended

    public var title: String {
        switch self {
        case .discovered: "接口已发现"
        case .reading: "正在读取"
        case .waiting: "等待上次操作结束"
        case .cancelled: "读取已取消"
        case .deviceResponse: "设备曾响应"
        case .systemMetadata: "系统状态已取得"
        case .partial: "部分状态已取得"
        case .unconfirmed: "状态未确认"
        case .suspended: "读取已暂停"
        }
    }

    public var detail: String {
        switch self {
        case .discovered: "系统已发布 HID 接口；接收器存在不代表无线外设在线。"
        case .reading: "正在读取，等待本次查询完成。"
        case .waiting: "上次操作已失效，底层请求尚未返回；结束后可手动重试。"
        case .cancelled: "本次读取已取消，结果不会用于更新设备状态。"
        case .deviceResponse: "本次连接曾返回有效设备响应；读数仅代表读取时的状态，不表示持续在线。"
        case .systemMetadata: "已取得 macOS 发布的缓存信息，不等同于直接设备测量。"
        case .partial: "部分字段有有效读数，其他字段未完成；请分别查看来源、时间和错误。"
        case .unconfirmed: "本次读取没有取得有效值；失败原因不等同于设备已离线或正在休眠。"
        case .suspended: "系统睡眠后清理了读数；唤醒后可手动读取，合格后端按设置重新安排电量刷新。"
        }
    }
}

public struct DeviceReadSummary: Codable, Equatable, Sendable {
    public let state: DeviceReadState
    public let lastResultAt: Date?

    public static func assess(battery: BatteryReading? = nil, mouse: MouseTelemetry? = nil, systemBattery: SystemBatteryReading? = nil,
                              polling: MousePollingReading? = nil, charging: MouseChargingReading? = nil,
                              keyboardBattery: KeyboardPowerReading? = nil, keyboardCharging: KeyboardPowerReading? = nil,
                              isReading: Bool = false,
                              isSuspended: Bool = false, isDraining: Bool = false, hasCancelledRead: Bool = false) -> DeviceReadSummary {
        let lastDate = [battery?.acquiredAt, mouse?.readAt, systemBattery?.acquiredAt, polling?.readAt, charging?.readAt,
                        keyboardBattery?.readAt, keyboardCharging?.readAt].compactMap { $0 }.max()
        let state: DeviceReadState
        let hasDeviceValue = battery?.isValid == true && battery?.source == .device
            || (battery == nil && (mouse?.batteryPercent != nil || keyboardBattery?.hasValue == true))
            || mouse?.dpi != nil || polling?.configuredHertz != nil || charging?.state != nil || keyboardCharging?.hasValue == true
        let hasSystemValue = battery?.isValid == true && battery?.source == .systemCache
            || (battery == nil && systemBattery?.percent != nil && systemBattery?.source != nil)
        let mouseFailure = mouse?.issues.contains { battery == nil || $0.field != "battery" } == true
        let hasFailure = battery.map { !$0.isValid } == true || mouseFailure
            || (battery == nil && (systemBattery?.issue != nil || systemBattery?.failureKind != nil || keyboardBattery?.issue != nil))
            || polling?.issue != nil || charging?.issue != nil || keyboardCharging?.issue != nil
        if isSuspended { state = .suspended }
        else if isDraining { state = .waiting }
        else if isReading { state = .reading }
        else if hasFailure && (hasDeviceValue || hasSystemValue) { state = .partial }
        else if hasDeviceValue { state = .deviceResponse }
        else if hasSystemValue { state = .systemMetadata }
        else if hasCancelledRead { state = .cancelled }
        else if battery != nil || mouse != nil || systemBattery != nil || polling != nil || charging != nil || keyboardBattery != nil || keyboardCharging != nil { state = .unconfirmed }
        else { state = .discovered }
        return DeviceReadSummary(state: state, lastResultAt: lastDate)
    }
}
