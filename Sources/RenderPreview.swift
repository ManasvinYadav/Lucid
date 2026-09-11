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

        let panes: [(String, AnyView)] = [
            ("1-general",     AnyView(GeneralSettings(state: state))),
            ("2-power",       AnyView(PowerSettings(state: state))),
            ("3-agents",      AnyView(AgentSettings(state: state))),
            ("4-privileges",  AnyView(PrivilegeSettings(state: state))),
            ("5-history",     AnyView(HistorySettings(state: state))),
            ("6-diagnostics", AnyView(DiagnosticsSettings(state: state))),
            // The popover material is painted by the system at runtime; supply an
            // equivalent here or dark-mode text lands white-on-white.
            ("7-menu",        AnyView(LucidMenuView(state: state)
                                        .background(Color(nsColor: .windowBackgroundColor)))),
        ]

        // A second menu render with sessions present, so the populated layout — rows,
        // badges, counts — is checked rather than only the empty state.
        state.lifecycle.handle(AgentEvent(agent: "claude-code", session_id: "a1",
                                          status: .working, detail: "Tool Running", pid: nil))
        state.lifecycle.handle(AgentEvent(agent: "codex", session_id: "b2",
                                          status: .idle, detail: "Waiting for prompt", pid: nil))
        state.lifecycle.handle(AgentEvent(agent: "cursor", session_id: "c3",
                                          status: .working, detail: "Active process", pid: nil))
        let busy: [(String, AnyView)] = [
            ("8-menu-busy", AnyView(LucidMenuView(state: state)
                                      .background(Color(nsColor: .windowBackgroundColor)))),
        ]

        for (name, view) in panes + busy {
            let size = name.hasSuffix("menu") || name.hasSuffix("busy")
                            ? NSSize(width: 320, height: 620)
                                        : NSSize(width: 560, height: 500)
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)

            let win = NSWindow(contentRect: host.frame, styleMask: [.titled],
                               backing: .buffered, defer: false)
            win.contentView = host
            win.layoutIfNeeded()
            // Give SwiftUI a beat to resolve its layout before capturing.
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded()

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
                print("rendered \(name).png")
            }
        }
        exit(0)
    }
}
#endif
