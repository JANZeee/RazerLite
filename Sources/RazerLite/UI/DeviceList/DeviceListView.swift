import Combine
import SwiftUI
import RazerLiteCore

@MainActor
private final class DeviceListViewState: ObservableObject {
    @Published var showsDiagnosticExport = false
    @Published var showsConnectionCheck = false
}

struct DeviceListView: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject var profiles: ProfileService
    @ObservedObject var workspace: AppWorkspace
    @Environment(\.colorScheme) private var scheme
    @StateObject private var state = DeviceListViewState()

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                DeviceSidebarContent(devices: manager.devices, selectedID: Binding(get: { workspace.section == .devices ? workspace.selectedDeviceID : nil }, set: {
                    workspace.navigationRequest = nil
                    workspace.section = .devices
                    workspace.selectedDeviceID = $0
                }), monitoring: manager.isMonitoring && !manager.isSuspended)
                VStack(spacing: 3) {
                    sidebarLink("本地档案", icon: "rectangle.stack", section: .profiles)
                    sidebarLink("设备目录", icon: "square.grid.2x2", section: .catalog)
                }.padding(.horizontal, 12).padding(.bottom, 16).background(RazerTheme(scheme: scheme).sidebar)
            }
                .navigationSplitViewColumnWidth(min: 220, ideal: 244, max: 290)
        } detail: {
            if workspace.section == .profiles {
                LocalProfileLibraryView(profiles: profiles, manager: manager, workspace: workspace)
            } else if workspace.section == .catalog {
                DeviceCatalogView(manager: manager, workspace: workspace)
            } else if let device = manager.devices.first(where: { $0.id == workspace.selectedDeviceID }) {
                DeviceDetailView(device: device, manager: manager, profiles: profiles, workspace: workspace).id(device.id)
            } else {
                DeviceEmptyState(hasDevices: !manager.physicalDevices.isEmpty,
                    onBrowse: { workspace.section = .catalog }, onCheck: { state.showsConnectionCheck = true })
            }
        }
        .frame(minWidth: 960, minHeight: manager.isSimulation ? 560 : 640)
        .tint(RazerTheme(scheme: scheme).accent)
        .toolbar {
            ToolbarItemGroup {
                Button { manager.refresh() } label: { Label("刷新设备", systemImage: "arrow.clockwise") }
                    .help("重新读取设备信息")
                    .disabled(manager.isSuspended)
                Button { state.showsConnectionCheck = true } label: { Label("检查连接", systemImage: "stethoscope") }
                    .help("查看发现状态、适配条件与读取问题")
                Menu {
                    Button { state.showsDiagnosticExport = true } label: {
                        Label("导出诊断…", systemImage: "square.and.arrow.up")
                    }
                } label: { Label("更多", systemImage: "ellipsis.circle") }
                    .help("更多操作")
            }
        }
        .onReceive(manager.$devices) { devices in
            if !devices.contains(where: { $0.id == workspace.selectedDeviceID }) { workspace.selectedDeviceID = devices.first?.id }
        }
        .alert("操作未完成", isPresented: Binding(get: { manager.lastError != nil }, set: { if !$0 { manager.clearError() } })) {
            Button("好") { manager.clearError() }
        } message: { Text(manager.lastError ?? "未知错误") }
        .sheet(isPresented: $state.showsDiagnosticExport) {
            JSONExportSheet(snapshotData: { try manager.snapshotData() }, simulation: manager.isSimulation)
        }
        .sheet(isPresented: $state.showsConnectionCheck) { ConnectionCheckSheet(manager: manager) }
    }

    private func sidebarLink(_ title: String, icon: String, section: AppWorkspace.Section) -> some View {
        Button { workspace.section = section } label: {
            Label(title, systemImage: icon).font(.system(size: 12))
                .foregroundStyle(workspace.section == section ? RazerTheme(scheme: scheme).accent : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(workspace.section == section ? RazerTheme(scheme: scheme).selected : .clear,
                            in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityAddTraits(workspace.section == section ? .isSelected : [])
    }
}

struct DeviceSidebarContent: View {
    let devices: [DeviceInfo]
    @Binding var selectedID: String?
    let monitoring: Bool
    var snapshot = false
    @Environment(\.colorScheme) private var scheme
    private var theme: RazerTheme { RazerTheme(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Text("R").font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(white: 0.10)).frame(width: 35, height: 35)
                    .background(RazerTheme.green, in: RoundedRectangle(cornerRadius: 10))
                Text("RazerLite").font(.system(size: 17, weight: .semibold)).tracking(-0.3)
            }.padding(.horizontal, 21).padding(.top, 24).padding(.bottom, 30)
            HStack {
                Text("我的设备").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(devices.filter { !$0.isVirtual }.count)").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }.padding(.horizontal, 23).padding(.bottom, 12)
            if snapshot { deviceRows }
            else { ScrollView { deviceRows } }
            Spacer(minLength: 24)
            if devices.contains(where: \.isVirtual) {
                Text("系统设备").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 23).padding(.bottom, 9)
                ForEach(devices.filter(\.isVirtual)) { device in row(device).padding(.horizontal, 12) }
            }
            Rectangle().fill(theme.line).frame(height: 1).padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 17)
            if #available(macOS 14.0, *) {
                SettingsLink { Label("设置", systemImage: "gearshape").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 20)
            }
            HStack(spacing: 7) {
                Circle().fill(monitoring ? theme.accent : .secondary).frame(width: 5, height: 5)
                Text(monitoring ? "自动发现设备" : "发现已暂停")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.sidebar)
    }

    private var deviceRows: some View {
        VStack(spacing: 7) {
            ForEach(devices.filter { !$0.isVirtual }) { row($0) }
            if devices.filter({ !$0.isVirtual }).isEmpty {
                Text("暂无设备").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }.padding(.horizontal, 12)
    }

    private func row(_ device: DeviceInfo) -> some View {
        let selected = selectedID == device.id
        return Button { selectedID = device.id } label: {
            HStack(spacing: 11) {
                Image(systemName: device.presentation.icon).font(.system(size: 19, weight: .regular))
                    .foregroundStyle(selected ? theme.accent : .secondary)
                    .frame(width: 36, height: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(device.presentation.name).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
                    Text(device.presentation.subtitle.components(separatedBy: " · ").first ?? device.presentation.subtitle)
                        .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected { RoundedRectangle(cornerRadius: 2).fill(theme.accent).frame(width: 3, height: 17) }
            }
            .padding(.horizontal, 11).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? theme.selected : .clear, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(selected ? theme.accent.opacity(0.12) : .clear) }
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain).help(device.product).accessibilityLabel(device.product)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct DeviceEmptyState: View {
    let hasDevices: Bool
    let onBrowse: () -> Void
    let onCheck: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var theme: RazerTheme { RazerTheme(scheme: scheme) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "keyboard").font(.system(size: 30, weight: .light))
                Image(systemName: "computermouse").font(.system(size: 30, weight: .light))
            }
            .foregroundStyle(theme.accent)
            .frame(width: 116, height: 88)
            .background(theme.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(theme.accent.opacity(0.12)) }
            .accessibilityHidden(true)
            Text(hasDevices ? "选择一台设备" : "连接你的设备")
                .font(.system(size: 26, weight: .semibold)).tracking(-0.6).padding(.top, 27)
            Text(hasDevices ? "从侧栏选择设备，查看状态与设置。" : "连接 Razer 外设后，将自动显示在这里。")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 10)
            if !hasDevices {
                HStack(spacing: 12) {
                    Button(action: onCheck) { Label("检查连接", systemImage: "stethoscope") }
                    Button(action: onBrowse) { Label("浏览设备目录", systemImage: "square.grid.2x2") }
                }.buttonStyle(.bordered).controlSize(.large).padding(.top, 25)
            }
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
    }
}
