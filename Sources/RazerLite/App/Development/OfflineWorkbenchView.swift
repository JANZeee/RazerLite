#if DEBUG
import SwiftUI
import RazerLiteCore

@MainActor
private final class OfflineWorkbenchState: ObservableObject {
    @Published var selected = OfflineScenario.mouse
    @Published var dpiOutcome = OfflineDPIOutcome.verified
    init() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--scenario"), arguments.indices.contains(index + 1),
           let scenario = OfflineScenario(rawValue: arguments[index + 1]) { selected = scenario }
    }
}

struct OfflineWorkbenchView: View {
    @ObservedObject var session: OfflineScenarioSession
    @ObservedObject var workspace: AppWorkspace
    @ObservedObject var preferences: AppPreferences
    @StateObject private var state = OfflineWorkbenchState()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("模拟数据", systemImage: "testtube.2").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                    .help("独立临时档案库；所有设备操作由假服务处理")
                Picker("场景", selection: $state.selected) {
                    ForEach(OfflineScenario.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 210).accessibilityLabel("离线场景")
                Picker("外观", selection: $preferences.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 85).accessibilityLabel("场景外观")
                Menu("生命周期") {
                    Button("完成等待中的读取") { Task { await session.finishReads() } }
                    Button("模拟断连") { session.disconnect() }
                    Button("模拟重新连接") { session.reconnect() }
                    Divider()
                    Button("模拟睡眠") { session.manager.suspend() }
                    Button("模拟唤醒") { session.manager.resume() }
                    Divider()
                    Button("紧凑窗口 · 960 × 640") { resize(width: 960, height: 640) }
                    Button("标准窗口 · 1180 × 800") { resize(width: 1180, height: 800) }
                }.frame(width: 100)
                Menu("DPI 结果") {
                    ForEach(OfflineDPIOutcome.allCases) { value in
                        Button(value.title) {
                            state.dpiOutcome = value
                            Task { await session.setDPIOutcome(value) }
                        }
                    }
                }.help(state.dpiOutcome.title).frame(width: 95)
                Spacer(minLength: 0)
            }.padding(.horizontal, 18).frame(height: 54)
            Divider()
            DeviceListView(manager: session.manager, profiles: session.profiles, workspace: workspace)
        }
        .task(id: state.selected) { await session.load(state.selected) }
    }

    private func resize(width: CGFloat, height: CGFloat) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "devices" }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: width, height: height))
    }
}
#endif
