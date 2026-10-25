import SwiftUI
import RazerLiteCore

struct LightingPreviewView: View {
    @ObservedObject var state: DeviceDetailState
    @Environment(\.colorScheme) private var scheme
    private var theme: RazerTheme { RazerTheme(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("灯光预览").font(.system(size: 24, weight: .semibold)).tracking(-0.5)
                    Text("颜色与亮度仅在此窗口生效。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                SmallBadge(title: "仅本地预览", color: theme.accent)
            }.padding(.vertical, 6)
            SurfaceCard {
                HStack {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("当前颜色").font(.system(size: 12, weight: .medium))
                        Text(DeviceDetailState.colors[state.previewColorIndex].0)
                            .font(.system(size: 27, weight: .medium)).foregroundStyle(theme.accent)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    DeviceArtwork(keyboard: true, color: state.previewColor, brightness: state.previewBrightness)
                }.padding(.horizontal, 6)
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 25) {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("颜色").font(.system(size: 12, weight: .medium))
                        HStack(spacing: 15) {
                            ForEach(DeviceDetailState.colors.indices, id: \.self) { index in
                                Button { state.previewColorIndex = index } label: {
                                    Circle().fill(DeviceDetailState.colors[index].1).frame(width: 25, height: 25)
                                        .padding(4).overlay {
                                            Circle().strokeBorder(state.previewColorIndex == index ? theme.accent : theme.line, lineWidth: state.previewColorIndex == index ? 1.5 : 0.5)
                                        }
                                }.buttonStyle(.plain)
                                    .accessibilityLabel("预览颜色：\(DeviceDetailState.colors[index].0)")
                                    .accessibilityAddTraits(state.previewColorIndex == index ? .isSelected : [])
                            }
                        }
                    }
                    Rectangle().fill(theme.line).frame(height: 1)
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("预览亮度").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("\(Int(state.previewBrightness * 100))%")
                                .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "sun.min").foregroundStyle(.secondary)
                            PreviewBrightnessSlider(value: $state.previewBrightness)
                            Image(systemName: "sun.max").foregroundStyle(.secondary)
                        }.font(.system(size: 13))
                    }
                }.padding(4)
            }
            Text("设备灯效控制尚未开放。").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

/// A SwiftUI-only preview control. Its binding never reaches a device service.
private struct PreviewBrightnessSlider: View {
    @Binding var value: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - 14)
            ZStack(alignment: .leading) {
                Capsule().fill(RazerTheme(scheme: scheme).line).frame(height: 4)
                Capsule().fill(RazerTheme(scheme: scheme).accent)
                    .frame(width: 7 + travel * value, height: 4)
                Circle().fill(.white).frame(width: 14, height: 14)
                    .overlay { Circle().strokeBorder(Color.black.opacity(0.08)) }
                    .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
                    .offset(x: travel * value)
            }
            .frame(height: 24).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                value = min(1, max(0, (event.location.x - 7) / travel))
            })
        }
        .frame(height: 24).focusable()
        .onMoveCommand { direction in
            if direction == .left { value = max(0, value - 0.01) }
            if direction == .right { value = min(1, value + 0.01) }
        }
        .accessibilityElement().accessibilityLabel("本地预览亮度")
        .accessibilityValue("\(Int(value * 100))%")
        .accessibilityAdjustableAction { direction in
            if direction == .increment { value = min(1, value + 0.05) }
            if direction == .decrement { value = max(0, value - 0.05) }
        }
    }
}

struct PerformancePanel: View {
    let device: DeviceInfo
    var telemetry: MouseTelemetry? = nil
    var polling: MousePollingReading? = nil
    var isReadingPolling = false
    var pollingDisabled = false
    var onReadPolling: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("灵敏度与回报率").font(.system(size: 24, weight: .semibold))
            if !MouseReadService.canRead(device) {
                Text("此型号的性能查询尚未适配。").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 21) {
                    HStack { Label("灵敏度", systemImage: "scope"); Spacer(); SmallBadge(title: telemetry?.dpi != nil ? "设备读数" : "尚未读取") }
                        .font(.system(size: 12, weight: .medium))
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(telemetry?.dpi.map { String($0.current.x) } ?? "—").font(.system(size: 46, weight: .light, design: .rounded))
                        Text("DPI").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    if let dpi = telemetry?.dpi {
                        Text("X \(dpi.current.x) / Y \(dpi.current.y) · 当前第 \(dpi.activeStage) 档")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            ForEach(Array(dpi.stages.enumerated()), id: \.offset) { index, stage in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("\(index + 1) 档").font(.system(size: 10)).foregroundStyle(.secondary)
                                    Text(stage.x == stage.y ? "\(stage.x)" : "\(stage.x) / \(stage.y)")
                                        .font(.system(size: 13, weight: .medium, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(RazerTheme(scheme: scheme).accent.opacity(dpi.activeStage == index + 1 ? 0.12 : 0.025), in: RoundedRectangle(cornerRadius: 9))
                                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(RazerTheme(scheme: scheme).accent.opacity(dpi.activeStage == index + 1 ? 0.5 : 0.08)) }
                            }
                        }
                    } else {
                        Text("点击右上角“读取状态”查看 DPI。").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        VStack(alignment: .leading, spacing: 11) {
                            Label("回报率配置", systemImage: "waveform.path").font(.system(size: 12, weight: .medium))
                            Text("配置读数 · 非实测频率").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(polling?.configuredHertz.map { "\($0) Hz" } ?? "— Hz")
                            .font(.system(size: 26, weight: .light, design: .rounded)).foregroundStyle(.secondary)
                    }
                    HStack {
                        if let reading = polling {
                            Text("\(reading.issue == nil ? "取得于" : "尝试于") \(reading.readAt.formatted(date: .omitted, time: .standard))")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if PollingRateReadService.canRead(device) {
                            Button(isReadingPolling ? "正在读取…" : "读取回报率") { onReadPolling() }
                                .disabled(isReadingPolling || pollingDisabled)
                        }
                    }
                    if let issue = polling?.issue {
                        if let kind = issue.kind { SmallBadge(title: kind.title, color: .orange) }
                        Text(issue.message).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct ButtonMappingPanel: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        SurfaceCard {
            VStack(spacing: 22) {
                HStack(spacing: 10) {
                    ForEach(["command", "option", "shift"], id: \.self) { symbol in
                        Image(systemName: symbol).font(.system(size: 26, weight: .light))
                            .foregroundStyle(RazerTheme(scheme: scheme).accent)
                            .frame(width: 64, height: 64)
                            .background(RazerTheme(scheme: scheme).elevated, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                VStack(spacing: 10) {
                    Text("按键映射").font(.system(size: 24, weight: .semibold))
                    Text("按键映射与宏暂未开放。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
                }
            }.padding(.vertical, 64).frame(maxWidth: .infinity)
        }
    }
}
