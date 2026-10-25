import SwiftUI
import RazerLiteCore

@MainActor
private final class CatalogSearchState: ObservableObject {
    @Published var query = ""
    @Published var filter = CatalogFilter.all
}

private enum CatalogFilter: String, CaseIterable, Identifiable {
    case all = "全部型号", adapters = "有 USB 适配", connected = "目录内已发现"
    var id: String { rawValue }
}

struct DeviceCatalogView: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject var workspace: AppWorkspace
    @StateObject private var search = CatalogSearchState()
    @Environment(\.colorScheme) private var scheme

    private var matches: [RazerModelReference] {
        let query = search.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return AdapterCatalog.modelEntries.filter {
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || hexID($0.productID).localizedCaseInsensitiveContains(query)
                || $0.kind.title.contains(query))
                && (search.filter != .adapters || usbManifest($0) != nil)
                && (search.filter != .connected || connectedDevices($0).isEmpty == false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("设备目录").font(.system(size: 25, weight: .semibold)).tracking(-0.5)
                    Text("\(RazerModelCatalog.entries.count) 个上游型号参考 · 内置 USB 适配另行标注")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text("型号收录不代表所有功能已适配。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("目录范围", selection: $search.filter) {
                ForEach(CatalogFilter.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 440)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索型号、PID 或类型", text: $search.query).textFieldStyle(.plain)
                    .accessibilityLabel("搜索 Razer 设备目录")
                if !search.query.isEmpty {
                    Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索")
                }
            }.padding(11).background(RazerTheme(scheme: scheme).surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(RazerTheme(scheme: scheme).line) }
            if matches.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text("没有找到型号").font(.system(size: 17, weight: .medium))
                    Text("试试其他名称或 PID。").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(matches) { entry in
                    HStack(spacing: 13) {
                        Image(systemName: entry.kind.symbol).font(.system(size: 19))
                            .foregroundStyle(RazerTheme(scheme: scheme).accent)
                            .frame(width: 36, height: 36)
                            .background(RazerTheme(scheme: scheme).selected, in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.name).font(.system(size: 12, weight: .medium))
                            Text("1532:\(String(format: "%04X", entry.productID)) · \(entry.kind.title)")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            if let manifest = usbManifest(entry) {
                                Text(manifest.features.filter { $0.implementation == .implemented }.map { feature in
                                    AdapterCatalog.featureTitles.first { $0.0 == feature.id }?.1 ?? feature.id
                                }.joined(separator: " · "))
                                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                            } else {
                                Text("型号参考 · 此 USB 型号尚无控制适配")
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        let connected = connectedDevices(entry)
                        if let device = connected.first {
                            Button("查看设备") { workspace.select(device, page: .information) }
                                .buttonStyle(.borderless).controlSize(.small)
                                .accessibilityLabel("查看 \(device.product) 的设备信息")
                                .help(connected.count > 1 ? "已发现 \(connected.count) 台；打开第一台，其余可在侧栏选择" : "查看本次连接的适配状态")
                        } else if let manifest = usbManifest(entry) {
                            SmallBadge(title: manifest.features.contains { $0.level == .hardwareValidated } ? "USB · 有真机记录" : "USB · 试验适配", color: .secondary)
                        }
                    }.padding(.vertical, 5)
                }.listStyle(.inset)
            }
            HStack {
                Text("\(matches.count) 项")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Link("OpenRazer 来源 ↗", destination: RazerModelCatalog.sourceURL).font(.system(size: 10))
            }
        }.padding(28).background(RazerTheme(scheme: scheme).canvas)
    }

    private func usbManifest(_ entry: RazerModelReference) -> DeviceAdapterManifest? {
        AdapterManifestCatalog.all.first { $0.vendorIDs.contains(0x1532) && $0.productIDs.contains(entry.productID) && $0.transports.contains("USB") }
    }

    private func connectedDevices(_ entry: RazerModelReference) -> [DeviceInfo] {
        manager.physicalDevices.filter { $0.vendorID == 0x1532 && $0.productID == entry.productID }
    }
}
