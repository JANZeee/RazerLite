import Foundation

public enum ConnectionCheckStatus: String, Codable, Sendable {
    case passed, attention, information
}

public struct ConnectionCheckStep: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let status: ConnectionCheckStatus
    public let detail: String
}

/// Explains existing snapshots only. Opening this report performs no device or permission operation.
public struct ConnectionCheckReport: Codable, Equatable, Sendable {
    public let steps: [ConnectionCheckStep]
    public let devices: [String: [ConnectionCheckStep]]

    public static func assess(devices: [DeviceInfo], assessments: [String: AdapterAssessment],
                              isMonitoring: Bool = true, isSuspended: Bool = false) -> ConnectionCheckReport {
        let physical = devices.filter { !$0.isVirtual }
        let status: ConnectionCheckStatus = !isMonitoring || isSuspended || physical.isEmpty ? .attention : .passed
        let detail = isSuspended ? "发现已随系统睡眠暂停，唤醒后刷新系统属性；不会自动查询设备。"
            : !isMonitoring ? "发现服务未运行。请重新打开应用并检查服务日志。"
            : physical.isEmpty ? "系统尚未发布物理 Razer HID。请检查 USB/接收器或系统蓝牙连接，再刷新；非 HID 外设可能不在此列表。"
            : "系统已发布 \(physical.count) 台物理设备。接收器存在不能证明无线外设在线。"
        return .init(steps: [.init(id: "discovery", title: "系统设备发现", status: status, detail: detail),
                             .init(id: "privacy", title: "检查范围", status: .information,
                                   detail: "仅读取已有状态；不收集输入，不申请额外权限。手动查询需从设备页明确发起。")],
                     devices: Dictionary(uniqueKeysWithValues: devices.compactMap { device in
                         assessments[device.id].map { (device.id, deviceSteps(device, assessment: $0)) }
                     }))
    }

    private static func deviceSteps(_ device: DeviceInfo, assessment: AdapterAssessment) -> [ConnectionCheckStep] {
        var steps: [ConnectionCheckStep] = [
            .init(id: "interface", title: device.isVirtual ? "虚拟设备" : "适配接口",
                  status: assessment.interfaceMatched ? .passed : .information, detail: assessment.connectionEvidence)
        ]
        for capability in assessment.capabilities where capability.session.state == .failed || capability.session.state == .unconfirmed {
            let session = capability.session
            let suggestion: String
            switch session.failureKind {
            case .permissionDenied: suggestion = "查看该接口的访问错误与驱动绑定；不需要为被动枚举授予全部隐私权限。"
            case .timeout, .busy: suggestion = "确认外设开机且连接稳定；稍后手动重试，超时不等于设备已离线。"
            case .protocolMismatch, .invalidData: suggestion = "停止本轮操作并导出诊断，核对具体接口、固件及其他控制软件；不要轮试命令。"
            case .notPublished: suggestion = "macOS 未提供可用属性或身份。可以检查系统蓝牙连接；不会按名称猜测电量。"
            case .disconnected: suggestion = "刷新设备列表，再从当前连接发起操作。"
            default: suggestion = "查看本次错误与日志；导出诊断以核对适配条件。"
            }
            steps.append(.init(id: capability.id, title: "\(capability.title) · \(session.failureKind?.title ?? session.state.title)",
                status: .attention, detail: "\(session.detail) \(suggestion)"))
        }
        if steps.count == 1 {
            steps.append(.init(id: "readStatus", title: assessment.readingSummary, status: .information,
                detail: "已有读数仅代表取得时的状态。未读取时可从设备页手动查询；报告本身不发送命令。"))
        }
        if !device.observedDrivers.isEmpty {
            steps.append(.init(id: "drivers", title: "观察到 Razer 驱动绑定", status: .information,
                detail: "可能与控制接口共享访问；仅凭驱动存在不能判定冲突。应用不会停止或卸载它们。"))
        }
        return steps
    }
}
