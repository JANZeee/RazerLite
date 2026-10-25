import Foundation

public struct DiagnosticSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let applicationVersion: String
    public let generatedAt: Date
    public let operatingSystem: String
    public let mode: String
    /// Present only for development fixtures; absent in ordinary hardware diagnostics.
    public let dataOrigin: String?
    public let devices: [DeviceInfo]
    public let mouseReadouts: [String: MouseTelemetry]?
    public let batteryReadouts: [String: BatteryReading]?
    public let dpiWriteResults: [String: MouseDPIWriteResult]?
    public let systemBatteryReadings: [String: SystemBatteryReading]?
    public let pollingReadouts: [String: MousePollingReading]?
    public let chargingReadouts: [String: MouseChargingReading]?
    public let keyboardBatteryReadouts: [String: KeyboardPowerReading]?
    public let keyboardChargingReadouts: [String: KeyboardPowerReading]?
    public let readSummaries: [String: DeviceReadSummary]
    /// Optional so historical schema 6 exports remain decodable. Present since schema 7.
    public let adapterManifests: [DeviceAdapterManifest]?
    public let adapterAssessments: [String: AdapterAssessment]?
    public let connectionCheck: ConnectionCheckReport?

    public init(interfaces: [HIDInterface], batteryReadouts: [String: BatteryReading] = [:], mouseReadouts: [String: MouseTelemetry] = [:],
                dpiWriteResults: [String: MouseDPIWriteResult] = [:], systemBatteryReadings: [String: SystemBatteryReading] = [:],
                pollingReadouts: [String: MousePollingReading] = [:],
                chargingReadouts: [String: MouseChargingReading] = [:],
                keyboardBatteryReadouts: [String: KeyboardPowerReading] = [:],
                keyboardChargingReadouts: [String: KeyboardPowerReading] = [:],
                readSummaries: [String: DeviceReadSummary]? = nil,
                activities: [String: CapabilityActivity] = [:], isMonitoring: Bool = true, isSuspended: Bool = false,
                queriesRequested: Bool = false, systemMetadataRequested: Bool = false,
                automaticBatteryRequested: Bool = false, settingRequested: Bool = false, simulation: Bool = false) {
        schemaVersion = 9
        applicationVersion = "0.10.2-battery-experience"
        generatedAt = Date()
        operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        dataOrigin = simulation ? "synthetic-development-fixtures; not hardware evidence" : nil
        mode = simulation ? "simulation-only; no device communication"
            : settingRequested || !dpiWriteResults.isEmpty ? "manual-device-operations; see dpiWriteResults when complete"
            : automaticBatteryRequested ? "opt-in-battery-and-manual-reads; no setting commands"
            : queriesRequested || !mouseReadouts.isEmpty || !pollingReadouts.isEmpty || !chargingReadouts.isEmpty
                || !keyboardBatteryReadouts.isEmpty || !keyboardChargingReadouts.isEmpty ? "manual-status-queries; no setting commands"
            : systemMetadataRequested || !systemBatteryReadings.isEmpty ? "system-metadata-read; no feature queries requested"
            : "discovery-only; no feature queries requested"
        devices = DeviceInfo.group(interfaces)
        self.mouseReadouts = mouseReadouts.isEmpty ? nil : mouseReadouts
        self.batteryReadouts = batteryReadouts.isEmpty ? nil : batteryReadouts
        self.dpiWriteResults = dpiWriteResults.isEmpty ? nil : dpiWriteResults
        self.systemBatteryReadings = systemBatteryReadings.isEmpty ? nil : systemBatteryReadings
        self.pollingReadouts = pollingReadouts.isEmpty ? nil : pollingReadouts
        self.chargingReadouts = chargingReadouts.isEmpty ? nil : chargingReadouts
        self.keyboardBatteryReadouts = keyboardBatteryReadouts.isEmpty ? nil : keyboardBatteryReadouts
        self.keyboardChargingReadouts = keyboardChargingReadouts.isEmpty ? nil : keyboardChargingReadouts
        self.readSummaries = readSummaries ?? Dictionary(uniqueKeysWithValues: devices.map { device in
            (device.id, DeviceReadSummary.assess(battery: batteryReadouts[device.id], mouse: mouseReadouts[device.id], systemBattery: systemBatteryReadings[device.id],
                                                polling: pollingReadouts[device.id], charging: chargingReadouts[device.id],
                                                keyboardBattery: keyboardBatteryReadouts[device.id], keyboardCharging: keyboardChargingReadouts[device.id],
                                                isReading: activities[device.id]?.reading.isEmpty == false,
                                                isSuspended: isSuspended || activities[device.id]?.isSuspended == true,
                                                isDraining: activities[device.id]?.isDraining == true,
                                                hasCancelledRead: activities[device.id]?.cancelled.isEmpty == false))
        })
        adapterManifests = AdapterManifestCatalog.all
        let assessments = Dictionary(uniqueKeysWithValues: devices.map { device in
            (device.id, AdapterCatalog.assess(device, battery: batteryReadouts[device.id], telemetry: mouseReadouts[device.id], systemBattery: systemBatteryReadings[device.id],
                polling: pollingReadouts[device.id], charging: chargingReadouts[device.id],
                keyboardBattery: keyboardBatteryReadouts[device.id], keyboardCharging: keyboardChargingReadouts[device.id],
                activity: activities[device.id] ?? .init(isSuspended: isSuspended), dpiWrite: dpiWriteResults[device.id], simulation: simulation))
        })
        adapterAssessments = assessments
        connectionCheck = .assess(devices: devices, assessments: assessments, isMonitoring: isMonitoring, isSuspended: isSuspended)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
