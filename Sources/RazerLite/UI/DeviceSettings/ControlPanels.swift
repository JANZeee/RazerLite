import SwiftUI
import RazerLiteCore

struct PerformancePanel: View {
    let device: DeviceInfo
    var telemetry: MouseTelemetry? = nil
    var polling: MousePollingReading? = nil
    var manager: DeviceManager? = nil
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
                                Button {
                                    guard let manager else { return }
                                    Task { await manager.prepareDPIStageSwitch(for: device.id, baseline: dpi, stage: index + 1) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text("\(index + 1) 档").font(.system(size: 10)).foregroundStyle(.secondary)
                                        Text(stage.x == stage.y ? "\(stage.x)" : "\(stage.x) / \(stage.y)")
                                            .font(.system(size: 13, weight: .medium, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(RazerTheme(scheme: scheme).accent.opacity(dpi.activeStage == index + 1 ? 0.12 : 0.025), in: RoundedRectangle(cornerRadius: 9))
                                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(RazerTheme(scheme: scheme).accent.opacity(dpi.activeStage == index + 1 ? 0.5 : 0.08)) }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(dpi.activeStage == index + 1 || manager == nil || manager?.isSuspended == true
                                          || manager?.isDeviceBusy(device.id) == true)
                                .accessibilityLabel("第 \(index + 1) 档，X \(stage.x) / Y \(stage.y) DPI")
                                .accessibilityAddTraits(dpi.activeStage == index + 1 ? .isSelected : [])
                                .help(dpi.activeStage == index + 1 ? "当前档位" : "切换到此档位，确认后应用")
                            }
                        }
                    } else {
                        Text("等待设备返回 DPI 档位。").font(.system(size: 11)).foregroundStyle(.secondary)
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
                    if let manager, PollingRateReadService.canRead(device) {
                        PollingRateEditorView(device: device, manager: manager)
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
