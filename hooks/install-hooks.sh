#!/bin/bash
# Installs Lucid lifecycle hooks for a coding agent.
#
# Merges into the agent's existing config — it never overwrites hooks you already have,
# writes a timestamped .bak first, and is idempotent.
#
#   ./install-hooks.sh                        preview for claude-code
#   ./install-hooks.sh claude-code --apply
#   ./install-hooks.sh codex --apply
#   ./install-hooks.sh claude-code --uninstall
#   ./install-hooks.sh --list                 show supported agents
set -euo pipefail

NOTIFY="$HOME/.lucid/lucid-notify"
AGENT="claude-code"
MODE="preview"

for arg in "$@"; do
  case "$arg" in
    --apply|--uninstall|preview) MODE="$arg" ;;
    --list) AGENT="--list" ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) AGENT="$arg" ;;
  esac
done

mkdir -p "$HOME/.lucid"
if [ -f "$(dirname "$0")/lucid-notify" ]; then
  install -m 0755 "$(dirname "$0")/lucid-notify" "$NOTIFY"
fi

python3 - "$AGENT" "$NOTIFY" "$MODE" <<'PY'
import json, os, shutil, sys, time

agent, notify, mode = sys.argv[1], sys.argv[2], sys.argv[3]

# Only claude-code's event names are verified against a real install. The rest are
# best-effort and are labelled as such rather than presented as known-good.
AGENTS = {
    "claude-code": {
        "name": "Claude Code", "format": "json", "verified": True,
        "path": "~/.claude/settings.json",
        "events": {
            "UserPromptSubmit":   ("working", "Thinking"),
            "PreToolUse":         ("working", "Tool Running"),
            "PostToolUse":        ("working", "Tool Running"),
            "PostToolUseFailure": ("working", "Tool Running"),
            "SubagentStart":      ("working", "Subagent Running"),
            "SubagentStop":       ("working", "Subagent Running"),
            "Notification":       ("idle",    "Waiting for prompt"),
            "Stop":               ("idle",    "Turn complete"),
            "SessionEnd":         ("ended",   ""),
        },
    },
    "codex": {
        "name": "Codex CLI", "format": "toml", "verified": False,
        "path": "~/.codex/config.toml",
        "events": {
            "pre_turn":  ("working", "Turn"),
            "post_turn": ("idle",    "Waiting for prompt"),
        },
    },
    "opencode": {
        "name": "opencode", "format": "json", "verified": False,
        "path": "~/.config/opencode/config.json",
        "events": {
            "onSessionStart": ("working", "Turn"),
            "onSessionIdle":  ("idle",    "Waiting for prompt"),
            "onSessionEnd":   ("ended",   ""),
        },
    },
}
MANUAL = {"gemini": "Gemini CLI", "copilot": "Copilot CLI"}
MARKER = "lucid-notify"

if agent == "--list":
    print("Supported agents:\n")
    for k, v in AGENTS.items():
        print(f"  {k:<14} {v['name']:<16} {'verified' if v['verified'] else 'best-effort'}  {v['path']}")
    for k, v in MANUAL.items():
        print(f"  {k:<14} {v:<16} manual — use the shell wrapper (see README)")
    sys.exit(0)

if agent in MANUAL:
    print(f"{MANUAL[agent]} has no confirmed hook interface.\n")
    print("Wrap the binary instead:\n")
    print(f"""  #!/bin/sh
  export LUCID_SESSION_ID=$$
  {notify} {agent} working "Running"
  trap '{notify} {agent} ended' EXIT
  exec <real-agent-binary> "$@"
""")
    print("Or leave it to the process fallback in Settings > Agents.")
    sys.exit(0)

if agent not in AGENTS:
    print(f"unknown agent '{agent}'. Try --list.", file=sys.stderr)
    sys.exit(2)

spec = AGENTS[agent]
path = os.path.expanduser(spec["path"])

if not spec["verified"] and mode == "--apply":
    print(f"NOTE: {spec['name']} event names are a best-effort mapping. "
          f"Confirm them against the installed version after installing.\n")

def backup_and_write(text):
    if os.path.exists(path):
        bak = f"{path}.bak.{int(time.time())}"
        shutil.copy2(path, bak)
        print(f"backed up -> {bak}")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)          # atomic

added = removed = 0

if spec["format"] == "json":
    data = {}
    if os.path.exists(path):
        with open(path) as f:
            data = json.load(f)
    hooks = data.setdefault("hooks", {})
    for event, (status, detail) in spec["events"].items():
        groups = hooks.setdefault(event, [])
        before = len(groups)
        groups[:] = [g for g in groups
                     if not any(MARKER in h.get("command", "") for h in g.get("hooks", []))]
        removed += before - len(groups)
        if mode != "--uninstall":
            cmd = f'"{notify}" {agent} {status} "{detail}"'
            groups.append({"hooks": [{"type": "command", "command": cmd}]})
            added += 1
        if not groups:
            del hooks[event]
    if not hooks:
        data.pop("hooks", None)
    rendered = json.dumps(data, indent=2) + "\n"

else:  # toml — line-oriented, so we manage a clearly delimited block
    BEGIN, END = "# >>> lucid >>>", "# <<< lucid <<<"
    existing = ""
    if os.path.exists(path):
        with open(path) as f:
            existing = f.read()
    if BEGIN in existing and END in existing:
        pre = existing.split(BEGIN)[0]
        post = existing.split(END, 1)[1]
        existing = pre.rstrip() + post
        removed += 1
    if mode == "--uninstall":
        rendered = existing.rstrip() + "\n"
    else:
        lines = [BEGIN, "[hooks]"]
        for event, (status, detail) in spec["events"].items():
            lines.append(f"{event} = '{notify} {agent} {status} \"{detail}\"'")
            added += 1
        lines.append(END)
        rendered = existing.rstrip() + "\n\n" + "\n".join(lines) + "\n"

if mode in ("--apply", "--uninstall"):
    backup_and_write(rendered)
    verb = "removed" if mode == "--uninstall" else "installed"
    print(f"{verb} for {spec['name']}: {removed} old cleared, {added} added -> {path}")
else:
    tag = "verified" if spec["verified"] else "BEST-EFFORT, unverified"
    print(f"PREVIEW ONLY — nothing written. Target: {path} ({tag})")
    print(f"Would add {added if mode!='preview' else len(spec['events'])} entries, "
          f"clearing {removed} existing Lucid ones.\n")
    for event, (status, _) in spec["events"].items():
        print(f"  {event:<20} -> {status}")
PY
