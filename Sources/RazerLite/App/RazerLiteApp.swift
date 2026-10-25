import SwiftUI
import Combine
import RazerLiteCore

@main
@MainActor
struct RazerLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var manager: DeviceManager
    @StateObject private var profiles: ProfileService
    @StateObject private var workspace: AppWorkspace
    @StateObject private var preferences: AppPreferences
    @StateObject private var loginItem: LoginItemController
    @StateObject private var batteryRefresh: BatteryRefreshController
    @StateObject private var batteryAlerts: LowBatteryAlertController
    #if DEBUG
    private let offlineSession: OfflineScenarioSession?
    #endif

    init() {
        let offlineRequested = CommandLine.arguments.contains("--offline-scenarios")
            || Bundle.main.object(forInfoDictionaryKey: "RazerLiteOfflineScenarios") as? Bool == true
        let preferences = AppPreferences(defaults: offlineRequested
            ? UserDefaults(suiteName: "local.RazerLite.Scenarios.Preferences")! : .standard)
        _preferences = StateObject(wrappedValue: preferences)
        _workspace = StateObject(wrappedValue: AppWorkspace(preferences: preferences))
        _loginItem = StateObject(wrappedValue: LoginItemController(
            service: offlineRequested ? OfflineLoginItemService() : NativeLoginItemService(),
            installationIssue: LoginItemInstallation.blockingReason(bundleURL: Bundle.main.bundleURL,
                homeURL: FileManager.default.homeDirectoryForCurrentUser, isSimulation: offlineRequested)))
        let manager: DeviceManager
        let profiles: ProfileService
        #if DEBUG
        if offlineRequested {
            do {
                let session = try OfflineScenarioSession()
                offlineSession = session
                manager = session.manager
                profiles = session.profiles
            } catch {
                fatalError("离线场景初始化失败，已停止启动：\(error)")
            }
        } else {
            offlineSession = nil
            manager = DeviceManager()
            profiles = ProfileService()
        }
        #else
        guard !offlineRequested else { fatalError("离线场景仅适用于 Debug 构建。") }
        manager = DeviceManager()
        profiles = ProfileService()
        #endif
        _manager = StateObject(wrappedValue: manager)
        _profiles = StateObject(wrappedValue: profiles)
        _batteryRefresh = StateObject(wrappedValue: BatteryRefreshController(manager: manager, preferences: preferences))
        _batteryAlerts = StateObject(wrappedValue: LowBatteryAlertController(manager: manager, preferences: preferences,
            service: offlineRequested ? OfflineBatteryNotificationService() : NativeBatteryNotificationService()))
    }

    var body: some Scene {
        Window("RazerLite", id: "devices") {
            rootContent
                .background(MainWindowState(autosaveName: offlineRequestedForWindow ? "Scenarios.MainWindow" : "MainWindow"))
                .task {
                    delegate.manager = manager
                    delegate.profiles = profiles
                    delegate.configure(preferences: preferences, loginItem: loginItem, batteryRefresh: batteryRefresh, batteryAlerts: batteryAlerts)
                    manager.start()
                    await batteryAlerts.refreshAuthorization()
                    delegate.startSmokeCheckIfRequested()
                }
        }
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新设备") { manager.refresh() }.keyboardShortcut("r")
            }
        }
        MenuBarExtra("RazerLite", systemImage: "computermouse") {
            MenuBarView(manager: manager, profiles: profiles, workspace: workspace)
        }
        Settings { SettingsView(manager: manager, profiles: profiles, preferences: preferences, loginItem: loginItem, batteryRefresh: batteryRefresh, batteryAlerts: batteryAlerts) }
    }

    private var offlineRequestedForWindow: Bool { manager.isSimulation }

    @ViewBuilder private var rootContent: some View {
        #if DEBUG
        if let offlineSession {
            if CommandLine.arguments.contains("--validate-capabilities-dir") {
                CapabilityValidationView(session: offlineSession)
            } else {
                OfflineWorkbenchView(session: offlineSession, workspace: workspace, preferences: preferences)
            }
        } else {
            DeviceListView(manager: manager, profiles: profiles, workspace: workspace)
        }
        #else
        DeviceListView(manager: manager, profiles: profiles, workspace: workspace)
        #endif
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var manager: DeviceManager?
    weak var profiles: ProfileService?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var appearanceSubscription: AnyCancellable?
    private var preferences: AppPreferences?
    private weak var batteryRefresh: BatteryRefreshController?
    private weak var batteryAlerts: LowBatteryAlertController?

    func configure(preferences: AppPreferences, loginItem: LoginItemController, batteryRefresh: BatteryRefreshController, batteryAlerts: LowBatteryAlertController) {
        guard self.preferences == nil else { return }
        self.preferences = preferences
        self.batteryRefresh = batteryRefresh; self.batteryAlerts = batteryAlerts
        appearanceSubscription = preferences.$appearance.removeDuplicates().sink { appearance in
            NSApp.appearance = switch appearance {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(mainWindowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    loginItem.refresh()
                    Task { @MainActor [weak batteryAlerts] in await batteryAlerts?.refreshAuthorization() }
                }
            }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func mainWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier?.rawValue == "devices" else { return }
        manager?.invalidateDPIPlans()
        if preferences?.closeBehavior == .quit { NSApp.terminate(nil) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.manager?.suspend() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.manager?.resume() }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        NotificationCenter.default.removeObserver(self)
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        appearanceSubscription?.cancel()
        batteryRefresh?.stop()
        batteryAlerts?.stop()
        manager?.stop()
    }

    private var smokeCheckStarted = false
    func startSmokeCheckIfRequested() {
        #if DEBUG
        guard manager?.isSimulation != true else { return }
        let arguments = CommandLine.arguments
        guard !smokeCheckStarted, let index = arguments.firstIndex(of: "--smoke-test-dir"),
              arguments.indices.contains(index + 1) else { return }
        smokeCheckStarted = true
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await Task.sleep(for: .seconds(1))
                guard let manager, let profiles, !manager.physicalDevices.isEmpty,
                      NSApp.windows.contains(where: { $0.isVisible && $0.title == "RazerLite" }) else {
                    throw CocoaError(.coderInvalidValue)
                }
                // Opt-in integration check; ordinary launches and ordinary smoke renders remain passive.
                if arguments.contains("--smoke-read-mouse"),
                   let mouse = manager.physicalDevices.first(where: { MouseReadService.canRead($0) }) {
                    await manager.readMouseState(for: mouse.id)
                }
                // Developer-only read/preparation check. This path never calls apply or sends 04/06.
                if arguments.contains("--smoke-dpi-check"),
                   let mouse = manager.physicalDevices.first(where: { MouseReadService.canRead($0) }) {
                    let text: String
                    do {
                        let plan = try await MouseDPIService().prepare(mouse, x: 2800, y: 2800)
                        text = "Read-only preparation succeeded: stage \(plan.before.activeStage), X \(plan.before.current.x) / Y \(plan.before.current.y). No setting command sent."
                    } catch { text = error.localizedDescription }
                    try Data(text.utf8).write(to: directory.appendingPathComponent("dpi-preparation.txt"))
                }
                try manager.snapshotData().write(to: directory.appendingPathComponent("devices.json"), options: .atomic)
                // Render shared page content directly; this does not capture the desktop.
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    let scheme: ColorScheme = name == "light" ? .light : .dark
                    for item in manager.physicalDevices {
                        let state = DeviceDetailState()
                        let content = workspaceSnapshot(manager: manager, profiles: profiles, device: item, state: state, scheme: scheme)
                        let prefix = item.presentation.isKeyboard ? "keyboard" : "mouse"
                        try saveRender(content, to: directory.appendingPathComponent("\(prefix)-\(name).png"))
                        try saveRender(workspaceSnapshot(manager: manager, profiles: profiles, device: item, state: state, scheme: scheme, width: 1000),
                                       to: directory.appendingPathComponent("\(prefix)-compact-\(name).png"))
                        if !item.presentation.isKeyboard {
                            state.page = .controls
                            try saveRender(workspaceSnapshot(manager: manager, profiles: profiles, device: item, state: state, scheme: scheme),
                                           to: directory.appendingPathComponent("performance-\(name).png"))
                            state.page = .buttons
                            try saveRender(workspaceSnapshot(manager: manager, profiles: profiles, device: item, state: state, scheme: scheme),
                                           to: directory.appendingPathComponent("buttons-\(name).png"))
                            state.page = .profiles
                            try saveRender(workspaceSnapshot(manager: manager, profiles: profiles, device: item, state: state, scheme: scheme),
                                           to: directory.appendingPathComponent("profiles-\(name).png"))
                        }
                    }
                    if let keyboard = manager.physicalDevices.first(where: { $0.presentation.isKeyboard }) {
                        let state = DeviceDetailState()
                        state.page = .controls
                        try saveRender(workspaceSnapshot(manager: manager, profiles: profiles, device: keyboard, state: state, scheme: scheme),
                                       to: directory.appendingPathComponent("lighting-\(name).png"))
                        state.previewColorIndex = 3
                        state.previewBrightness = 0.35
                        try saveRender(workspaceSnapshot(manager: manager, profiles: profiles, device: keyboard, state: state, scheme: scheme),
                                       to: directory.appendingPathComponent("lighting-purple-\(name).png"))
                    }
                }
                try Data("GUI window ready; real HID snapshot exported; shared workspace and local preview rendered in light/dark. Native window chrome and interactions require manual verification.\n".utf8)
                    .write(to: directory.appendingPathComponent("success.txt"))
            } catch {
                try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("error.txt"))
            }
            NSApp.terminate(nil)
        }
        #endif
    }

    #if DEBUG
    private func workspaceSnapshot(manager: DeviceManager, profiles: ProfileService, device: DeviceInfo, state: DeviceDetailState, scheme: ColorScheme, width: CGFloat = 1180) -> some View {
        let height: CGFloat = manager.mouseReadouts[device.id] == nil ? 760 : 910
        return HStack(alignment: .top, spacing: 0) {
            DeviceSidebarContent(devices: manager.devices, selectedID: .constant(device.id), monitoring: manager.isMonitoring, snapshot: true)
                .frame(width: width < 1180 ? 220 : 244, height: height)
            Rectangle().fill(RazerTheme(scheme: scheme).line).frame(width: 1)
            DevicePageContent(device: device, logs: manager.logs, state: state, telemetry: manager.mouseReadouts[device.id], profiles: profiles)
                .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(RazerTheme(scheme: scheme).canvas)
        .environment(\.colorScheme, scheme)
    }

    private func saveRender<Content: View>(_ content: Content, to url: URL) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw CocoaError(.coderInvalidValue) }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.coderInvalidValue) }
        try png.write(to: url)
    }
    #endif
}
