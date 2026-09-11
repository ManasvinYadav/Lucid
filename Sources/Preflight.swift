import Foundation

/// Checks the things that must be true for a lid-closed run, at the last moment the user
/// can still be told: when the lock arms with the lid still open.
///
/// The app verifies its privileged layer once at launch. Between then and the moment it
/// matters, a system update can restore /etc/sudoers.d, another tool can rewrite the
/// agent's config and drop the hooks, or the app can be moved. Each of those fails
/// silently and is only discovered by coming back to a Mac that slept.
@MainActor
struct Preflight {

    struct Issue: Identifiable {
        let id = UUID()
        let text: String
        let severity: Severity
        enum Severity { case blocking, warning }
    }

    /// Nothing here runs a subprocess that can prompt, and the whole pass is bounded —
    /// `sudo -n -l` returns immediately when no password is needed.
    static func run(state: AppState) -> [Issue] {
        var issues: [Issue] = []
        let prefs = Preferences.shared

        if prefs.lidCloseCoverage {
            if !PowerManager.isPrivilegeRuleInstalled() {
                issues.append(Issue(
                    text: "The privilege rule is gone — a system update can remove it. Lid-close coverage will fall back to the power assertion alone.",
                    severity: .warning))
            } else if PowerManager.readSleepDisabled() == false, state.power.isArmed {
                issues.append(Issue(
                    text: "SleepDisabled did not take effect despite the rule being installed.",
                    severity: .blocking))
            }
        }

        // Hooks are what make the difference between working and idle. Losing them
        // silently downgrades the app to process guessing.
        let installed = AgentRegistry.all.filter { $0.installed }
        let detected  = AgentRegistry.all.filter { $0.detected && $0.configPath != nil }
        if installed.isEmpty && !detected.isEmpty && !prefs.processFallbackEnabled {
            issues.append(Issue(
                text: "No agent hooks are installed and the process fallback is off, so nothing can report agent state.",
                severity: .blocking))
        } else if installed.isEmpty && !detected.isEmpty {
            issues.append(Issue(
                text: "No agent hooks are installed — falling back to process detection, which cannot tell working from waiting.",
                severity: .warning))
        }

        if !state.lifecycle.isListening {
            issues.append(Issue(text: "The hook listener is not accepting connections.",
                                severity: .blocking))
        }
        if !InstallLocation.isStable {
            issues.append(Issue(text: InstallLocation.advice, severity: .warning))
        }
        if state.guardrails.isBlocking, let r = state.guardrails.yieldReason {
            issues.append(Issue(text: r.summary, severity: .blocking))
        }
        return issues
    }
}
