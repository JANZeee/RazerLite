#if DEBUG
import SwiftUI
import RazerLiteCore

/// Explicit developer rendering path using the same isolated services as the scenario app.
struct CapabilityValidationView: View {
    let session: OfflineScenarioSession
    var body: some View {
        Text("正在验证离线能力界面…").padding(40).task {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: "--validate-capabilities-dir"), arguments.indices.contains(index + 1) else {
                NSApp.terminate(nil); return
            }
            let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for scenario in [OfflineScenario.unread, .keyboard, .bluetooth, .partial, .retryFailed, .timeout, .empty] {
                    await session.load(scenario)
                    try session.manager.snapshotData().write(to: directory.appendingPathComponent("\(scenario.rawValue).json"))
                    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                        let theme = RazerTheme(scheme: scheme)
                        if let device = session.manager.devices.first, scenario != .timeout {
                            let assessment = session.manager.adapterAssessment(for: device)
                            let view = VStack(alignment: .leading, spacing: 18) {
                                Label("模拟数据 · \(device.product)", systemImage: "testtube.2").font(.headline).foregroundStyle(.orange)
                                PreviousReadingsView(assessment: assessment)
                                SurfaceCard { DeviceCapabilitiesView(assessment: assessment) }
                            }.padding(24).frame(width: 700).background(theme.canvas).environment(\.colorScheme, scheme)
                            try render(view, at: directory.appendingPathComponent("\(scenario.rawValue)-\(name).png"))
                        }
                    }
                }
                try Data("Capability content rendered with synthetic services only. Connection-check JSON is included. Native scrolling, disclosure, toolbar, menu and export interactions require separate verification.\n".utf8)
                    .write(to: directory.appendingPathComponent("success.txt"))
            } catch {
                try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("error.txt"))
            }
            session.manager.stop()
            NSApp.terminate(nil)
        }
    }

    @MainActor private func render<Content: View>(_ content: Content, at url: URL) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw CocoaError(.coderInvalidValue) }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.coderInvalidValue) }
        try data.write(to: url)
    }
}
#endif
