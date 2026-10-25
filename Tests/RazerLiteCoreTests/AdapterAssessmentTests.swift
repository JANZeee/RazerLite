import Foundation
import Testing
@testable import RazerLiteCore

struct AdapterAssessmentTests {
    private func mouse(id: UInt64 = 3, usbID: UInt64 = 100) -> DeviceInfo {
        DeviceInfo.group([MouseReadServiceTests().controlInterface(id: id, usbID: usbID)])[0]
    }

    @Test func manifestsSeparateEvidenceImplementationAndExecutableRoutes() throws {
        #expect(Set(AdapterManifestCatalog.all.map(\.id)).count == 3)
        for manifest in AdapterManifestCatalog.all {
            #expect(Set(manifest.features.map(\.id)).count == manifest.features.count)
            #expect(!manifest.sources.isEmpty && !manifest.firmwareScope.isEmpty)
            for feature in manifest.features {
                #expect(AdapterCatalog.featureTitles.contains { $0.0 == feature.id })
                #expect(!feature.records.isEmpty)
            }
        }
        let device = DeviceInfo.group([DeviceTests().interface(id: 1)])[0] // wrong Viper fingerprint
        let assessment = AdapterCatalog.assess(device)
        #expect(assessment.adapterID == AdapterManifestCatalog.viper.id)
        #expect(!assessment.interfaceMatched && DeviceReadRegistry.backends(for: device).isEmpty)
        let dpi = try #require(assessment.capability("dpi"))
        #expect(dpi.implementation == .implemented && dpi.evidence.level == .hardwareValidated)
        #expect(!dpi.routeAvailable && dpi.session.state == .unavailable)
        #expect(assessment.capability("pollingWrite")?.implementation == .notImplemented)
    }

    @Test func adapterModelsRemainVisibleEvenWhenAbsentFromUpstreamTable() {
        #expect(RazerModelCatalog.entries.count == 273)
        let entries = AdapterCatalog.modelEntries
        #expect(Set(entries.map(\.productID)).count == entries.count)
        for manifest in [AdapterManifestCatalog.viper, AdapterManifestCatalog.keyboard] {
            #expect(manifest.productIDs.allSatisfy { pid in entries.contains { $0.productID == pid } })
        }
        #expect(entries.first { $0.productID == 0x00E6 }?.kind == .mouse)
        #expect(entries.first { $0.productID == 0x02D2 }?.kind == .keyboard)
        #expect(AdapterManifestCatalog.bluetooth.matchesIdentity(DeviceInfo.group([BluetoothDiscoveryTests().interface(transport: "Bluetooth LE")])[0]))
    }

    @Test func duplicateControlInterfacesAndMixedIdentitiesNeverEnablePrivateRoutes() {
        let first = MouseReadServiceTests().controlInterface()
        let second = MouseReadServiceTests().controlInterface(id: 4)
        let ambiguous = DeviceInfo.group([first, second])[0]
        #expect(AdapterManifestCatalog.manifest(for: ambiguous) != nil)
        #expect(DeviceReadRegistry.backends(for: ambiguous).isEmpty)
        #expect(AdapterCatalog.assess(ambiguous).capability("battery")?.session.state == .unavailable)
        let mixed = DeviceInfo.group([first, DeviceTests().interface(id: 6, pid: 0xEEEE)])[0]
        #expect(AdapterManifestCatalog.manifest(for: mixed) == nil)
        #expect(DeviceReadRegistry.backends(for: mixed).isEmpty)
    }

    @Test func keyboardSuccessCannotPromoteEvidenceOrImplementRGB() throws {
        let device = KeyboardPowerFixtures().device()
        let value = KeyboardPowerReading(deviceID: device.id, interfaceID: device.interfaces[0].id, field: .battery,
            readAt: Date(), batteryPercent: 0, chargingState: nil, issue: nil)
        let assessment = AdapterCatalog.assess(device, keyboardBattery: value, simulation: true)
        let battery = try #require(assessment.capability("battery"))
        #expect(battery.implementation == .implemented && battery.session.state == .succeeded)
        #expect(battery.evidence.level == .simulationTested)
        #expect(battery.session.source?.contains("模拟") == true)
        #expect(assessment.capability("rgb")?.implementation == .notImplemented)
        #expect(assessment.capability("rgb")?.evidence.level == .sourceReviewed)
        #expect(assessment.capability("polling")?.implementation == .notImplemented)
        #expect(assessment.dataOrigin.contains("simulation-only"))
    }

