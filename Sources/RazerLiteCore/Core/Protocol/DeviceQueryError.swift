import Foundation

enum DeviceQueryError: Error, LocalizedError, Equatable {
    case unsupportedDevice
    case deviceChanged
    case unavailableInterface
    case io(operation: String, code: Int32)
    case malformed(String)
    case mismatchedResponse(transaction: UInt8, commandClass: UInt8, commandID: UInt8)
    case rejected(UInt8)
    case busyTimeout

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice: "当前设备或连接方式没有可用的已审查查询适配器。"
        case .deviceChanged: "设备或接口已变化，请刷新列表后重试。"
        case .unavailableInterface: "未找到符合已审查协议的 90 字节查询接口。"
        case let .io(operation, code):
            "\(operation)失败（\(hexID(Int(UInt32(bitPattern: code)), width: 8))）。接口可能被系统、现有驱动限制或已断开。"
        case let .malformed(reason): "响应无效：\(reason)"
        case let .mismatchedResponse(transaction, commandClass, commandID):
            "响应不匹配（事务 \(hexID(Int(transaction), width: 2))，命令 \(hexID(Int(commandClass), width: 2))/\(hexID(Int(commandID), width: 2))）；可能存在并发控制，已停止查询。"
        case let .rejected(status): "设备返回失败状态 \(hexID(Int(status), width: 2))。"
        case .busyTimeout: "设备持续忙碌，查询已结束；稍后可手动重试。"
        }
    }
}

typealias MouseQueryError = DeviceQueryError
