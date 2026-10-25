import Foundation
import RazerLiteCore

@main
struct RazerLiteProbe {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") {
            print("razerlite-probe [--all] [--watch SECONDS] [READ_OPTION] [--device-id ID]\n默认仅枚举属性；READ_OPTION 一次只选一个：\n--read-mouse 显式发送 Viper V4 Pro 电量与 DPI 查询，无设置命令。\n--read-polling-rate 仅读取 Viper V4 Pro 回报率配置，不设置频率，也不是实测输入频率。\n--read-charging 独立读取 Viper V4 Pro 充电标志，不修改设置。\n--read-system-battery 按需读取一台蓝牙 Razer 设备的 macOS 电量，不发送 Feature Report。\n--read-keyboard-battery 试读 1532:02D2 键盘电量，macOS 真机兼容性待验证。\n--read-keyboard-charging 独立试读同一键盘的充电标志，不切换模式或设置设备。\n--watch 向 stderr 输出插拔事件，结束时 stdout 输出 JSON；不能与读取选项组合。")
            return
        }
        var duration = 0.0
        var all = false
        var readMouse = false
        var readSystemBattery = false
        var readPolling = false
        var readCharging = false
        var readKeyboardBattery = false
        var readKeyboardCharging = false
        var selectedID: String?
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--all": all = true
            case "--read-mouse": readMouse = true
            case "--read-system-battery": readSystemBattery = true
            case "--read-polling-rate": readPolling = true
            case "--read-charging": readCharging = true
            case "--read-keyboard-battery": readKeyboardBattery = true
            case "--read-keyboard-charging": readKeyboardCharging = true
            case "--device-id":
                index += 1
                guard index < args.count else { fail("--device-id 需要枚举结果中的设备 ID。") }
                selectedID = args[index]
            case "--watch":
                index += 1
                guard index < args.count, let seconds = Double(args[index]), seconds.isFinite,
                      seconds > 0, seconds <= 3600 else { fail("--watch 需要 0 到 3600 之间的秒数（不含 0）。") }
                duration = seconds
            default: fail("未知参数：\(args[index])。使用 --help 查看用法。")
            }
            index += 1
        }
        let readCount = [readMouse, readSystemBattery, readPolling, readCharging, readKeyboardBattery, readKeyboardCharging].filter { $0 }.count
        if readCount > 1 { fail("请一次选择一个读取后端。") }
        if readCount > 0 && duration > 0 { fail("读取选项与 --watch 不能组合；读取为单次显式操作。") }
        if selectedID != nil && readCount == 0 { fail("--device-id 仅用于读取选项。") }
        let started = ContinuousClock.now
        var records: [HIDInterface] = []
        let discovery = HIDDiscovery(razerOnly: !all)
        discovery.onChange = { interfaces, reason in
            records = interfaces
            if duration > 0 { stderr("\(Date().ISO8601Format()) \(reason)") }
        }
        discovery.onError = { stderr($0) }
        discovery.start()
        defer { discovery.stop() }
        stderr("discoveryReady=\(started.duration(to: .now)); interfaces=\(records.count)")
        if duration > 0 { watch(for: duration) }
        var readouts: [String: MouseTelemetry] = [:]
        var systemBatteries: [String: SystemBatteryReading] = [:]
        var pollingReadouts: [String: MousePollingReading] = [:]
        var chargingReadouts: [String: MouseChargingReading] = [:]
        var keyboardBatteries: [String: KeyboardPowerReading] = [:]
        var keyboardCharging: [String: KeyboardPowerReading] = [:]
        var queryFailed = false
        let keyboardField: KeyboardPowerField? = readKeyboardBattery ? .battery : readKeyboardCharging ? .charging : nil
        if let field = keyboardField {
            let candidates = DeviceInfo.group(records).filter {
                KeyboardPowerReadService.canRead($0) && (selectedID == nil || $0.id == selectedID)
            }
            guard candidates.count == 1, let device = candidates.first else {
                fail("未找到唯一可试读的 BlackWidow Low-profile TKL 1532:02D2；多台设备请用 --device-id 指定。")
            }
            stderr("手动试读键盘\(field.title)；macOS 硬件兼容性待验证，不切换设备模式。")
            var reading: KeyboardPowerReading?
            Task { @MainActor in
                reading = await KeyboardPowerReadService().read(device, field: field)
                CFRunLoopStop(CFRunLoopGetMain())
            }
            CFRunLoopRun()
            guard let reading else { fail("键盘电源状态未返回结果。") }
            discovery.refresh()
            guard let current = DeviceInfo.group(records).first(where: { $0.id == device.id }), current == device else {
                fail("读取期间设备已变化，未导出旧状态。")
            }
            if field == .battery { keyboardBatteries[device.id] = reading }
            else { keyboardCharging[device.id] = reading }
            queryFailed = !reading.hasValue
            if let issue = reading.issue { stderr("\(issue.kind?.title ?? "读取失败")：\(issue.message)") }
        }
        if readMouse {
            let candidates = DeviceInfo.group(records).filter {
                MouseReadService.canRead($0) && (selectedID == nil || $0.id == selectedID)
            }
            guard candidates.count == 1, let device = candidates.first else {
                fail("未找到唯一可查询的 Viper V4 Pro；多台设备请用 --device-id 指定枚举 ID。")
            }
            stderr("手动查询：\(device.product)，仅电量与 DPI。")
            let reading = readOnce(device)
            readouts[device.id] = reading
            queryFailed = !reading.isComplete
            for issue in reading.issues { stderr("\(issue.field): \(issue.message)") }
        }
        if readPolling {
            let candidates = DeviceInfo.group(records).filter {
                PollingRateReadService.canRead($0) && (selectedID == nil || $0.id == selectedID)
            }
            guard candidates.count == 1, let device = candidates.first else {
                fail("未找到唯一可读取回报率的 Viper V4 Pro；多台设备请用 --device-id 指定。")
            }
            var reading: MousePollingReading?
            Task { @MainActor in
                reading = await PollingRateReadService().read(device)
                CFRunLoopStop(CFRunLoopGetMain())
            }
            CFRunLoopRun()
            guard let reading else { fail("回报率读取未返回结果。") }
            discovery.refresh()
            guard let current = DeviceInfo.group(records).first(where: { $0.id == device.id }), current == device else {
                fail("读取期间设备已变化，未导出旧状态。")
            }
            pollingReadouts[device.id] = reading
            queryFailed = reading.configuredHertz == nil
            if let issue = reading.issue { stderr("\(issue.kind?.title ?? "读取失败")：\(issue.message)") }
        }
        if readCharging {
            let candidates = DeviceInfo.group(records).filter {
                ChargingReadService.canRead($0) && (selectedID == nil || $0.id == selectedID)
            }
            guard candidates.count == 1, let device = candidates.first else {
                fail("未找到唯一可读取充电状态的 Viper V4 Pro；多台设备请用 --device-id 指定。")
            }
            var reading: MouseChargingReading?
            Task { @MainActor in
                reading = await ChargingReadService().read(device)
                CFRunLoopStop(CFRunLoopGetMain())
            }
            CFRunLoopRun()
            guard let reading else { fail("充电状态读取未返回结果。") }
            discovery.refresh()
            guard let current = DeviceInfo.group(records).first(where: { $0.id == device.id }), current == device else {
                fail("读取期间设备已变化，未导出旧状态。")
            }
            chargingReadouts[device.id] = reading
            queryFailed = reading.state == nil
            if let issue = reading.issue { stderr("\(issue.kind?.title ?? "读取失败")：\(issue.message)") }
        }
        if readSystemBattery {
            let candidates = DeviceInfo.group(records).filter {
                SystemBatteryService.canRead($0) && (selectedID == nil || $0.id == selectedID)
            }
            guard candidates.count == 1, let device = candidates.first else {
                fail("未找到唯一可读取系统电量的蓝牙设备；多台设备请用 --device-id 指定。")
            }
            var reading: SystemBatteryReading?
            Task { @MainActor in
                reading = await SystemBatteryService().read(device)
                CFRunLoopStop(CFRunLoopGetMain())
            }
            CFRunLoopRun()
            guard let reading else { fail("系统电量读取未返回结果。") }
            // Refresh identity once more before exporting a potentially slow system snapshot.
            discovery.refresh()
            guard let current = DeviceInfo.group(records).first(where: { $0.id == device.id }), current == device else {
                fail("读取期间设备已变化，未导出旧状态。")
            }
            systemBatteries[device.id] = reading
            queryFailed = reading.percent == nil
            if let issue = reading.issue { stderr(issue) }
        }
        do {
            FileHandle.standardOutput.write(try DiagnosticSnapshot(interfaces: records, mouseReadouts: readouts,
                                                                  systemBatteryReadings: systemBatteries,
                                                                  pollingReadouts: pollingReadouts,
                                                                  chargingReadouts: chargingReadouts,
                                                                  keyboardBatteryReadouts: keyboardBatteries,
                                                                  keyboardChargingReadouts: keyboardCharging).jsonData())
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch { fail("诊断编码失败：\(error.localizedDescription)") }
        if queryFailed { discovery.stop(); exit(1) }
    }

    @MainActor
    private static func watch(for seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    @MainActor
    private static func readOnce(_ device: DeviceInfo) -> MouseTelemetry {
        var result: MouseTelemetry?
        Task { @MainActor in
            result = await MouseReadService().read(device)
            CFRunLoopStop(CFRunLoopGetMain())
        }
        // Preserve the CLI's main CF run loop while its serial I/O worker handles the query.
        CFRunLoopRun()
        guard let result else { fail("查询未返回结果。") }
        return result
    }

    static func stderr(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
    static func fail(_ message: String) -> Never { stderr(message); exit(1) }
}
