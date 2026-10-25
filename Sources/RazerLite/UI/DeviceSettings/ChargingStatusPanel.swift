import SwiftUI
import RazerLiteCore

struct ChargingStatusPanel: View {
    let reading: MouseChargingReading?
    let isReading: Bool
    let disabled: Bool
    let onRead: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: reading?.state == .charging ? "battery.100.bolt" : "bolt.circle")
                        .font(.system(size: 22)).foregroundStyle(RazerTheme(scheme: scheme).accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("充电状态").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(isReading ? "正在读取…" : reading?.state?.title ?? (reading == nil ? "尚未读取" : "未取得"))
                            .font(.system(size: 17, weight: .medium))
                            .help("充电标志仅代表读取时的状态；未充电不代表正在放电或已经充满")
                    }
                    Spacer()
                    Button(isReading ? "正在读取…" : "读取充电状态", action: onRead)
                        .disabled(disabled || isReading)
                        .help("单独读取设备充电标志；不依赖电量或 DPI，不修改设置")
                }
                if let reading {
                    Text("\(reading.state == nil ? "尝试于" : "读取于") \(reading.readAt.formatted(date: .abbreviated, time: .standard)) · 设备读取")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if let issue = reading.issue {
                        if let kind = issue.kind { SmallBadge(title: kind.title, color: .orange) }
                        Text(issue.message).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
