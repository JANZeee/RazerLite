import SwiftUI
import RazerLiteCore

@MainActor
private final class ConnectionCheckViewState: ObservableObject {
    @Published var showsExport = false
}

struct ConnectionCheckSheet: View {
    @ObservedObject var manager: DeviceManager
    @StateObject private var state = ConnectionCheckViewState()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let report = manager.connectionCheck()
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("检查连接", systemImage: "stethoscope").font(.system(size: 20, weight: .semibold))
                Spacer()
                if manager.isSimulation { SmallBadge(title: "模拟数据", color: .orange) }
            }
            Text("根据当前系统属性和已完成的读取检查；打开此页不会查询设备。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    steps(report.steps)
                    ForEach(manager.devices) { device in
                        Divider()
                        Text(device.product).font(.system(size: 13, weight: .semibold))
                        Text("\(hexID(device.vendorID)) / \(hexID(device.productID)) · \(device.transport)")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        steps(report.devices[device.id] ?? [])
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
            }
            Divider()
            HStack {
                Button("刷新系统属性") { manager.refresh() }.disabled(manager.isSuspended || !manager.isMonitoring)
                Button("导出诊断…") { state.showsExport = true }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 650, height: 580)
            .sheet(isPresented: $state.showsExport) {
                JSONExportSheet(snapshotData: { try manager.snapshotData() }, simulation: manager.isSimulation)
            }
    }

    private func steps(_ values: [ConnectionCheckStep]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(values) { step in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: step.status == .passed ? "checkmark.circle" : step.status == .attention ? "exclamationmark.circle" : "info.circle")
                        .foregroundStyle(step.status == .passed ? Color.green : step.status == .attention ? Color.orange : Color.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(step.title).font(.system(size: 12, weight: .medium))
                        Text(step.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.textSelection(.enabled)
    }
}
