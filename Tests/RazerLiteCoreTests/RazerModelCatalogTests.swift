import Testing
@testable import RazerLiteCore

struct RazerModelCatalogTests {
    @Test func referenceIdentitiesStayDistinctAndNeverGrantControl() {
        #expect(RazerModelCatalog.entries.count == 273)
        #expect(Set(RazerModelCatalog.entries.map(\.productID)).count == RazerModelCatalog.entries.count)
        #expect(RazerModelCatalog.lookup(vendorID: 0x1532, productID: 0x00A6)?.name.contains("Viper V2 Pro") == true)
        #expect(RazerModelCatalog.lookup(vendorID: 0x1532, productID: 0x007A)?.name.contains("Viper Ultimate") == true)
        #expect(RazerModelCatalog.lookup(vendorID: 0x1532, productID: 0x00A3)?.name == "Razer Cobra")
        #expect(RazerModelCatalog.lookup(vendorID: 0x046D, productID: 0x00A3) == nil)
        let device = DeviceInfo.group([MouseReadServiceTests().controlInterface(pid: 0x00A6)])[0]
        #expect(device.kind == .mouse)
        #expect(!MouseReadService.canRead(device))
        let assessment = AdapterCatalog.assess(device)
        #expect(assessment.sourceURL == RazerModelCatalog.sourceURL)
        #expect(assessment.capabilities.filter { $0.session.state == .succeeded }.map(\.id) == ["discovery"])
    }

    @Test func unknownPIDKeepsSystemInformationWithoutInventingModelOrCommands() {
        let device = DeviceInfo.group([MouseReadServiceTests().controlInterface(pid: 0xEEEE)])[0]
        #expect(device.productID == 0xEEEE)
        #expect(device.product == "Viper fixture")
        #expect(device.modelReference == nil)
        #expect(device.kind == .unknown)
        #expect(!MouseReadService.canRead(device))
        #expect(AdapterCatalog.assess(device).capabilities.first?.session.state == .succeeded)
    }

    @Test func audioAndKeyboardReferencesDoNotBecomeMice() {
        let keyboard = DeviceInfo.group([MouseReadServiceTests().controlInterface(pid: 0x0203)])[0]
        #expect(keyboard.kind == .keyboard)
        let audio = RazerModelCatalog.entries.first { $0.kind == .audio }!
        let headset = DeviceInfo.group([MouseReadServiceTests().controlInterface(pid: audio.productID)])[0]
        #expect(headset.kind == .audio)
        #expect(!MouseReadService.canRead(headset))
    }
}
