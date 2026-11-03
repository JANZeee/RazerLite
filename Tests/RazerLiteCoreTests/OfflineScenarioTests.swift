#if DEBUG
import Foundation
import Testing
@testable import RazerLiteCore

@MainActor
struct OfflineScenarioTests {
    private func snapshot(_ session: OfflineScenarioSession) throws -> DiagnosticSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticSnapshot.self, from: session.manager.snapshotData())
    }

    @Test func batchChangesStayIsolatedAndRejectAnOldDraft() async throws {
        let session = try OfflineScenarioSession()
        await session.load(.twinMice)
        let first = session.manager.devices[0], second = session.manager.devices[1]
        let baseline = try #require(session.manager.mouseReadouts[first.id]?.dpi)
        let other = session.manager.mouseReadouts[second.id]?.dpi
        let changes = [MouseDPIStageChange(stage: 1, x: 1000, y: 1200),
                       MouseDPIStageChange(stage: 3, x: 3200, y: 3400)]
        await session.manager.prepareDPIStages(for: first.id, baseline: baseline, changes: changes)
        let plan = try #require(session.manager.pendingDPIChanges[first.id])
        #expect(plan.changedStages == [1, 3])
        await session.manager.confirmDPIChange(for: first.id, planID: plan.id)
        await session.manager.confirmDPIChange(for: first.id, planID: plan.id)
        #expect(session.manager.mouseReadouts[first.id]?.dpi == plan.after)
        #expect(session.manager.mouseReadouts[second.id]?.dpi == other)
        #expect((await session.services.operations).filter { $0.hasPrefix("apply:") }.count == 1)
        await session.manager.prepareDPIStages(for: first.id, baseline: baseline, changes: changes)
        #expect(session.manager.pendingDPIChanges[first.id] == nil)
        #expect(session.manager.dpiErrors[first.id] != nil)
    }

    @Test func batchConfirmationIsRevokedDuringSleep() async throws {
        let session = try OfflineScenarioSession()
        await session.load(.mouse)
        let id = try #require(session.manager.devices.first?.id)
        let baseline = try #require(session.manager.mouseReadouts[id]?.dpi)
        await session.manager.prepareDPIStages(for: id, baseline: baseline,
            changes: [MouseDPIStageChange(stage: 1, x: 1000, y: 1200)])
        let plan = try #require(session.manager.pendingDPIChanges[id])
        session.manager.suspend()
        session.manager.resume()
        await session.manager.confirmDPIChange(for: id, planID: plan.id)
        #expect(session.manager.pendingDPIChanges[id] == nil)
        #expect(!(await session.services.operations).contains { $0.hasPrefix("apply:") })
    }

    @Test func allScenariosUseSyntheticDiagnosticsAndIsolatedStorage() async throws {
        let first = try OfflineScenarioSession()
        let second = try OfflineScenarioSession()
        #expect(first.storageDirectory != second.storageDirectory)
        #expect(first.profiles.storageURL.deletingLastPathComponent() == first.storageDirectory)
        for scenario in OfflineScenario.allCases where scenario != .reading {
            await first.load(scenario)
            let data = try snapshot(first)
            #expect(first.manager.isSimulation)
            #expect(data.mode == "simulation-only; no device communication")
            #expect(data.dataOrigin == "synthetic-development-fixtures; not hardware evidence")
            #expect(first.manager.lastError == nil)
        }
        #expect(!first.profiles.profiles.isEmpty)
        #expect(second.profiles.profiles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: second.profiles.storageURL.path))
    }

    @Test func zeroPowerValuesUnknownModelAndFailureClassesRemainDistinct() async throws {
        let session = try OfflineScenarioSession()
        await session.load(.keyboard)
        let keyboard = try #require(session.manager.devices.first)
        #expect(session.manager.keyboardBatteryReadouts[keyboard.id]?.batteryPercent == 0)
        #expect(session.manager.keyboardChargingReadouts[keyboard.id]?.chargingState == .charging)
        await session.load(.bluetooth)
        let bluetooth = try #require(session.manager.devices.first)
        #expect(session.manager.systemBatteryReadings[bluetooth.id]?.percent == 0)
        #expect(session.manager.systemBatteryReadings[bluetooth.id]?.source == .macOSBluetoothSnapshot)
        #expect(session.manager.mouseReadouts.isEmpty)
        for (scenario, kind) in [(OfflineScenario.timeout, ReadFailureKind.timeout), (.permissionDenied, .permissionDenied), (.receiverOnly, .timeout)] {
            await session.load(scenario)
            let device = try #require(session.manager.devices.first)
            #expect(session.manager.mouseReadouts[device.id]?.batteryPercent == nil)
            #expect(session.manager.mouseReadouts[device.id]?.issues.first?.kind == kind)
            #expect(session.manager.readSummary(for: device.id).state == .unconfirmed)
        }
        await session.load(.partial)
        let device = try #require(session.manager.devices.first)
        #expect(session.manager.mouseReadouts[device.id]?.batteryPercent == 76)
        #expect(session.manager.mouseReadouts[device.id]?.dpi == nil)
        #expect(session.manager.readSummary(for: device.id).state == .partial)
        await session.load(.unknown)
        let unknown = try #require(session.manager.devices.first)
        let calls = await session.services.operations
        await session.manager.readMouseState(for: unknown.id)
        await session.manager.readKeyboardPower(for: unknown.id, field: .battery)
        #expect(await session.services.operations == calls)
        #expect(DeviceReadRegistry.backends(for: unknown).isEmpty)
    }

    @Test func waitingScenarioCompletesOnlyOnExplicitReleaseAndRefreshDoesNotQuery() async throws {
        let session = try OfflineScenarioSession()
        let task = Task { await session.load(.reading) }
        await session.services.waitForPendingRead()
        let id = try #require(session.manager.devices.first?.id)
        #expect(session.manager.readingDeviceIDs.contains(id))
        session.manager.refresh()
        await session.manager.readMouseState(for: id)
        #expect(await session.services.operations.count == 1)
        await session.finishReads()
        await task.value
        #expect(session.manager.readingDeviceIDs.isEmpty)
        #expect(session.manager.mouseReadouts[id]?.dpi?.current == MouseDPIStage(x: 2800, y: 3000))
    }

    @Test func switchingScenarioDiscardsHeldResponseWithoutPollutingNewDevice() async throws {
        let session = try OfflineScenarioSession()
        let held = Task { await session.load(.reading) }
        await session.services.waitForPendingRead()
        await session.load(.bluetooth)
        await held.value
        #expect(session.scenario == .bluetooth)
        #expect(session.manager.mouseReadouts.isEmpty)
        #expect(session.manager.systemBatteryReadings.count == 1)
    }

    @Test func disconnectReconnectAndSleepInvalidateHeldReadsAndConfirmations() async throws {
        let session = try OfflineScenarioSession()
        let held = Task { await session.load(.reading) }
        await session.services.waitForPendingRead()
        let old = try #require(session.manager.devices.first?.id)
        session.disconnect()
        #expect(session.manager.devices.isEmpty)
        session.reconnect()
        let current = try #require(session.manager.devices.first?.id)
        #expect(old != current)
        await session.finishReads()
        await held.value
        #expect(session.manager.mouseReadouts.isEmpty)
        await session.manager.prepareDPIChange(for: current, x: 1600, y: 1600)
        #expect(session.manager.pendingDPIChanges.count == 1)
        session.manager.suspend()
        session.manager.resume()
        #expect(session.manager.pendingDPIChanges.isEmpty)
        #expect(session.manager.mouseReadouts.isEmpty)
        #expect(!(await session.services.operations).contains { $0.hasPrefix("apply:") })
    }

    @Test func twoIdenticalModelsNeverShareSessionReadingsOrFakeAppliedState() async throws {
        let session = try OfflineScenarioSession()
        await session.load(.twinMice)
        #expect(session.manager.devices.count == 2)
        let first = session.manager.devices[0], second = session.manager.devices[1]
        #expect(first.id != second.id)
        #expect(session.manager.mouseReadouts[first.id]?.batteryPercent != session.manager.mouseReadouts[second.id]?.batteryPercent)
        await session.manager.prepareDPIChange(for: first.id, x: 1600, y: 1600)
        let plan = try #require(session.manager.pendingDPIChanges[first.id])
        await session.manager.confirmDPIChange(for: first.id, planID: plan.id)
        await session.manager.confirmDPIChange(for: first.id, planID: plan.id)
        #expect(session.manager.mouseReadouts[first.id]?.dpi?.current.x == 1600)
        #expect(session.manager.mouseReadouts[second.id]?.dpi?.current.x == 2800)
        #expect((await session.services.operations).filter { $0.hasPrefix("apply:") }.count == 1)
        #expect(try snapshot(session).mode == "simulation-only; no device communication")
    }

    @Test func cancelExpiryAndUncertainResultExerciseTheRealManagerFlow() async throws {
        let session = try OfflineScenarioSession()
        await session.load(.mouse)
        let id = try #require(session.manager.devices.first?.id)
        await session.manager.prepareDPIChange(for: id, x: 1600, y: 1600)
        let cancelled = try #require(session.manager.pendingDPIChanges[id])
        session.manager.cancelDPIChange(for: id)
        await session.manager.confirmDPIChange(for: id, planID: cancelled.id)
        #expect(!(await session.services.operations).contains { $0.hasPrefix("apply:") })
        for outcome in [OfflineDPIOutcome.expired, .notSent, .mismatch] {
            await session.setDPIOutcome(outcome)
            await session.manager.prepareDPIChange(for: id, x: 1600, y: 1600)
            let plan = try #require(session.manager.pendingDPIChanges[id])
            await session.manager.confirmDPIChange(for: id, planID: plan.id)
            #expect(session.manager.dpiWriteResults[id]?.outcome == (outcome == .mismatch ? .uncertain : .notSent))
            #expect(session.manager.mouseReadouts[id] == nil)
        }
    }

    @Test func normalSnapshotsRemainUnmarkedAndOldSchemaSixStillDecodes() throws {
        let live = DiagnosticSnapshot(interfaces: [])
        #expect(live.dataOrigin == nil)
        #expect(live.mode == "discovery-only; no feature queries requested")
        var object = try #require(JSONSerialization.jsonObject(with: live.jsonData()) as? [String: Any])
        object["schemaVersion"] = 6
        for key in ["dataOrigin", "adapterManifests", "adapterAssessments", "connectionCheck"] { object.removeValue(forKey: key) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(DiagnosticSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.schemaVersion == 6 && old.dataOrigin == nil && old.adapterManifests == nil && old.adapterAssessments == nil && old.connectionCheck == nil)
    }
}
#endif
