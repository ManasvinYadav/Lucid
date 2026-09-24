import AppKit

// Explicit entry point rather than @main so --selftest can run *before* any of the app is
// constructed. AppState's initialiser binds the hook socket, which unlinks any existing
// one — running a self-test while the app is live would otherwise silently steal the
// listener out from under the running instance.
if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

// Scriptable toggle — also what makes the login item testable without clicking a checkbox.
if let i = CommandLine.arguments.firstIndex(of: "--login-item"),
   i + 1 < CommandLine.arguments.count {
    // Anything but on/off is a mistake, not "off": off boots out a running instance.
    let arg = CommandLine.arguments[i + 1]
    guard arg == "on" || arg == "off" else {
        FileHandle.standardError.write(Data("usage: --login-item on|off\n".utf8))
        exit(2)
    }
    let on = arg == "on"
    let ok = LoginItem.setEnabled(on)
    print("launch at login: \(on ? "enabled" : "disabled")\(ok ? "" : " (FAILED)")")
    exit(ok ? 0 : 1)
}

// One instance per user, whatever copy of the bundle it runs from. A second one treated
// the first one's arm marker as a crash and cleared its SleepDisabled, took over the hook
// socket, and on quitting unlinked the socket the survivor was listening on. The kernel
// drops the lock on any exit, kill -9 included, so it can never go stale. Held (and the
// fd deliberately leaked) for the life of the process.
let instanceLock = open(AppPaths.instanceLock.path, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK, 0o600)
if instanceLock < 0 {
    if errno == EWOULDBLOCK {
        let me = ProcessInfo.processInfo.processIdentifier
        let other = Bundle.main.bundleIdentifier.map {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }?.first { $0.processIdentifier != me }
        print("Lucid is already running\(other.map { " (pid \($0.processIdentifier))" } ?? "").")
        other?.activate()
    } else {
        print("cannot open \(AppPaths.instanceLock.path): \(String(cString: strerror(errno)))")
    }
    exit(0)
}

#if DEBUG_RENDER
if let i = CommandLine.arguments.firstIndex(of: "--render-settings"),
   i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { RenderPreview.run(outDir: CommandLine.arguments[i + 1]) }
}
#endif

LucidApp.main()