    @Test func transientFailureLeavesHistoricalEvidenceAndOtherFieldsIntact() throws {
        let device = mouse(), at = Date(timeIntervalSince1970: 1_700_000_000)
        let value = MouseTelemetry(deviceID: device.id, interfaceID: 3, readAt: at, batteryPercent: 0, dpi: nil,
            issues: [.init(field: "dpi", message: "fixture timeout", kind: .timeout)])
        let assessment = AdapterCatalog.assess(device, telemetry: value)
        let battery = try #require(assessment.capability("battery")), dpi = try #require(assessment.capability("dpi"))
        #expect(battery.session.state == .succeeded && battery.session.at == at)
        #expect(dpi.implementation == .implemented && dpi.evidence.level == .hardwareValidated)
        #expect(dpi.session.state == .failed && dpi.session.failureKind == .timeout)
        #expect(assessment.capability("stages")?.session.state == .failed)
        #expect(assessment.capability("dpiWrite")?.session.state == .notRequested)
        #expect(assessment.readingSummary == "部分状态已取得")
    }

    @Test func skippedDPIAndUnknownBatteryStayUnknown() {
        let device = mouse()
        let value = MouseTelemetry(deviceID: device.id, interfaceID: 3, readAt: Date(), batteryPercent: nil, dpi: nil,
            issues: [.init(field: "battery", message: "fixture failure", kind: .busy)])
        let assessment = AdapterCatalog.assess(device, telemetry: value)
        #expect(assessment.capability("battery")?.session.state == .failed)
        #expect(assessment.capability("dpi")?.session.state == .notRead)
        #expect(assessment.capability("dpi")?.session.source == nil)
    }

    @Test func oldReadingsCannotAttachToTwinMouseOrChangedInterface() {
        let first = mouse(), twin = mouse(id: 4, usbID: 200), reconnected = mouse(id: 5)
        let value = MouseTelemetry(deviceID: first.id, interfaceID: 3, readAt: Date(), batteryPercent: 70, dpi: nil, issues: [])
        for device in [twin, reconnected] {
            #expect(AdapterCatalog.assess(device, telemetry: value).capability("battery")?.session.state == .notRead)
        }
    }

    @Test func activityAndSleepOverrideOnlyTransientResult() {
        let device = mouse()
        let value = MouseTelemetry(deviceID: device.id, interfaceID: 3, readAt: Date(), batteryPercent: 70, dpi: nil, issues: [])
        let reading = AdapterCatalog.assess(device, telemetry: value, activity: .init(reading: ["battery", "dpi", "stages"]))
        #expect(reading.capability("battery")?.session.state == .reading)
        #expect(reading.capability("polling")?.session.state == .notRead)
        #expect(reading.capability("dpiWrite")?.session.state == .notRequested)
        let asleep = AdapterCatalog.assess(device, telemetry: value, activity: .init(isSuspended: true))
        #expect(asleep.capability("battery")?.session.state == .suspended)
        #expect(asleep.capability("battery")?.evidence.level == .hardwareValidated)
        #expect(asleep.capability("localProfiles")?.session.state == .localOnly)
    }

    @Test func genericBluetoothDoesNotInheritOneModelsHardwareEvidence() {
        let observed = DeviceInfo.group([BluetoothDiscoveryTests().interface(pid: 0x00D5)])[0]
        let other = DeviceInfo.group([BluetoothDiscoveryTests().interface(pid: 0xEEEE)])[0]
        #expect(AdapterCatalog.assess(observed).capability("battery")?.evidence.level == .hardwareValidated)
        #expect(AdapterCatalog.assess(other).capability("battery")?.evidence.level == .softwareTested)
        #expect(AdapterCatalog.assess(other).capability("dpi")?.implementation == .notImplemented)
    }

