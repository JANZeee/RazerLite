import Foundation
import Testing
@testable import RazerLiteCore

struct DeviceTests {
    func interface(id: UInt64, usbID: UInt64? = 100, pid: Int = 0x00E6,
                           transport: String = "USB", isVirtual: Bool = false) -> HIDInterface {
        HIDInterface(id: id, vendorID: 0x1532, productID: pid, product: "Fixture", manufacturer: nil,
                     transport: transport, locationID: 0, versionNumber: 0x0101, usbDeviceID: usbID,
                     usbInterfaceNumber: Int(id % 5), usbDeviceRelease: 0x0101,
                     primaryUsagePage: 1, primaryUsage: 2, usages: [], maxInputReportSize: 8,
                     maxOutputReportSize: 0, maxFeatureReportSize: 90, registryClass: "Fixture",
                     observedDrivers: [], isVirtual: isVirtual)
    }

    @Test func multipleInterfacesGroupWithoutMergingIdenticalDevices() {
        let records = [interface(id: 1), interface(id: 2), interface(id: 3, usbID: 200)]
        let groups = DeviceInfo.group(records)
        #expect(groups.count == 2)
        #expect(groups.first { $0.id == "usb-100" }?.interfaces.count == 2)
    }

    @Test func missingIdentityAndVirtualDevicesNeverMergeByNameOrLocation() {
        #expect(DeviceInfo.group([interface(id: 1, usbID: nil), interface(id: 2, usbID: nil)]).count == 2)
        #expect(DeviceInfo.group([interface(id: 1), interface(id: 2, isVirtual: true)]).count == 2)
    }

    @Test func implementationAndEvidenceDoNotGuaranteeMatchingInterface() {
        let device = DeviceInfo.group([interface(id: 1)]).first!
        let assessment = AdapterCatalog.assess(device)
        #expect(assessment.capabilities.filter { $0.session.state == .succeeded }.map(\.id) == ["discovery"])
        #expect(assessment.capability("dpi")?.session.state == .unavailable)
        #expect(assessment.capabilities.first { $0.id == "firmware" }?.implementation == .notImplemented)
    }

    @Test func transportIsPartOfAdapterMatch() {
        let device = DeviceInfo.group([interface(id: 1, transport: "Bluetooth")]).first!
        let assessment = AdapterCatalog.assess(device)
        #expect(DeviceReadRegistry.backends(for: device) == [.macOSBluetoothBattery])
        #expect(!MouseReadService.canRead(device))
        #expect(assessment.capabilities.first { $0.id == "dpi" }?.implementation == .notImplemented)
        #expect(assessment.capabilities.first { $0.id == "battery" }?.session.state == .notRead)
    }

    @Test func keyboardDoesNotReuseMouseCapabilitiesOrNeighbouringPID() {
        let keyboard = AdapterCatalog.assess(DeviceInfo.group([interface(id: 1, pid: 0x02D2)]).first!)
        #expect(keyboard.capability("rgb")?.implementation == .notImplemented)
        #expect(keyboard.capabilities.first { $0.id == "dpi" }?.implementation == .notImplemented)
        #expect(AdapterCatalog.assess(DeviceInfo.group([interface(id: 1, pid: 0x02D4)]).first!).sourceURL == nil)
    }

    @Test func successfulReadDoesNotApplyWritesOrAffectOtherFieldsOrConnections() {
        let device = DeviceInfo.group([MouseReadServiceTests().controlInterface()])[0]
        let value = MouseTelemetry(deviceID: device.id, interfaceID: 3, readAt: Date(), batteryPercent: 60, dpi: nil,
                                   issues: [MouseReadIssue(field: "dpi", message: "synthetic failure")])
        let capabilities = AdapterCatalog.assess(device, telemetry: value).capabilities
        #expect(capabilities.first { $0.id == "battery" }?.session.state == .succeeded)
        #expect(capabilities.first { $0.id == "dpi" }?.session.state == .failed)
        #expect(capabilities.first { $0.id == "dpiWrite" }?.session.state == .notRequested)
        let reconnected = DeviceInfo.group([MouseReadServiceTests().controlInterface(id: 4)])[0]
        #expect(AdapterCatalog.assess(reconnected, telemetry: value).capabilities.first { $0.id == "battery" }?.session.state == .notRead)
    }

    @Test func diagnosticRoundTripAndNoClaimedFirmware() throws {
        let snapshot = DiagnosticSnapshot(interfaces: [interface(id: 1)])
        let data = try snapshot.jsonData()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticSnapshot.self, from: data)
        #expect(decoded.devices == snapshot.devices)
        #expect(decoded.schemaVersion == 9)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("firmwareVersion"))
        #expect(!text.contains("serialNumber"))
    }
}
