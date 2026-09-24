import Foundation

/// Undoes everything the app put on the system.
///
/// Order matters: release the lock first. If the sudoers rule or the arm marker goes
/// while a SleepDisabled flag we set is still on, nothing is left that can clear it and
/// the Mac cannot sleep again, across reboots.
@MainActor
enum Uninstaller {

    struct Step: Identifiable {
        let id = UUID()
        let name: String
        let detail: String
        let ok: Bool
    }

    /// Disarms, then says whether nothing Lucid set is left for the steps below to orphan.
    private static func released(_ power: PowerManager) -> Bool {
        power.disarm()
        // A marker with the flag clear and not ours is a leftover (a recovery that failed,
        // then fixed by hand), which launch recovery would delete the same way.
        if !power.ownsSleepDisabled, PowerManager.readSleepDisabled() == false {
            try? FileManager.default.removeItem(at: AppPaths.armMarker)
        }
        return !power.ownsSleepDisabled
            && !FileManager.default.fileExists(atPath: AppPaths.armMarker.path)
    }

    private static var stopped: Step {
        Step(name: "Stopped — the wake lock did not release",
             detail: "Lucid could not clear the SleepDisabled flag it set. Clear it first with: "
                   + "sudo pmset -a disablesleep 0",
             ok: false)
    }

    /// The caller must already have stopped the lock from re-arming (mode off).
    static func run(power: PowerManager, removePrivilege: Bool) async -> [Step] {
        var steps: [Step] = []

        // 1. Release. The gate is ownership, not the live flag: a flag the user set
        // themselves does not depend on anything below, but one we set, or one a crashed
        // run left behind, does.
        guard released(power) else { return [stopped] }
        let live = PowerManager.readSleepDisabled()
        steps.append(Step(name: "Released the wake lock",
                          detail: live == true ? "SleepDisabled is 1, set outside Lucid — left as it is"
                                               : "SleepDisabled is 0",
                          ok: true))

        // 2. Hooks, per agent that actually has them.
        var hooksLeft = false
        for agent in AgentRegistry.all where agent.installed || agent.outdated {
            let r = HookInstaller.run(agent: agent.id, "--uninstall")
            if !r.ok { hooksLeft = true }
            steps.append(Step(name: "Removed \(agent.name) hooks",
                              detail: r.ok ? "Lucid's entries removed"
                                           : r.output.trimmingCharacters(in: .whitespacesAndNewlines),
                              ok: r.ok))
        }

        // 3. The sudoers rule. Needs the admin prompt, so it is optional.
        if removePrivilege && power.ruleInstalled {
            let ok = await power.removePrivilegeRule()
            steps.append(Step(name: "Removed the privilege rule",
                              detail: ok ? AppPaths.sudoersFile
                                          : "cancelled — run: sudo rm \(AppPaths.sudoersFile)",
                              ok: ok))
        }

        // 4. Support directory — socket, arm marker, status, history, notify script.
        // Again: the admin prompt above freed the main actor, and a lid test or ⌃⌥⌘L can
        // re-arm meanwhile. Deleting the marker under a flag we hold orphans it.
        guard released(power) else { return steps + [stopped] }
        let dir = AppPaths.dir
        do {
            AppPaths.removed = true       // nothing may recreate it on the way out
            let fm = FileManager.default
            if hooksLeft {
                // Hooks we could not remove still call lucid-notify. Left in place it exits
                // quietly once the socket is gone; deleted, every hook event fails.
                for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                where name != "lucid-notify" {
                    try fm.removeItem(at: dir.appendingPathComponent(name))
                }
            } else if fm.fileExists(atPath: dir.path) {
                try fm.removeItem(at: dir)
            }
            // Preferences live in the defaults domain, not in ~/.lucid, so removing
            // the directory alone would leave setupComplete set and a reinstall would
            // never show first-run setup again.
            if let id = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: id)
            }
            steps.append(Step(name: "Deleted app data and preferences",
                              detail: hooksLeft ? "\(dir.path) (kept lucid-notify: some hooks still call it)"
                                                : dir.path,
                              ok: true))
        } catch {
            steps.append(Step(name: "Deleted app data",
                              detail: error.localizedDescription, ok: false))
        }

        // 5. Launch at login.
        if LoginItem.plistExists {
            let ok = LoginItem.setEnabled(false)
            steps.append(Step(name: "Removed the login item",
                              detail: LoginItem.plistURL.path, ok: ok))
        }

        return steps
    }

    /// The bundle itself can't delete itself while running; tell the user where it is.
    static var bundlePath: String {
        Bundle.main.bundleURL.path
    }
}
