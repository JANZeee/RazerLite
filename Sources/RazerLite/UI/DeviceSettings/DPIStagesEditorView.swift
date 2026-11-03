import SwiftUI
import RazerLiteCore

@MainActor
private final class DPIStagesDraft: ObservableObject {
    @Published var expanded = false
    @Published var baseline: MouseDPIState?
    @Published var rows: [Row] = []

    struct Row {
        var x: String
        var y: String
    }

}

/// Keeps an explicit snapshot so a later read cannot silently overwrite a user's draft.
struct DPIStagesEditorView: View {
    let device: DeviceInfo
    @ObservedObject var manager: DeviceManager
    let busy: Bool
    @StateObject private var editor = DPIStagesDraft()
    private var baseline: MouseDPIState? { editor.baseline }
    private var rows: [DPIStagesDraft.Row] { editor.rows }

    private var latest: MouseDPIState? { manager.mouseReadouts[device.id]?.dpi }
    private var stale: Bool {
        guard let baseline, let latest else { return false }
        return baseline != latest
    }
    private var changes: [MouseDPIStageChange]? {
        guard let baseline, rows.count == baseline.stages.count else { return nil }
        var changes: [MouseDPIStageChange] = []
        for index in rows.indices {
            guard let x = Int(rows[index].x), let y = Int(rows[index].y) else { return nil }
            let original = baseline.stages[index]
            if x == original.x && y == original.y { continue }
            guard (100...50000).contains(x), (100...50000).contains(y), x % 50 == 0, y % 50 == 0 else { return nil }
            changes.append(MouseDPIStageChange(stage: index + 1, x: x, y: y))
        }
        return changes.isEmpty ? nil : changes
    }

    var body: some View {
        DisclosureGroup("编辑全部档位", isExpanded: $editor.expanded) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(baseline == nil ? "先读取状态，再载入设备值。" : "保留档位数量和当前档位。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(baseline == nil ? "载入设备值" : "重新载入设备值") { loadLatest() }
                        .disabled(busy || latest == nil)
                }
                if let baseline {
                    HStack {
                        Text("档位").frame(width: 80, alignment: .leading)
                        Text("X 轴 DPI").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Y 轴 DPI").frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                    ForEach(rows.indices, id: \.self) { index in
                        HStack {
                            Text("\(index + 1)\(index + 1 == baseline.activeStage ? " · 当前" : "")")
                                .font(.system(size: 11)).frame(width: 80, alignment: .leading)
                            TextField("X", text: $editor.rows[index].x)
                                .accessibilityLabel("第 \(index + 1) 档 X 轴 DPI")
                            TextField("Y", text: $editor.rows[index].y)
                                .accessibilityLabel("第 \(index + 1) 档 Y 轴 DPI")
                        }.textFieldStyle(.roundedBorder).disabled(busy)
                    }
                    if stale {
                        Label("设备值已变化，请重新载入后编辑。", systemImage: "arrow.clockwise")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    HStack {
                        Text("修改值步进 50；未修改的原值完整保留。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Button("检查档位变更…") {
                            guard let changes else { return }
                            Task { await manager.prepareDPIStages(for: device.id, baseline: baseline, changes: changes) }
                        }.disabled(busy || stale || changes == nil)
                    }
                }
            }.padding(.top, 12)
        }
        .font(.system(size: 12))
        .onChange(of: editor.expanded) { isExpanded in
            if isExpanded && baseline == nil { loadLatest() }
        }
        .onChange(of: manager.dpiWriteResults[device.id]?.completedAt) { _ in
            if manager.dpiWriteResults[device.id]?.outcome == .verified { loadLatest() }
        }
    }

    private func loadLatest() {
        guard let latest else { return }
        editor.baseline = latest
        editor.rows = latest.stages.map { DPIStagesDraft.Row(x: String($0.x), y: String($0.y)) }
    }
}
