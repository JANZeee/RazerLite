import Foundation
import Testing
@testable import RazerLiteCore

struct ObservedModelCatalogTests {
    private func interface(_ id: UInt64, pid: Int = 0x02F5, vendor: Int = 0x1532,
                           name: String = "Razer Reclusa Mini 65%", transport: String = "USB",
                           usage: Int = 6, virtual: Bool = false, usbID: UInt64 = 100) -> HIDInterface {
        .init(id: id, vendorID: vendor, productID: pid, product: name, manufacturer: nil,
              transport: transport, locationID: nil, versionNumber: nil, usbDeviceID: usbID,
              usbInterfaceNumber: Int(id), usbDeviceRelease: nil, primaryUsagePage: usage == 1 ? 12 : 1,
              primaryUsage: usage, usages: [], maxInputReportSize: usage == 1 ? 0 : 8,
              maxOutputReportSize: 0, maxFeatureReportSize: usage == 1 ? 90 : 0,
              registryClass: "Fixture", observedDrivers: [], isVirtual: virtual)
    }

    @Test func compositeKeyboardKeepsObservedIdentityAndUsesReviewedKeyboardRoutes() throws {
        let device = DeviceInfo.group([interface(0, usage: 2), interface(1), interface(2), interface(3, usage: 1)])[0]
        #expect(device.interfaces.count == 4)
        #expect(device.kind == .keyboard)
        #expect(device.modelReference?.source == .localObservation)
        #expect(device.product == "Razer Reclusa Mini 65%")
        #expect(RazerModelCatalog.lookup(vendorID: 0x1532, productID: 0x02F5) == nil)
        #expect(DeviceReadRegistry.backends(for: device) == [.reclusaMini65USB])
        #expect(AdapterManifestCatalog.manifest(for: device)?.id == AdapterManifestCatalog.reclusaLighting.id)
        let assessment = AdapterCatalog.assess(device)
        #expect(assessment.interfaceMatched && ReclusaBrightnessReadService.canRead(device))
        #expect(assessment.sourceURL == AdapterManifestCatalog.reclusaLighting.sources.first?.url)
        #expect(assessment.capabilities.filter(\.routeAvailable).map(\.id) == ["discovery", "polling", "pollingWrite", "brightness", "brightnessWrite", "battery", "charging"])
        for id in ["rgb", "dpiWrite"] {
            #expect(assessment.capability(id)?.implementation == .notImplemented)
        }
        let snapshot = DiagnosticSnapshot(interfaces: device.interfaces)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticSnapshot.self, from: snapshot.jsonData())
        #expect(decoded.devices.first?.kind == .keyboard)
        #expect(decoded.adapterAssessments?[device.id]?.sourceURL == AdapterManifestCatalog.reclusaLighting.sources.first?.url)
    }

    @Test func nearbyModelsNamesTransportsAndVirtualDevicesCannotBorrowObservation() {
        let candidates = [
            interface(1, pid: 0x02E3), interface(1, pid: 0x02F4), interface(1, vendor: 0x068E),
            interface(1, name: "Razer Reclusa X Mini 65%"), interface(1, name: ""),
            interface(1, transport: "Bluetooth"), interface(1, transport: "Bluetooth Low Energy"),
            interface(1, transport: "未知"), interface(1, virtual: true), interface(1, usage: 1)
        ]
        for candidate in candidates {
            let device = DeviceInfo.group([candidate])[0]
            #expect(ObservedModelCatalog.lookup(device) == nil)
            #expect(device.modelReference?.source != .localObservation)
            #expect(!MouseReadService.canRead(device))
            #expect(!KeyboardPowerReadService.canRead(device))
        }
        #expect(ObservedModelCatalog.lookup(.init(id: "empty", interfaces: [])) == nil)
    }

    @Test func inconsistentCompositeIdentityIsNotPromotedAndTwinKeyboardsRemainSeparate() {
        for other in [interface(2, pid: 0x02E3), interface(2, vendor: 0x1234),
                      interface(2, name: "Other"), interface(2, transport: "Bluetooth")] {
            let device = DeviceInfo.group([interface(1), other])[0]
            #expect(ObservedModelCatalog.lookup(device) == nil)
        }
        let twins = DeviceInfo.group([interface(1), interface(2, usbID: 200)])
        #expect(twins.count == 2)
        #expect(twins.allSatisfy { $0.kind == .keyboard && DeviceReadRegistry.backends(for: $0).isEmpty })
    }

    @Test func mergedDirectoryRetainsDistinctSources() {
        #expect(RazerModelCatalog.entries.count == 273)
        let entries = AdapterCatalog.modelEntries
        #expect(Set(entries.map(\.productID)).count == entries.count)
        #expect(entries.first { $0.productID == 0x02F5 }?.source == .localObservation)
        #expect(entries.first { $0.productID == 0x00E6 }?.source == .adapterManifest)
        #expect(entries.first { $0.productID == 0x0203 }?.source == .openRazer)
    }

    #if DEBUG
    @MainActor @Test func offlineUnreadScenarioDoesNotCreateReadings() async throws {
        let session = try OfflineScenarioSession()
        await session.load(.observedKeyboard)
        let device = try #require(session.manager.physicalDevices.first)
        #expect(device.interfaces.count == 4 && device.kind == .keyboard)
        #expect(session.manager.mouseReadouts.isEmpty)
        #expect(session.manager.keyboardBatteryReadouts.isEmpty && session.manager.keyboardBrightnessReadouts.isEmpty)
        #expect(DeviceReadRegistry.backends(for: device) == [.reclusaMini65USB])
        #expect(await session.services.operations.isEmpty)
    }
    #endif
}
