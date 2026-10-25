import Foundation
import Testing
@testable import RazerLiteCore

struct SystemBatteryTests {
    static let address = "112233445566"
    static func device(id: UInt64 = 42, pid: Int = 0x00D5, transport: String = "Bluetooth Low Energy", virtual: Bool = false) -> DeviceInfo {
        DeviceInfo.group([HIDInterface(id: id, vendorID: 0x068E, productID: pid, product: "BSK MOBILE", manufacturer: "Razer",
                                      transport: transport, locationID: nil, versionNumber: 1, usbDeviceID: nil,
                                      usbInterfaceNumber: nil, usbDeviceRelease: nil, primaryUsagePage: 1, primaryUsage: 2,
                                      usages: [], maxInputReportSize: 9, maxOutputReportSize: 1, maxFeatureReportSize: 1,
                                      registryClass: "IOHIDUserDevice", observedDrivers: [], isVirtual: virtual)])[0]
    }
    static func fields(address: String = "11:22:33:44:55:66", battery: String? = "73%", vendor: String = "0x068E") -> [String: String] {
        var fields = ["device_address": address, "device_vendorID": vendor, "device_productID": "0x00D5"]
        fields["device_batteryLevelMain"] = battery
        return fields
    }
    static func data(connected: [[String: [String: String]]], disconnected: [[String: [String: String]]] = []) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["SPBluetoothDataType": [["device_connected": connected, "device_not_connected": disconnected]]])
    }

    @Test func matchesAddressAndIDsInsteadOfNamesAndIgnoresDisconnectedEntries() throws {
        let snapshot = try Self.data(connected: [
            ["BSK MOBILE": Self.fields(address: "AA:BB:CC:DD:EE:FF", battery: "1%")],
            ["Renamed Mouse": Self.fields(battery: "0%")]
        ], disconnected: [["BSK MOBILE": Self.fields(battery: "100%")]])
        #expect(try BluetoothBatterySnapshot.percent(snapshot, address: Self.address, vendorID: 0x068E, productID: 0x00D5) == 0)
        #expect(BluetoothBatterySnapshot.address("11-22-33-44-55-66") == Self.address)
        #expect(BluetoothBatterySnapshot.address("prefix 11:22:33:44:55:66") == nil)
        #expect(BluetoothBatterySnapshot.address("11:22:33:44:55:6G") == nil)
    }

    @Test(arguments: ["101%", "-1%", "73.5%", "unknown", "0.8", "", "+50%"])
    func rejectsInvalidBatteryValues(_ raw: String) throws {
        let snapshot = try Self.data(connected: [["BSK MOBILE": Self.fields(battery: raw)]])
        #expect(throws: SystemBatteryError.self) {
            try BluetoothBatterySnapshot.percent(snapshot, address: Self.address, vendorID: 0x068E, productID: 0x00D5)
        }
    }

    @Test func rejectsDuplicateMissingIdentityAndDisconnectedSnapshots() throws {
        let cases = [
            try Self.data(connected: [["A": Self.fields()], ["B": Self.fields()]]),
            try Self.data(connected: [["A": Self.fields(vendor: "0x1532")]]),
            try Self.data(connected: [["A": Self.fields(battery: nil)]]),
            try Self.data(connected: [], disconnected: [["A": Self.fields()]]),
            Data("{}".utf8)
        ]
        for data in cases {
            #expect(throws: (any Error).self) {
                try BluetoothBatterySnapshot.percent(data, address: Self.address, vendorID: 0x068E, productID: 0x00D5)
            }
        }
    }

    @Test func backendRegistrySeparatesUSBAndBluetoothAndNeverEnablesPrivateQueriesByName() {
        let device = Self.device()
        #expect(DeviceReadRegistry.backends(for: device) == [.macOSBluetoothBattery])
        #expect(DeviceReadRegistry.backends(for: Self.device(transport: "USB")).isEmpty)
        #expect(DeviceReadRegistry.backends(for: Self.device(virtual: true)).isEmpty)
        #expect(DeviceReadRegistry.backends(for: Self.device(pid: 0x00E6)) == [.macOSBluetoothBattery])
        #expect(DeviceReadRegistry.backends(for: DeviceInfo.group([MouseReadServiceTests().controlInterface()])[0]) == [.viperV4USB])
        #expect(!MouseReadService.canRead(device))
    }

    @Test func registryBatteryTakesPriorityAndZeroIsAValidValue() async throws {
        let loader = FixtureBatteryLoader(data: Data())
        let service = SystemBatteryService(resolver: FixtureBatteryResolver(target: .init(address: nil, registryPercent: 0)), loader: loader)
        let reading = await service.read(Self.device())
        #expect(reading.percent == 0 && reading.source == .hidRegistry && reading.issue == nil)
        #expect(await loader.calls == 0)
    }

    @Test func systemSnapshotHasSourceAndNoAddressesInDiagnosticExport() async throws {
        let data = try Self.data(connected: [["Renamed": Self.fields()]])
        let loader = FixtureBatteryLoader(data: data)
        let device = Self.device()
        let service = SystemBatteryService(resolver: FixtureBatteryResolver(target: .init(address: Self.address, registryPercent: nil)), loader: loader)
        let reading = await service.read(device)
        #expect(reading.percent == 73 && reading.source == .macOSBluetoothSnapshot && reading.issue == nil)
        #expect(await loader.calls == 1)
        #expect(reading.matches(device))
        #expect(!reading.matches(Self.device(id: 43)))
        let exported = try DiagnosticSnapshot(interfaces: device.interfaces, systemBatteryReadings: [device.id: reading]).jsonData()
        let text = String(decoding: exported, as: UTF8.self)
        #expect(!text.contains(Self.address) && !text.contains("11:22:33:44:55:66"))
        #expect(text.contains("system-metadata-read") && text.contains("macOSBluetoothSnapshot"))
        let assessment = AdapterCatalog.assess(device, systemBattery: reading)
        #expect(assessment.capabilities.first { $0.id == "battery" }?.session.state == .succeeded)
        #expect(assessment.capabilities.first { $0.id == "dpiWrite" }?.implementation == .notImplemented)
    }

    @Test func missingAddressDoesNotLaunchProcessAndFailureNeverInventsBattery() async throws {
        let loader = FixtureBatteryLoader(data: Data())
        let service = SystemBatteryService(resolver: FixtureBatteryResolver(target: .init(address: nil, registryPercent: nil)), loader: loader)
        let reading = await service.read(Self.device())
        #expect(reading.percent == nil && reading.source == nil && reading.issue != nil)
        #expect(await loader.calls == 0)
    }
}

