#if DEBUG
import Foundation
import Testing
@testable import RazerLiteCore

/// Exercises production manager/catalog/lifecycle code with the developer session's fake I/O.
/// Values in these tests are synthetic and never establish hardware protocol compatibility.
@MainActor
struct ReclusaBasicsIntegrationTests {
    private func waitUntilIdle(_ manager: DeviceManager, deviceID: String) async throws {
        for _ in 0..<100 where manager.isDeviceBusy(deviceID) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!manager.isDeviceBusy(deviceID))
    }

    @Test func keyboardScenarioPublishesIndependentPowerPollingAndBrightnessCapabilities() async throws {
        let session = try OfflineScenarioSession()
        await session.load(.keyboardLighting)
        let device = try #require(session.manager.devices.first)
        let interface = try #require(KeyboardPowerReadService.controlInterface(in: device))
        #expect(DeviceReadRegistry.backends(for: device) == [.reclusaMini65USB])
        #expect(PollingRateReadService.controlInterface(in: device)?.id == interface.id)
        let battery = try #require(session.manager.keyboardBatteryReadouts[device.id])
        #expect(battery.batteryPercent == 78 && battery.matches(device, field: .battery))
        #expect(session.manager.batterySummary(for: device)?.percent == 78)
        #expect(session.manager.batteryReadouts[device.id] == nil)
        #expect(session.manager.keyboardChargingReadouts[device.id]?.chargingState == .charging)
        #expect(session.manager.pollingReadouts[device.id]?.configuredHertz == 1000)
        #expect(session.manager.keyboardBrightnessReadouts[device.id]?.percent == 60)
        let assessment = session.manager.adapterAssessment(for: device)
        for feature in ["battery", "charging", "polling", "brightness"] {
            let capability = try #require(assessment.capability(feature))
            #expect(capability.implementation == .implemented && capability.routeAvailable)
            #expect(capability.session.state == .succeeded)
            #expect(capability.session.source?.contains("模拟") == true)
        }
        let write = try #require(assessment.capability("pollingWrite"))
        #expect(write.implementation == .implemented && write.routeAvailable && write.session.state == .notRequested)
        #expect(session.manager.batteryTargets.first?.backend == .reclusaMini65USB)
        #expect(!BatteryRefreshEligibility.allows(.reclusaMini65USB, simulation: false))
        #expect((await session.services.operations).allSatisfy { !$0.hasPrefix("apply-") })
        await session.manager.readBattery(for: device.id)
        let independentBattery = try #require(session.manager.batteryReadouts[device.id])
        #expect(independentBattery.percent == 78 && independentBattery.backend == .reclusaMini65USB)
        #expect(independentBattery.matches(device))
    }

    @Test func sameInterfaceRefreshPreservesReadingsAndUnifiedBatteryRefreshUsesKeyboardRoute() async throws {
        let session = try OfflineScenarioSession()
        await session.load(.keyboardLighting)
        let device = try #require(session.manager.devices.first)
        let battery = session.manager.batteryReadouts[device.id]
        let power = session.manager.keyboardBatteryReadouts[device.id]
        let charging = session.manager.keyboardChargingReadouts[device.id]
        let polling = session.manager.pollingReadouts[device.id]
        let brightness = session.manager.keyboardBrightnessReadouts[device.id]
        let calls = await session.services.operations
        session.manager.refresh()
        #expect(await session.services.operations == calls)
        #expect(session.manager.batteryReadouts[device.id] == battery)
        #expect(session.manager.keyboardBatteryReadouts[device.id] == power)
        #expect(session.manager.keyboardChargingReadouts[device.id] == charging)
        #expect(session.manager.pollingReadouts[device.id] == polling)
        #expect(session.manager.keyboardBrightnessReadouts[device.id] == brightness)
        await session.manager.readBattery(for: device.id)
        #expect(await session.services.operations == calls + ["keyboard-battery:\(device.id)"])
        #expect(session.manager.batteryReadouts[device.id]?.percent == 78)
        #expect(session.manager.batteryReadouts[device.id]?.backend == .reclusaMini65USB)
        #expect(session.manager.keyboardChargingReadouts[device.id] == charging)
        #expect(session.manager.pollingReadouts[device.id] == polling)
        #expect(session.manager.adapterAssessment(for: device).capability("battery")?.session.state == .succeeded)
    }

    @Test func reconnectClearsOldSessionValuesAndDoesNotReplayQueriesOrSettings() async throws {
        let session = try OfflineScenarioSession()
        await session.load(.keyboardLighting)
        let old = try #require(session.manager.devices.first)
        await session.manager.preparePollingChange(for: old.id, hertz: 500)
        let plan = try #require(session.manager.pendingPollingChanges[old.id])
        let calls = await session.services.operations
        session.disconnect()
        #expect(session.manager.devices.isEmpty && session.manager.batteryTargets.isEmpty)
        #expect(session.manager.batteryReadouts.isEmpty && session.manager.keyboardBatteryReadouts.isEmpty)
        #expect(session.manager.keyboardChargingReadouts.isEmpty && session.manager.pollingReadouts.isEmpty)
        #expect(session.manager.keyboardBrightnessReadouts.isEmpty && session.manager.pendingPollingChanges.isEmpty)
        #expect(!plan.isUsable)
        session.reconnect()
        let current = try #require(session.manager.devices.first)
        #expect(current.id != old.id)
        #expect(await session.services.operations == calls)
        for feature in ["battery", "charging", "polling", "brightness"] {
            #expect(session.manager.adapterAssessment(for: current).capability(feature)?.session.state == .notRead)
        }
        await session.manager.confirmPollingChange(for: old.id, planID: plan.id)
        #expect(await session.services.operations == calls)
        await session.manager.readBattery(for: current.id)
        #expect(session.manager.batteryReadouts[current.id]?.percent == 78)
        #expect(session.manager.batteryReadouts[old.id] == nil && session.manager.pollingReadouts[current.id] == nil)
    }

    @Test func pendingPollingConfirmationExcludesLiveBrightnessAndReadsAndAppliesOnlyOnce() async throws {
        let session = try OfflineScenarioSession()
        await session.load(.keyboardLighting)
        let device = try #require(session.manager.devices.first)
        await session.manager.preparePollingChange(for: device.id, hertz: 500)
        let plan = try #require(session.manager.pendingPollingChanges[device.id])
        #expect(session.manager.isDeviceBusy(device.id))
        #expect(session.manager.adapterAssessment(for: device).capability("pollingWrite")?.session.state == .awaitingConfirmation)
        let calls = await session.services.operations
        session.manager.setKeyboardBrightness(for: device.id, percent: 30)
        await session.manager.readBattery(for: device.id)
        await session.manager.readKeyboardPower(for: device.id, field: .charging)
        await session.manager.readKeyboardBrightness(for: device.id)
        await session.manager.readPollingRate(for: device.id)
        #expect(await session.services.operations == calls)
        #expect(session.manager.liveBrightnessTargets[device.id] == nil)
        await session.manager.confirmPollingChange(for: device.id, planID: plan.id)
        await session.manager.confirmPollingChange(for: device.id, planID: plan.id)
        #expect((await session.services.operations).filter { $0 == "apply-polling:\(device.id)" }.count == 1)
        #expect(session.manager.pollingReadouts[device.id]?.configuredHertz == 500)
        #expect(session.manager.pollingWriteResults[device.id]?.outcome == .verified)
        #expect(session.manager.batteryReadouts[device.id] == nil && session.manager.keyboardBatteryReadouts[device.id] == nil)
        #expect(session.manager.keyboardChargingReadouts[device.id] == nil)
        session.manager.refresh()
        #expect(session.manager.pollingReadouts[device.id]?.configuredHertz == 500)
        #expect(session.manager.pollingWriteResults[device.id]?.outcome == .verified)
        #expect(session.manager.adapterAssessment(for: device).capability("polling")?.session.state == .succeeded)
        #expect(session.manager.adapterAssessment(for: device).capability("pollingWrite")?.session.state == .succeeded)
    }

    @Test func inFlightPowerReadExcludesPollingAndLiveBrightness() async throws {
        let session = try OfflineScenarioSession()
        await session.load(.keyboardLighting)
        let id = try #require(session.manager.devices.first?.id)
        await session.services.configure(.reading)
        let reading = Task { await session.manager.readBattery(for: id) }
        await session.services.waitForPendingRead()
        let calls = await session.services.operations
        #expect(session.manager.isDeviceBusy(id) && session.manager.readingBatteryIDs.contains(id))
        await session.manager.preparePollingChange(for: id, hertz: 500)
        await session.manager.readPollingRate(for: id)
        session.manager.setKeyboardBrightness(for: id, percent: 30)
        #expect(await session.services.operations == calls)
        #expect(session.manager.pendingPollingChanges[id] == nil && session.manager.liveBrightnessTargets[id] == nil)
        await session.finishReads()
        await reading.value
        #expect(session.manager.batteryReadouts[id]?.percent == 78 && !session.manager.isDeviceBusy(id))
    }

    @Test func inFlightLiveBrightnessExcludesPollingAndPowerAndCancellationPreventsWrite() async throws {
        let session = try OfflineScenarioSession()
        await session.load(.keyboardLighting)
        let id = try #require(session.manager.devices.first?.id)
        await session.services.configure(.reading)
        session.manager.setKeyboardBrightness(for: id, percent: 30)
        await session.services.waitForPendingRead()
        #expect(session.manager.isDeviceBusy(id) && session.manager.brightnessWriteBusyIDs.contains(id))
        let calls = await session.services.operations
        await session.manager.preparePollingChange(for: id, hertz: 500)
        await session.manager.readPollingRate(for: id)
        await session.manager.readBattery(for: id)
        await session.manager.readKeyboardPower(for: id, field: .charging)
        #expect(await session.services.operations == calls)
        #expect(session.manager.pendingPollingChanges[id] == nil)
        session.manager.cancelLiveBrightness(for: id)
        #expect(session.manager.isDeviceBusy(id) && session.manager.drainingOperationIDs.contains(id))
        await session.finishReads()
        try await waitUntilIdle(session.manager, deviceID: id)
        #expect(session.manager.liveBrightnessTargets[id] == nil)
        #expect(session.manager.brightnessWriteResults[id] == nil)
        #expect((await session.services.operations).allSatisfy { !$0.hasPrefix("apply-brightness:") })
    }

    @Test func unknownModelCannotEnterPowerPollingOrLiveBrightnessServices() async throws {
        let session = try OfflineScenarioSession()
        await session.load(.unknown)
        let device = try #require(session.manager.devices.first)
        let calls = await session.services.operations
        await session.manager.readBattery(for: device.id)
        await session.manager.readKeyboardPower(for: device.id, field: .battery)
        await session.manager.readKeyboardPower(for: device.id, field: .charging)
        await session.manager.readPollingRate(for: device.id)
        await session.manager.preparePollingChange(for: device.id, hertz: 500)
        session.manager.setKeyboardBrightness(for: device.id, percent: 30)
        #expect(await session.services.operations == calls)
        #expect(DeviceReadRegistry.backends(for: device).isEmpty)
        #expect(session.manager.batteryReadouts.isEmpty && session.manager.pollingReadouts.isEmpty)
        #expect(session.manager.pendingPollingChanges.isEmpty && session.manager.liveBrightnessTargets.isEmpty)
        #expect(session.manager.adapterAssessment(for: device).capability("polling")?.routeAvailable == false)
    }
}
#endif
