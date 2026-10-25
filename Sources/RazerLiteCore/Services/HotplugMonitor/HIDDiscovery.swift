import Foundation
import IOKit.hid

@MainActor
public protocol HIDDiscovering: AnyObject {
    var onChange: (([HIDInterface], String) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func start()
    func refresh()
    func stop()
}

/// Discovery only: no Open, GetReport, SetReport, seizure, or input callbacks.
/// All callbacks run on the scheduled main run loop; stop unregisters them before release.
@MainActor
public final class HIDDiscovery: HIDDiscovering {
    public var onChange: (([HIDInterface], String) -> Void)?
    public var onError: ((String) -> Void)?
    private let razerOnly: Bool
    private var manager: IOHIDManager?
    private var records: [UInt64: HIDInterface] = [:]
    private var deviceIDs: [IOHIDDevice: UInt64] = [:]

    public init(razerOnly: Bool = true) { self.razerOnly = razerOnly }

    isolated deinit { stop() }

    public func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        self.manager = manager
        if razerOnly {
            // Bluetooth devices can publish Razer's SIG company identifier
            // instead of the USB VID. Filter transport after reading properties.
            IOHIDManagerSetDeviceMatchingMultiple(manager, [
                [kIOHIDVendorIDKey: 0x1532],
                [kIOHIDVendorIDKey: 0x068E]
            ] as CFArray)
        } else {
            IOHIDManagerSetDeviceMatching(manager, nil)
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<HIDDiscovery>.fromOpaque(context).takeUnretainedValue().matched(device, result: result)
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, result, _, device in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<HIDDiscovery>.fromOpaque(context).takeUnretainedValue().removed(device, result: result)
            }
        }, context)
        // Also deliver removals while native menus track events, so old reads/plans are invalidated promptly.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        refresh()
    }

    public func refresh() {
        guard let manager else { return }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        records.removeAll(keepingCapacity: true)
        deviceIDs.removeAll(keepingCapacity: true)
        for device in devices {
            if let record = HIDPropertyReader.read(device) {
                guard !razerOnly || record.isRazer else { continue }
                records[record.id] = record
                deviceIDs[device] = record.id
            } else { onError?("一个 HID 接口的属性已不可用；可能在枚举过程中断开。") }
        }
        publish("只读枚举完成：\(records.count) 个 HID 接口")
    }

    public func stop() {
        guard let manager else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.manager = nil
        records.removeAll()
        deviceIDs.removeAll()
    }

    private func matched(_ device: IOHIDDevice, result: IOReturn) {
        guard result == kIOReturnSuccess else { onError?("HID 匹配失败：\(hexID(Int(UInt32(bitPattern: result)), width: 8))"); return }
        guard let record = HIDPropertyReader.read(device) else { onError?("无法读取新 HID 接口的属性。") ; return }
        guard !razerOnly || record.isRazer else { return }
        deviceIDs[device] = record.id
        guard records[record.id] != record else { return }
        records[record.id] = record
        publish("接口接入：\(record.product) · \(record.id)")
    }

    private func removed(_ device: IOHIDDevice, result: IOReturn) {
        if result != kIOReturnSuccess { onError?("HID 移除通知：\(hexID(Int(UInt32(bitPattern: result)), width: 8))") }
        guard let id = deviceIDs.removeValue(forKey: device), let record = records.removeValue(forKey: id) else { return }
        publish("接口移除：\(record.product) · \(id)")
    }

    private func publish(_ reason: String) { onChange?(records.values.sorted { $0.id < $1.id }, reason) }
}