private struct FixtureBatteryResolver: SystemBatteryTargetResolving {
    let target: SystemBatteryTarget
    func resolve(_ device: DeviceInfo) throws -> SystemBatteryTarget { target }
}

private actor FixtureBatteryLoader: BluetoothSnapshotLoading {
    let data: Data
    private(set) var calls = 0
    init(data: Data) { self.data = data }
    func load() async throws -> Data { calls += 1; return data }
}

@Suite(.serialized)
struct SystemSnapshotProcessTests {
    @Test func nativeProcessIsBoundedAndReportsFailure() async {
        var timeout = SystemProfilerSnapshotLoader()
        timeout.executable = URL(fileURLWithPath: "/bin/sleep")
        timeout.arguments = ["30"]
        timeout.timeout = 0.1
        let start = ContinuousClock.now
        await #expect(throws: SnapshotProcessError.timedOut) { try await timeout.load() }
        #expect(start.duration(to: .now) < .seconds(5))
        var limit = SystemProfilerSnapshotLoader()
        limit.executable = URL(fileURLWithPath: "/usr/bin/yes")
        limit.arguments = []
        limit.outputLimit = 128
        await #expect(throws: SnapshotProcessError.outputLimit) { try await limit.load() }
        var failure = SystemProfilerSnapshotLoader()
        failure.executable = URL(fileURLWithPath: "/usr/bin/false")
        failure.arguments = []
        await #expect(throws: SnapshotProcessError.failed) { try await failure.load() }
    }

    @Test func cancelledReadDoesNotLeaveChildRunning() async throws {
        var loader = SystemProfilerSnapshotLoader()
        loader.executable = URL(fileURLWithPath: "/bin/sleep")
        loader.arguments = ["30"]
        let task = Task { try await loader.load() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
