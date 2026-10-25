import Foundation
import IOKit
import IOKit.hid

enum HIDOperationExecutor {
    static let queue = DispatchQueue(label: "local.RazerLite.feature-operations", qos: .userInitiated)
}

/// Internal data transport. Construction and all I/O occur on the query service's serial worker.
protocol HIDFeatureTransport: AnyObject {
    func send(_ bytes: [UInt8], reportID: Int) throws
    func receive(reportID: Int, length: Int) throws -> [UInt8]
    func close()
}

final class NativeHIDFeatureTransport: HIDFeatureTransport {
    private let device: IOHIDDevice
    private var isOpen = false

    init(interface expected: HIDInterface) throws {
        guard let matching = IORegistryEntryIDMatching(expected.id) else { throw MouseQueryError.deviceChanged }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { throw MouseQueryError.deviceChanged }
        defer { IOObjectRelease(service) }
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service),
              let current = HIDPropertyReader.read(device), current.matchesSession(expected) else {
            throw MouseQueryError.deviceChanged
        }
        self.device = device
        // Normal shared open, never kIOHIDOptionsTypeSeizeDevice. No input callbacks or scheduling.
        let result = IOHIDDeviceOpen(device, 0)
        guard result == kIOReturnSuccess else { throw MouseQueryError.io(operation: "打开查询接口", code: result) }
        isOpen = true
    }

    deinit { close() }

    func send(_ bytes: [UInt8], reportID: Int) throws {
        guard isOpen else { throw MouseQueryError.deviceChanged }
        guard !bytes.isEmpty else { throw MouseQueryError.malformed("不能发送空报文") }
        let result = bytes.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, reportID, $0.baseAddress!, $0.count)
        }
        guard result == kIOReturnSuccess else { throw MouseQueryError.io(operation: "发送状态查询", code: result) }
    }

    func receive(reportID: Int, length: Int) throws -> [UInt8] {
        guard isOpen else { throw MouseQueryError.deviceChanged }
        guard length > 0 else { throw MouseQueryError.malformed("接收缓冲区为空") }
        var bytes = [UInt8](repeating: 0, count: length)
        var returnedLength = length
        let result = bytes.withUnsafeMutableBufferPointer {
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, reportID, $0.baseAddress!, &returnedLength)
        }
        guard result == kIOReturnSuccess else { throw MouseQueryError.io(operation: "读取状态响应", code: result) }
        guard (0...length).contains(returnedLength) else { throw MouseQueryError.malformed("系统返回的长度超出缓冲区") }
        return Array(bytes.prefix(returnedLength))
    }

    func close() {
        if isOpen { IOHIDDeviceClose(device, 0); isOpen = false }
    }
}
