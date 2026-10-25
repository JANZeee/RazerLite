import SwiftUI
import RazerLiteCore

/// Historical values are secondary and always carry their original timestamp and source.
struct PreviousReadingsView: View {
    let assessment: AdapterAssessment
    private var previous: [DeviceCapability] { assessment.capabilities.filter { $0.session.previous != nil } }

    var body: some View {
        if !previous.isEmpty {
            DisclosureGroup("上次成功读数 · \(previous.count) 项") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(previous) { capability in
                        if let sample = capability.session.previous {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(capability.title) · \(sample.value)").font(.system(size: 11, weight: .medium))
                                Text("\(sample.at.formatted(date: .abbreviated, time: .standard)) · \(sample.source)")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .help("上次成功的历史值，不能用于判断当前设备状态；断连或睡眠后清除")
        }
    }
}
