import SwiftUI
import AppKit

/// First-run setup. Shown once, automatically, on the first launch after installation.
///
/// It exists because two of the three things this app needs cannot be done silently:
/// the privilege rule needs an admin password, and the hooks modify the user's own
/// agent config. Both should be explicit, previewable and reversible.
@MainActor
final class OnboardingController {
    static let shared = OnboardingController()
    private var window: NSWindow?

    static var hasCompletedSetup: Bool {
        get { UserDefaults.standard.bool(forKey: "setupComplete") }
        set { UserDefaults.standard.set(newValue, forKey: "setupComplete") }
    }

    func showIfFirstRun(state: AppState) {
        guard !Self.hasCompletedSetup else { return }
        // Mark it on presentation, not on Done. The window is closable, and every step it
        // offers also lives permanently in Settings, so closing it with the red button
        // means "later", not "show me again at every login".
        //
        // Except from a translocated bundle: that is a look-before-installing launch, and
        // consuming the one shot there would mean the real first launch shows nothing.
        if InstallLocation.isStable { Self.hasCompletedSetup = true }
        show(state: state)
    }

    func show(state: AppState) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(state: state) { [weak self] in
            Self.hasCompletedSetup = true
            self?.window?.close()
            self?.window = nil
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Lucid Setup"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = NSHostingView(rootView: view)
        window = w
        w.makeKeyAndOrderFront(nil)
        // LSUIElement apps have no Dock icon, so the window will not come forward on its own.
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Hook installation

enum HookInstaller {
    /// The bundled installer, copied into Resources by build.sh.
    static var scriptURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("hooks/install-hooks.sh")
    }

    /// Agents on this Mac that Lucid can hook.
    static var detected: [AgentDefinition] {
        AgentRegistry.all.filter { $0.detected && !$0.isManual }
    }

    static var anyInstalled: Bool { AgentRegistry.all.contains(where: \.installed) }

    /// Every hook calls ~/.lucid/lucid-notify, so an app update has to bring it along, or
    /// agents keep running the old client until their hooks are reinstalled. Renamed
    /// into place, so a hook firing mid-update never runs a half-written file.
    static func syncClient() {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("hooks/lucid-notify"),
              let new = try? Data(contentsOf: src) else { return }
        let dst = AppPaths.dir.appendingPathComponent("lucid-notify")
        guard (try? Data(contentsOf: dst)) != new else { return }
        let tmp = dst.appendingPathExtension("new")
        guard (try? new.write(to: tmp)) != nil, chmod(tmp.path, 0o755) == 0,
              rename(tmp.path, dst.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return
        }
    }

    @discardableResult
    static func run(agent: String, _ mode: String) -> (ok: Bool, output: String) {
        guard let script = scriptURL,
              FileManager.default.fileExists(atPath: script.path) else {
            return (false, "Installer not found in the app bundle.")
        }
        // Not waitUntilExit: it spins the main run loop, letting queued work run mid-call.
        let r = PowerManager.runTool("/bin/bash", [script.path, agent, mode],
                                     timeout: 30, mergeStderr: true)
        return (r.ok, r.out)
    }
}

// MARK: - View

struct OnboardingView: View {
    @Bindable var state: AppState
    var onFinish: () -> Void

    @State private var hooksInstalled = HookInstaller.anyInstalled
    @State private var hookOutput = ""
    @State private var loginItem = LoginItem.isEnabled
    @State private var adminPending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    privilegeStep
                    hooksStep
                    loginStep
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lucid").font(.title2.bold())
                Text("Stay awake while agents work. Sleep when they don't.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    // Step 1 ---------------------------------------------------------------
    private var privilegeStep: some View {
        StepCard(
            number: 1,
            title: "Lid-close support",
            done: state.privilegeRuleInstalled,
            required: true
        ) {
            Text("""
                 Keeping a Mac awake with the lid shut needs a system flag that only root \
                 can set. Power assertions can't do it — macOS treats lid close as a demand \
                 sleep and ignores them.

                 This installs a sudoers rule limited to exactly two commands. Nothing else \
                 is granted, and you can remove it at any time.
                 """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("pmset -a disablesleep 1  /  0")
                .font(.system(.caption2, design: .monospaced))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))

            HStack {
                Button(state.privilegeRuleInstalled ? "Reinstall" : "Install…") {
                    runAdmin { _ = await state.power.installPrivilegeRule() }
                }
                .buttonStyle(.borderedProminent)
                if state.privilegeRuleInstalled {
                    Button("Remove") {
                        runAdmin { _ = await state.power.removePrivilegeRule() }
                    }
                }
                Spacer()
                if adminPending { ProgressView().controlSize(.small) }
                Text("Asks for your password once")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .disabled(adminPending)
        }
    }

    // Step 2 ---------------------------------------------------------------
    private var hooksStep: some View {
        StepCard(
            number: 2,
            title: "Agent hooks",
            done: hooksInstalled,
            required: false
        ) {
            let found = HookInstaller.detected
            if found.isEmpty {
                Text("No supported agent found. Settings → Agents lists them, with a wrapper for anything else.")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("""
                     Found: \(found.map(\.name).joined(separator: ", ")). Hooks report when a \
                     turn starts and when the agent is waiting for input — the difference \
                     between "working" and "idle".

                     Existing hooks are preserved; changed files are backed up first.
                     """)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Preview") { runHooks("preview", found) }
                Button(hooksInstalled ? "Reinstall" : "Install Hooks") { runHooks("--apply", found) }
                    .buttonStyle(.borderedProminent)
                if hooksInstalled {
                    Button("Remove") {
                        runHooks("--uninstall", AgentRegistry.all.filter { $0.installed || $0.outdated })
                    }
                }
                Spacer()
            }
            .disabled(found.isEmpty)

            if !hookOutput.isEmpty {
                ScrollView {
                    Text(hookOutput)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    private func runAdmin(_ op: @escaping () async -> Void) {
        adminPending = true
        Task { await op(); adminPending = false }
    }

    private func runHooks(_ mode: String, _ agents: [AgentDefinition]) {
        hookOutput = agents.map { agent in
            let r = HookInstaller.run(agent: agent.id, mode)
            return "\(agent.name): " + r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n\n")
        hooksInstalled = HookInstaller.anyInstalled
    }

    // Step 3 ---------------------------------------------------------------
    private var loginStep: some View {
        StepCard(number: 3, title: "Start automatically", done: loginItem, required: false) {
            Toggle("Launch Lucid at login", isOn: Binding(
                get: { loginItem },
                set: {
                    LoginItem.setEnabled($0)
                    state.refreshLoginItem()
                    loginItem = LoginItem.isEnabled   // what happened, not what was asked
                }))
                .disabled(LoginItem.blockedReason != nil)
                .toggleStyle(.checkbox)
            Text("It runs in the menu bar with no Dock icon.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if !state.privilegeRuleInstalled {
                Label("Without step 1, only idle sleep is prevented (lid-open only).",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: onFinish)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

/// A numbered step with a completion tick.
private struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    let required: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(done ? Color.green : Color.secondary.opacity(0.25))
                        .frame(width: 22, height: 22)
                    if done {
                        Image(systemName: "checkmark")
                            .font(.caption2.bold()).foregroundStyle(.white)
                    } else {
                        Text("\(number)").font(.caption2.bold()).foregroundStyle(.secondary)
                    }
                }
                Text(title).font(.headline)
                if required && !done {
                    Text("required for lid-close")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(.leading, 30)
        }
    }
}
