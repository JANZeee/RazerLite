import Testing
@testable import RazerLiteCore

struct BluetoothDiscoveryTests {
    func interface(vendor: Int = 0x068E, transport: String = "Bluetooth Low Energy", pid: Int = 0x00D5) -> HIDInterface {
        HIDInterface(id: 42, vendorID: vendor, productID: pid, product: "BSK MOBILE", manufacturer: "Razer",
                     transport: transport, locationID: nil, versionNumber: 1, usbDeviceID: nil,
                     usbInterfaceNumber: nil, usbDeviceRelease: nil, primaryUsagePage: 1, primaryUsage: 2,
                     usages: [HIDUsage(page: 1, usage: 2), HIDUsage(page: 1, usage: 6)],
                     maxInputReportSize: 9, maxOutputReportSize: 1, maxFeatureReportSize: 1,
                     registryClass: "IOHIDUserDevice", observedDrivers: [], isVirtual: false)
    }

    @Test func bluetoothCompanyIdentityIsAcceptedWithoutRewritingUSBIdentity() {
        #expect(interface().isRazer)
        #expect(interface(transport: "Bluetooth").isRazer)
        #expect(!interface(transport: "USB").isRazer)
        #expect(!interface(vendor: 0x004C).isRazer)
        let device = DeviceInfo.group([interface()])[0]
        #expect(device.isRazer)
        #expect(device.vendorID == 0x068E && device.productID == 0x00D5)
        #expect(device.kind == .mouse)
        #expect(!device.isVirtual)
        #expect(device.modelReference == nil)
        #expect(device.id == "hid-42")
    }

    @Test func bluetoothNeverReusesUSBPrivateQueriesOrWriteProfiles() {
        for pid in [0x00D5, 0x00E6, 0x02D2] {
            let device = DeviceInfo.group([interface(pid: pid)])[0]
            #expect(!MouseReadService.canRead(device))
            #expect(ProfileDeviceTarget(device: device) == nil)
            let assessment = AdapterCatalog.assess(device)
            #expect(assessment.capabilities.filter { $0.session.state == .succeeded }.map(\.id) == ["discovery"])
            #expect(assessment.adapterName == "Razer 蓝牙 HID · 系统电量")
        }
    }
}
