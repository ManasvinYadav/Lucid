import Foundation

/// How an agent gets wired up to report its lifecycle.
enum HookMechanism {
    /// Merged into a JSON settings file that has a `hooks` object.
    case jsonHooks(path: String)
    /// Merged into a TOML config file.
    case tomlHooks(path: String)
    /// No hook system exists — the user wraps the binary, or we fall back to process
    /// activity. We do not pretend otherwise.
    case manual
}

struct AgentDefinition: Identifiable {
    let id: String              // wire value, e.g. "claude-code"
    let name: String
    let mechanism: HookMechanism
    /// True only where the event names and file format were checked against a real
    /// install. Everything else is a best-effort mapping the user should confirm.
    let verified: Bool
    let note: String

    var configPath: String? {
        switch mechanism {
        case let .jsonHooks(p), let .tomlHooks(p):
            return NSString(string: p).expandingTildeInPath
        case .manual:
            return nil
        }
    }

    var configExists: Bool {
        guard let p = configPath else { return false }
        return FileManager.default.fileExists(atPath: p)
    }

    /// Detected = its config directory is present, so the agent is plausibly installed.
    var detected: Bool {
        guard let p = configPath else { return false }
        return FileManager.default.fileExists(
            atPath: (p as NSString).deletingLastPathComponent)
    }

    var installed: Bool {
        guard let p = configPath,
              let s = try? String(contentsOfFile: p, encoding: .utf8) else { return false }
        return s.contains("lucid-notify")
    }
}

enum AgentRegistry {
    /// Ordered by how much confidence we have in the mapping.
    static let all: [AgentDefinition] = [
        AgentDefinition(
            id: "claude-code", name: "Claude Code",
            mechanism: .jsonHooks(path: "~/.claude/settings.json"),
            verified: true,
            note: "Notification fires when Claude Code is waiting for input, which distinguishes working from idle."),

        AgentDefinition(
            id: "codex", name: "Codex CLI",
            mechanism: .tomlHooks(path: "~/.codex/config.toml"),
            verified: false,
            note: "Best-effort mapping to pre_turn/post_turn. Confirm against the installed Codex CLI version before relying on it."),

        AgentDefinition(
            id: "opencode", name: "opencode",
            mechanism: .jsonHooks(path: "~/.config/opencode/config.json"),
            verified: false,
            note: "Best-effort mapping. Confirm that the installed build reads a hooks object from this path."),

        AgentDefinition(
            id: "gemini", name: "Gemini CLI",
            mechanism: .manual, verified: false,
            note: "No hook interface confirmed. Covered by process detection, or wrap the binary for exact working/idle state."),

        AgentDefinition(
            id: "copilot", name: "Copilot CLI",
            mechanism: .manual, verified: false,
            note: "No hook interface confirmed. Covered by process detection, or wrap the binary for exact working/idle state."),

        AgentDefinition(
            id: "aider", name: "Aider",
            mechanism: .manual, verified: false,
            note: "No hook interface. Covered by process detection while the process is busy."),

        AgentDefinition(
            id: "windsurf", name: "Windsurf / Codeium",
            mechanism: .manual, verified: false,
            note: "GUI editor with no hook interface. Covered by process detection."),

        AgentDefinition(
            id: "cursor", name: "Cursor",
            mechanism: .manual, verified: false,
            note: "GUI editor with no hook interface. Covered by process detection."),
    ]

    static func find(_ id: String) -> AgentDefinition? { all.first { $0.id == id } }

    /// The universal escape hatch for anything not listed: wrap the binary.
    static func wrapperSnippet(agent: String) -> String {
        """
        #!/bin/sh
        # Wrap any agent that has no hook system.
        export LUCID_SESSION_ID=$$
        ~/.lucid/lucid-notify \(agent) working "Running"
        trap '~/.lucid/lucid-notify \(agent) ended' EXIT
        exec <real-agent-binary> "$@"
        """
    }
}
