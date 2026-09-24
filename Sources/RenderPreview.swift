#if DEBUG_RENDER
import AppKit
import SwiftUI

/// `--render-settings <dir>` dumps each settings pane to a PNG.
///
/// This exists so the UI can be inspected without Screen Recording permission. It renders
/// the real AppKit-backed view hierarchy via cacheDisplay, not an approximation, so what
/// lands in the PNG is what the window shows.
enum RenderPreview {
    @MainActor
    static func run(outDir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let state = AppState()
        let dir = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func render(_ name: String, _ view: AnyView, menu: Bool) {
            // The menu sizes itself (its width is fixed at 320); a settings pane gets the
            // window's size.
            let host = NSHostingView(rootView: menu ? view : AnyView(view.frame(width: 560, height: 500)))
            host.frame = NSRect(origin: .zero,
                                size: menu ? host.fittingSize : NSSize(width: 560, height: 500))

            let win = NSWindow(contentRect: host.frame, styleMask: [.titled],
                               backing: .buffered, defer: false)
            win.contentView = host
            win.layoutIfNeeded()
            // Give SwiftUI a beat to resolve its layout before capturing.
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            if menu { host.setFrameSize(host.fittingSize) }
            host.layoutSubtreeIfNeeded()

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
                print("rendered \(name).png")
            }
        }

        // The popover material is painted by the system at runtime; supply an equivalent
        // here or dark-mode text lands white-on-white.
        func menuView() -> AnyView {
            AnyView(LucidMenuView(state: state).background(Color(nsColor: .windowBackgroundColor)))
        }

        render("1-general",     AnyView(GeneralSettings(state: state)), menu: false)
        render("2-power",       AnyView(PowerSettings(state: state)), menu: false)
        render("3-agents",      AnyView(AgentSettings(state: state)), menu: false)
        render("4-privileges",  AnyView(PrivilegeSettings(state: state)), menu: false)
        render("5-history",     AnyView(HistorySettings(state: state)), menu: false)
        render("6-diagnostics", AnyView(DiagnosticsSettings(state: state)), menu: false)
        render("7-menu",        menuView(), menu: true)

        // Rendered only after the empty menu, so the two captures really differ: the
        // populated layout — rows, badges, counts — is checked, not only the empty state.
        state.lifecycle.handle(AgentEvent(agent: "claude-code", session_id: "a1",
                                          status: .working, detail: "Tool Running", pid: nil))
        state.lifecycle.handle(AgentEvent(agent: "codex", session_id: "b2",
                                          status: .idle, detail: "Waiting for prompt", pid: nil))
        state.lifecycle.handle(AgentEvent(agent: "cursor", session_id: "c3",
                                          status: .working, detail: "Active process", pid: nil))
        render("8-menu-busy", menuView(), menu: true)
        exit(0)
    }
}
#endif
