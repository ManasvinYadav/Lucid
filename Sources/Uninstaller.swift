import Foundation

/// Undoes everything the app put on the system.
///
/// Order matters: disarm first. If the sudoers rule goes before `SleepDisabled` is
/// cleared, we lose the ability to clear it and the Mac is left permanently unable to
/// sleep — the exact state the arm-marker exists to prevent.
@MainActor
enum Uninstaller {

    struct Step: Identifiable {
        let id = UUID()
        let name: String
        let detail: String
        let ok: Bool
    }

    /// Everything except the sudoers rule, which needs an admin prompt and is offered
    /// separately so the user can keep it if they plan to reinstall.
    static func run(power: PowerManager, removePrivilege: Bool) -> [Step] {
        var steps: [Step] = []

        // 1. Disarm. Always first, and a hard gate on everything after it.
        power.disarm()
        let disabled = PowerManager.readSleepDisabled()
        guard disabled != true else {
            // Stop here. Steps 4 and 5 delete the arm marker and the privilege rule —
            // between them, the only two ways left to clear the flag. Removing them
            // while SleepDisabled is still 1 would leave a Mac that can never sleep
            // again, across reboots, with nothing left to fix it.
            return [Step(name: "Stopped — the wake lock did not release",
                         detail: "SleepDisabled is still 1. Clear it first with: "
                               + "sudo pmset -a disablesleep 0",
                         ok: false)]
        }
        steps.append(Step(name: "Released the wake lock",
                          detail: disabled == false ? "SleepDisabled is 0"
                                                    : "SleepDisabled unreadable, nothing was engaged",
                          ok: true))

        // 2. Hooks, per agent that actually has them.
        for agent in AgentRegistry.all where agent.installed {
            let r = HookInstaller.run(agent: agent.id, "--uninstall")
            steps.append(Step(name: "Removed \(agent.name) hooks",
                              detail: r.ok ? "config restored (a .bak was kept)"
                                           : r.output.trimmingCharacters(in: .whitespacesAndNewlines),
                              ok: r.ok))
        }

        // 3. Launch at login.
        if LoginItem.isEnabled {
            let ok = LoginItem.setEnabled(false)
            steps.append(Step(name: "Removed the login item",
                              detail: LoginItem.plistURL.path, ok: ok))
        }

        // 4. Support directory — socket, arm marker, status, history, notify script.
        do {
            if FileManager.default.fileExists(atPath: AppPaths.dir.path) {
                try FileManager.default.removeItem(at: AppPaths.dir)
            }
            // Preferences live in the defaults domain, not in ~/.lucid, so removing
            // the directory alone would leave setupComplete set and a reinstall would
            // never show first-run setup again.
            if let id = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: id)
            }
            steps.append(Step(name: "Deleted app data and preferences",
                              detail: AppPaths.dir.path, ok: true))
        } catch {
            steps.append(Step(name: "Deleted app data",
                              detail: error.localizedDescription, ok: false))
        }

        // 5. The sudoers rule, last, because it needs the admin prompt.
        if removePrivilege && PowerManager.isPrivilegeRuleInstalled() {
            let ok = power.removePrivilegeRule()
            steps.append(Step(name: "Removed the privilege rule",
                              detail: ok ? AppPaths.sudoersFile
                                          : "cancelled — run: sudo rm \(AppPaths.sudoersFile)",
                              ok: ok))
        }

        return steps
    }

    /// The bundle itself can't delete itself while running; tell the user where it is.
    static var bundlePath: String {
        Bundle.main.bundleURL.path
    }
}
