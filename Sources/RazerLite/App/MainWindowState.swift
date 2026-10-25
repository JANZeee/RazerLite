import AppKit
import SwiftUI

/// Native frame autosaving is scoped to this app's defaults. No device state is
/// restored. This view observes attachment, not a timer or a window polling loop.
struct MainWindowState: NSViewRepresentable {
    let autosaveName: String
    func makeNSView(context: Context) -> FrameSavingView {
        FrameSavingView(autosaveName: autosaveName)
    }
    func updateNSView(_ nsView: FrameSavingView, context: Context) {}
}

final class FrameSavingView: NSView {
    let autosaveName: String
    private weak var configuredWindow: NSWindow?
    init(autosaveName: String) {
        self.autosaveName = autosaveName
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, configuredWindow !== window else { return }
        configuredWindow = window
        window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
    }
}
