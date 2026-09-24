import Foundation

/// One agent Lucid knows how to wire up. The installer (hooks/install-hooks.sh) holds the
/// event mappings; this is only what the app needs to show status and offer buttons.
struct AgentDefinition: Identifiable {
    let id: String              // wire value, e.g. "claude-code"
    let name: String
    /// Any of these present means the agent is installed. Empty for agents with no hooks.
    let detectDirs: [String]
    /// Files the installer writes, first one shown. Empty = wrapper only.
    let paths: [String]
    /// Files older Lucid versions wrote, which the installer now cleans up.
    let legacyPaths: [String]
    /// True only where the event names and file format were checked against a real
    /// install. Everything else is a best-effort mapping the user should confirm.
    let verified: Bool
    let note: String

    init(_ id: String, _ name: String, detect: [String] = [], paths: [String] = [],
         legacy: [String] = [], verified: Bool = false, note: String) {
        self.id = id; self.name = name; detectDirs = detect; self.paths = paths
        legacyPaths = legacy; self.verified = verified; self.note = note
    }

    var isManual: Bool { paths.isEmpty }
    var configPath: String? { paths.first.map(Self.expand) }

    var detected: Bool {
        detectDirs.contains { FileManager.default.fileExists(atPath: Self.expand($0)) }
    }

    /// Current hooks are in place. Only looked for once the agent is detected: Cline's
    /// live in ~/Documents, and reading there makes macOS ask for Documents access.
    var installed: Bool { detected && paths.contains(where: Self.hasMarker) }

    /// Only an older Lucid's config is there: the agent reports nothing until reinstalled.
    var outdated: Bool { !installed && legacyPaths.contains(where: Self.hasMarker) }

    private static func expand(_ p: String) -> String { NSString(string: p).expandingTildeInPath }

    private static func hasMarker(_ p: String) -> Bool {
        guard let s = try? String(contentsOfFile: expand(p), encoding: .utf8) else { return false }
        return s.contains("lucid-notify") || s.contains("liddownai-notify")
    }
}

enum AgentRegistry {
    /// Ordered by how much confidence we have in the mapping.
    static let all: [AgentDefinition] = [
        AgentDefinition("claude-code", "Claude Code", detect: ["~/.claude"],
            paths: ["~/.claude/settings.json"], verified: true,
            note: "Notification fires when Claude Code is waiting for input, which distinguishes working from idle."),

        AgentDefinition("codex", "Codex CLI", detect: ["~/.codex"],
            paths: ["~/.codex/hooks.json"], legacy: ["~/.codex/config.toml"], verified: true,
            note: "Codex skips new hooks until you trust them: run /hooks in Codex once after installing."),

        AgentDefinition("gemini", "Gemini CLI", detect: ["~/.gemini"],
            paths: ["~/.gemini/settings.json"], verified: true,
            note: "Gemini runs hooks only in trusted folders, and only in sessions started after installing."),

        AgentDefinition("cursor", "Cursor", detect: ["~/.cursor"],
            paths: ["~/.cursor/hooks.json"],
            note: "The Cursor agent and cursor-agent CLI. Cursor has no hook for waiting on approval, so a chat reads as working while an approval prompt is open."),

        AgentDefinition("copilot", "Copilot CLI", detect: ["~/.copilot"],
            paths: ["~/.copilot/hooks/lucid.json"],
            note: "A separate hooks file Lucid owns; your own Copilot hooks are not touched."),

        AgentDefinition("droid", "Factory Droid", detect: ["~/.factory"],
            paths: ["~/.factory/hooks.json", "~/.factory/settings.json"],
            note: "Written to hooks.json, or to settings.json if that is where your Droid hooks already live."),

        AgentDefinition("qwen", "Qwen Code", detect: ["~/.qwen"],
            paths: ["~/.qwen/settings.json"],
            note: "Qwen Code reads hooks when a session starts, so restart open sessions after installing."),

        AgentDefinition("devin", "Devin", detect: ["~/.config/devin"],
            paths: ["~/.config/devin/config.json"],
            note: "Devin CLI, and Devin Local in Devin Desktop. Restart open sessions after installing."),

        AgentDefinition("cline", "Cline", detect: ["~/.cline", clineVSCode],
            paths: clineHooks.map { "~/Documents/Cline/Hooks/\($0)" },
            note: "The VS Code extension and the CLI. Cline keeps hooks in ~/Documents, so macOS asks once for Documents access. It has no hook for waiting on approval, so a task reads as working while one is open."),

        AgentDefinition("opencode", "opencode", detect: ["~/.config/opencode"],
            paths: ["~/.config/opencode/plugins/lucid.js"],
            legacy: ["~/.config/opencode/config.json"],
            note: "A plugin rather than hooks. opencode loads plugins at startup, so restart it after installing."),

        AgentDefinition("amp", "Amp", detect: ["~/.config/amp"],
            paths: ["~/.config/amp/plugins/lucid.ts"],
            note: "A plugin rather than hooks. Reload Amp's plugins, or restart it, after installing."),

        AgentDefinition("aider", "Aider",
            note: "No hook interface. Wrap the binary, or leave it to process detection."),

        AgentDefinition("windsurf", "Windsurf",
            note: "Cascade was removed in Devin Desktop 3.9.19; install the Devin hooks for Devin Local. For Cascade, leave it to process detection."),
    ]

    private static let clineVSCode =
        "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"
    /// Same list as the installer's.
    private static let clineHooks = ["TaskStart", "TaskResume", "UserPromptSubmit", "PreToolUse",
                                     "PostToolUse", "TaskComplete", "TaskCancel", "TaskError"]

    static func find(_ id: String) -> AgentDefinition? { all.first { $0.id == id } }

    /// The escape hatch for anything with no hooks: wrap the binary. Same text the
    /// installer prints. Not exec: the ended event has to run after the agent exits.
    static func wrapperSnippet(agent: String) -> String {
        """
        #!/bin/sh
        # Reports "working" for as long as the agent process runs. It cannot tell working
        # from waiting for input, so use it only for an agent that has no hooks.
        export LUCID_SESSION_ID="wrap-$$" LUCID_PID=$$
        "$HOME/.lucid/lucid-notify" \(agent) working "Running"
        <real-agent-binary> "$@"
        rc=$?
        "$HOME/.lucid/lucid-notify" \(agent) ended
        exit $rc
        """
    }
}