    @Test func cachedSystemBatteryRequiresSourceAndUsesAcquisitionTime() {
        let device = DeviceInfo.group([BluetoothDiscoveryTests().interface()])[0], at = Date()
        func reading(source: SystemBatterySource?) -> SystemBatteryReading {
            .init(deviceID: device.id, interfaceIDs: device.interfaces.map(\.id), acquiredAt: at, percent: 0, source: source, issue: nil)
        }
        let valid = AdapterCatalog.assess(device, systemBattery: reading(source: .hidRegistry)).capability("battery")
        #expect(valid?.session.state == .succeeded && valid?.session.at == at)
        #expect(valid?.session.source == SystemBatterySource.hidRegistry.title)
        #expect(AdapterCatalog.assess(device, systemBattery: reading(source: nil)).capability("battery")?.session.state == .failed)
    }

    @Test func connectionCheckExplainsAbsenceMismatchAndObservedFailure() {
        let empty = ConnectionCheckReport.assess(devices: [], assessments: [:])
        #expect(empty.steps.first?.status == .attention && empty.devices.isEmpty)
        #expect(empty.steps.first?.detail.contains("非 HID") == true)
        let device = mouse()
        for kind in [ReadFailureKind.permissionDenied, .timeout, .protocolMismatch, .notPublished] {
            let value = MouseTelemetry(deviceID: device.id, interfaceID: 3, readAt: Date(), batteryPercent: nil, dpi: nil,
                issues: [.init(field: "battery", message: "fixture error", kind: kind)])
            let assessment = AdapterCatalog.assess(device, telemetry: value)
            let report = ConnectionCheckReport.assess(devices: [device], assessments: [device.id: assessment])
            #expect(report.devices[device.id]?.contains { $0.id == "battery" && $0.status == .attention } == true)
            #expect(report.devices[device.id]?.first { $0.id == "battery" }?.title.contains(kind.title) == true)
        }
    }

    @Test func diagnosticRoundTripContainsScopedManifestAndIndependentStates() throws {
        let device = mouse()
        let snapshot = DiagnosticSnapshot(interfaces: device.interfaces, activities: [device.id: .init(reading: ["charging"])])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(DiagnosticSnapshot.self, from: snapshot.jsonData())
        #expect(result.schemaVersion == 9 && result.adapterManifests == AdapterManifestCatalog.all)
        #expect(result.adapterAssessments?[device.id]?.capability("charging")?.session.state == .reading)
        #expect(result.adapterAssessments?[device.id]?.capability("charging")?.evidence.level == .simulationTested)
        #expect(result.connectionCheck != nil)
        let text = String(decoding: try snapshot.jsonData(), as: UTF8.self)
        #expect(!text.contains("serialNumber") && !text.contains("DeviceAddress") && !text.contains("setDpiTxTemplate"))
    }

    #if DEBUG
    @Test @MainActor func allOfflineScenariosShareUIAndDiagnosticAssessmentWithoutExtraOperations() async throws {
        let session = try OfflineScenarioSession()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        for scenario in OfflineScenario.allCases where scenario != .reading {
            await session.load(scenario)
            let before = await session.services.operations
            let snapshot = try decoder.decode(DiagnosticSnapshot.self, from: session.manager.snapshotData())
            #expect(snapshot.connectionCheck == session.manager.connectionCheck())
            for device in session.manager.devices {
                // Diagnostic timestamps are ISO 8601 seconds, while in-memory Dates retain subseconds.
                let expected = try decoder.decode(AdapterAssessment.self, from: encoder.encode(session.manager.adapterAssessment(for: device)))
                #expect(snapshot.adapterAssessments?[device.id] == expected)
                #expect(snapshot.adapterAssessments?[device.id]?.dataOrigin.contains("simulation-only") == true)
            }
            #expect(await session.services.operations == before)
        }
        session.manager.stop()
    }
    #endif
}
