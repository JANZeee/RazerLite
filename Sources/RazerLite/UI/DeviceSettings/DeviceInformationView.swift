import SwiftUI
import RazerLiteCore

struct DeviceInformationView: View {
    let device: DeviceInfo
    let logs: [DiagnosticLog]
    let assessment: AdapterAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text("关于这台设备").font(.system(size: 15, weight: .semibold))
                    field("产品名称", device.product)
                    field("VID / PID", "\(hexID(device.vendorID)) / \(hexID(device.productID))")
                    field("连接方式", device.transport)
                    field("固件版本", "尚未查询")
                    Text(assessment.connectionEvidence).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                }
            }
            if !device.observedDrivers.isEmpty {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("检测到 Razer 驱动绑定", systemImage: "info.circle").font(.system(size: 12, weight: .medium))
                        Text("状态响应可能受到其他控制程序干扰。响应不匹配时会停止查询，不会自动停止现有软件。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(device.observedDrivers.joined(separator: "\n")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            SurfaceCard {
                DisclosureGroup("功能适配详情") {
                    DeviceCapabilitiesView(assessment: assessment).padding(.top, 18)
                }.font(.system(size: 12, weight: .medium))
            }
            SurfaceCard {
                DisclosureGroup("适配证据与接口条件") {
                    VStack(alignment: .leading, spacing: 12) {
                        field("适配器", assessment.adapterName)
                        field("适配 ID", assessment.adapterID ?? "无可执行适配器")
                        if let manifest = AdapterManifestCatalog.all.first(where: { $0.id == assessment.adapterID }) {
                            field("接口指纹", manifest.fingerprint?.title ?? "系统蓝牙属性；所有接口须为蓝牙")
                            field("固件范围", manifest.firmwareScope)
                            ForEach(manifest.sources, id: \.url) { source in
                                Link("查看固定协议来源 ↗", destination: source.url).font(.caption)
                                Text(source.revision ?? "Apple 系统 API 文档，无提交版本").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        } else if let url = assessment.sourceURL {
                            Link("型号目录来源 ↗", destination: url).font(.caption)
                        }
                    }.padding(.top, 16)
                }.font(.system(size: 12, weight: .medium))
            }
            Text("HID 接口 · \(device.interfaces.count)").font(.system(size: 14, weight: .semibold)).padding(.top, 6)
            Text("下列版本属性不等同于已验证的固件版本。报文长度来自系统属性；只有手动状态查询才收发指定 Feature Report。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(device.interfaces) { interface in
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(interface.usbInterfaceNumber.map { "USB interface \($0)" } ?? "HID interface")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(String(format: "0x%llX", interface.id)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        field("Usage page / usage", "\(hexID(interface.primaryUsagePage)) / \(hexID(interface.primaryUsage))")
                        field("Input / Output / Feature", "\(size(interface.maxInputReportSize)) / \(size(interface.maxOutputReportSize)) / \(size(interface.maxFeatureReportSize)) 字节")
                        field("VersionNumber / bcdDevice", "\(hexID(interface.versionNumber)) / \(hexID(interface.usbDeviceRelease))")
                        field("Location ID", hexID(interface.locationID, width: 8))
                        field("USB 父设备", interface.usbDeviceID.map { String(format: "0x%llX", $0) } ?? "未发布")
                        field("IORegistry 类", interface.registryClass)
                        field("全部 usage", interface.usages.map { "\(hexID($0.page))/\(hexID($0.usage))" }.joined(separator: ", "))
                    }
                }
            }
            SurfaceCard {
                DisclosureGroup("诊断日志 · 最近 \(logs.count) 条") {
                    VStack(alignment: .leading, spacing: 11) {
                        Text("服务日志覆盖全部设备，不记录键鼠输入。").font(.caption).foregroundStyle(.secondary)
                        ForEach(logs.reversed()) { entry in
                            HStack(alignment: .top, spacing: 12) {
                                Text(entry.time, style: .time).foregroundStyle(.secondary)
                                Text(entry.message).foregroundStyle(entry.isError ? Color.red : .primary)
                            }.font(.system(size: 10, design: .monospaced))
                        }
                    }.padding(.top, 16).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 12, weight: .medium))
            }
        }.textSelection(.enabled)
    }

    private func field(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title).foregroundStyle(.secondary).frame(width: 160, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11))
    }
    private func size(_ value: Int?) -> String { value.map(String.init) ?? "未知" }
}

struct DeviceCapabilitiesView: View {
    let assessment: AdapterAssessment
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("实现状态、历史验证与本次结果分别显示。未实现不代表硬件不支持。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(assessment.capabilities) { capability in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 16) {
                        Text(capability.title).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                        SmallBadge(title: capability.implementation.title, color: capability.implementation == .implemented ? .green : .secondary)
                    }
                    if capability.implementation == .implemented {
                        HStack(spacing: 8) {
                            Text(capability.evidence.level.title)
                            Text("·")
                            Text(capability.session.state.title)
                                .foregroundStyle(capability.session.state == .failed || capability.session.state == .unconfirmed ? .orange : .secondary)
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("查看说明") {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(capability.evidence.scope)
                            Text(capability.session.detail)
                            if let value = capability.session.value { Text("读取值：\(value)") }
                            if let previous = capability.session.previous {
                                Text("上次成功：\(previous.value)")
                                Text("\(previous.at.formatted(date: .abbreviated, time: .standard)) · \(previous.source)")
                            }
                            if let source = capability.session.source { Text("来源：\(source)") }
                            if let at = capability.session.at {
                                Text("结果时间：\(at.formatted(date: .abbreviated, time: .standard))")
                            }
                            if !capability.evidence.records.isEmpty {
                                Text("验证记录：\(capability.evidence.records.joined(separator: "、"))")
                            }
                        }.padding(.top, 7).textSelection(.enabled)
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if capability.id != assessment.capabilities.last?.id { Divider() }
            }
        }
    }
}
