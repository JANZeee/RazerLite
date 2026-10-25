import Darwin
import Foundation
import IOKit

/// A stable, presentation-friendly category for an unsuccessful explicit read.
/// It describes the observed failure only; it does not describe device power state.
public enum ReadFailureKind: String, Codable, Equatable, Sendable, CaseIterable {
    case unavailable
    case unsupported
    case deviceRejected
    case notPublished
    case disconnected
    case timeout
    case busy
    case protocolMismatch
    case invalidData
    case permissionDenied
    case io
    case cancelled
    case unknown

    /// Short Chinese label for UI and diagnostic summaries.
    public var title: String {
        switch self {
        case .unavailable: "不可用"
        case .unsupported: "未支持"
        case .deviceRejected: "设备未接受"
        case .notPublished: "系统未发布"
        case .disconnected: "已断开"
        case .timeout: "超时"
        case .busy: "设备忙碌"
        case .protocolMismatch: "响应不匹配"
        case .invalidData: "数据无效"
        case .permissionDenied: "权限不足"
        case .io: "输入输出错误"
        case .cancelled: "已取消"
        case .unknown: "未知错误"
        }
    }
}

/// Shared classifications for known read errors and platform error domains.
enum ReadFailureClassifier {
    /// The single classification entry point for explicit read services.
    static func classify(_ error: any Error) -> ReadFailureKind {
        if let common = commonKind(for: error) { return common }
        if let error = error as? MouseQueryError { return mouseQueryKind(for: error) }
        if let error = error as? SystemBatteryError { return systemBatteryKind(for: error) }
        if let error = error as? SnapshotProcessError { return snapshotProcessKind(for: error) }
        return .unknown
    }

    static func commonKind(for error: any Error) -> ReadFailureKind? {
        if error is CancellationError { return .cancelled }

        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain {
            switch error.code {
            case Int(EACCES), Int(EPERM): return .permissionDenied
            case Int(ETIMEDOUT): return .timeout
            case Int(ENODEV), Int(ENXIO), Int(ENOTCONN): return .disconnected
            default: return .io
            }
        }
        if error.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: error.code) {
            case .fileReadNoPermission, .fileWriteNoPermission: return .permissionDenied
            default: return nil
            }
        }
        return nil
    }

    static func ioKind(for code: Int32) -> ReadFailureKind {
        switch code {
        case kIOReturnNotPermitted, kIOReturnNotPrivileged:
            .permissionDenied
        case kIOReturnTimeout:
            .timeout
        case kIOReturnNoDevice, kIOReturnNotAttached:
            .disconnected
        default:
            .io
        }
    }

    private static func mouseQueryKind(for error: MouseQueryError) -> ReadFailureKind {
        switch error {
        case .unavailableInterface: .unavailable
        case .unsupportedDevice: .unsupported
        case .deviceChanged: .disconnected
        case let .io(_, code): ioKind(for: code)
        case .busyTimeout: .busy
        case .mismatchedResponse: .protocolMismatch
        case .malformed: .invalidData
        case let .rejected(status):
            switch status {
            case 0x04: .timeout
            case 0x05: .unsupported
            default: .deviceRejected
            }
        }
    }

    private static func systemBatteryKind(for error: SystemBatteryError) -> ReadFailureKind {
        switch error {
        case .unavailable: .unavailable
        case .deviceChanged, .disconnected: .disconnected
        case .missingAddress, .noBattery: .notPublished
        case .identityMismatch: .protocolMismatch
        case .invalidSnapshot, .ambiguous: .invalidData
        }
    }

    private static func snapshotProcessKind(for error: SnapshotProcessError) -> ReadFailureKind {
        switch error {
        case .timedOut: .timeout
        case .outputLimit: .invalidData
        case .failed: .io
        }
    }
}
