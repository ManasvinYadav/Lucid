import Foundation

// Explicit entry point rather than @main so --selftest can run *before* any of the app is
// constructed. AppState's initialiser binds the hook socket, which unlinks any existing
// one — running a self-test while the app is live would otherwise silently steal the
// listener out from under the running instance.
if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

// Scriptable toggle — also what makes the login item testable without clicking a checkbox.
if let i = CommandLine.arguments.firstIndex(of: "--login-item"),
   i + 1 < CommandLine.arguments.count {
    let on = CommandLine.arguments[i + 1] == "on"
    let ok = LoginItem.setEnabled(on)
    print("launch at login: \(on ? "enabled" : "disabled")\(ok ? "" : " (FAILED)")")
    exit(ok ? 0 : 1)
}

#if DEBUG_RENDER
if let i = CommandLine.arguments.firstIndex(of: "--render-settings"),
   i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { RenderPreview.run(outDir: CommandLine.arguments[i + 1]) }
}
#endif

LucidApp.main()
