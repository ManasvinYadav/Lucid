#!/bin/bash
# Installs Lucid lifecycle hooks into a coding agent's own config.
#
# Merges into what is already there: hooks you have are kept, a timestamped .bak is
# written before any change, and running it twice changes nothing.
#
#   install-hooks.sh [agent] [preview|--apply|--uninstall]   agent defaults to claude-code
#   install-hooks.sh --list
#
# preview (the default) prints the change it would make and writes nothing at all.
set -euo pipefail

NOTIFY="$HOME/.lucid/lucid-notify"
AGENT="claude-code"
MODE="preview"
for arg in "$@"; do
  case "$arg" in
    --apply|--uninstall|--list|preview) MODE="$arg" ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) AGENT="$arg" ;;
  esac
done

# Without Apple's Command Line Tools, /usr/bin/python3 is only a stub that pops an
# install dialog. The app runs this with launchd's PATH, so that is the one it finds.
if [ "$(command -v python3)" = /usr/bin/python3 ] && ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
  echo "The hook installer needs python3, which comes with Apple's Command Line Tools." >&2
  echo "Install them with: xcode-select --install" >&2
  exit 1
fi

if [ "$MODE" = "--apply" ]; then
  # 0700 even if something else created it first: the socket and state live here.
  mkdir -p -m 700 "$HOME/.lucid"
  chmod 700 "$HOME/.lucid"
  src="$(dirname "$0")/lucid-notify"
  [ -f "$src" ] && install -m 0755 "$src" "$NOTIFY"
fi

exec python3 - "$AGENT" "$NOTIFY" "$MODE" <<'PY'
import difflib, json, os, re, shutil, stat, sys, tempfile, time
# A preview diff of a file that is not UTF-8 must print, not raise.
sys.stdout.reconfigure(errors="backslashreplace"); sys.stderr.reconfigure(errors="backslashreplace")

agent, notify, mode = sys.argv[1:4]
HOME = os.path.expanduser("~")
MARKERS = ("lucid-notify", "liddownai-notify")   # the second is the pre-rename name

class Refuse(Exception):
    pass

if not re.fullmatch(r"[A-Za-z0-9/._ -]+", notify):
    sys.exit(f"refusing: unexpected characters in {notify!r}")

# --- The command each hook runs --------------------------------------------------

def command(agent_id, status, detail, stdin, guard):
    n = f'"{notify}"'
    call = f"{n} {'--stdin ' if stdin else ''}{agent_id} {status}"
    if detail:
        call += f' "{detail}"'
    # Guarded, so a removed notifier exits 0 instead of 127: some agents show every
    # failing hook, and Copilot denies the tool call outright.
    return f"[ -x {n} ] && exec {call}; exit 0" if guard else call

def claude_handler(event, cmd, timeout):          # Claude Code, Codex, Droid
    return {"type": "command", "command": cmd, "timeout": timeout}

def gemini_handler(event, cmd, timeout):          # timeout in ms; name for /hooks toggling
    return {"name": f"lucid-{event}", "type": "command", "command": cmd, "timeout": timeout * 1000}

def cursor_handler(event, cmd, timeout):
    return {"command": cmd, "timeout": timeout}

def copilot_handler(event, cmd, timeout):
    return {"type": "command", "bash": cmd, "timeoutSec": timeout}

# --- Plugin agents: a whole file of Lucid's own -----------------------------------

OPENCODE_PLUGIN = r'''// Managed by Lucid (install-hooks.sh). Reports opencode session state to the Lucid
// menu bar app through ~/.lucid/lucid-notify. Remove with: install-hooks.sh opencode --uninstall
import { spawn } from "node:child_process"
import { homedir } from "node:os"
import { join } from "node:path"

const BIN = join(homedir(), ".lucid", "lucid-notify")

export const LucidPlugin = async () => {
  const parent = new Map() // subagent session -> its parent
  const last = new Map()   // session -> last status sent
  let queue = Promise.resolve() // one notifier at a time, in event order

  const root = (id) => {
    while (parent.has(id)) id = parent.get(id)
    return id
  }
  const send = (sid, status, detail = "") => {
    if (!sid || last.get(sid) === status) return
    last.set(sid, status)
    queue = queue.then(() => new Promise((done) => {
      const child = spawn(BIN, ["opencode", status, detail], {
        stdio: "ignore",
        detached: true, // the final "ended" must outlive opencode
        env: { ...process.env, LUCID_SESSION_ID: sid },
      })
      child.on("error", done)
      child.on("exit", done)
    })).catch(() => {}) // a spawn that throws must not stall every later event
  }

  return {
    event: async ({ event }) => {
      const p = event.properties ?? {}
      const sid = p.sessionID ?? p.info?.id
      switch (event.type) {
        case "session.created":
          if (p.info?.parentID) parent.set(sid, p.info.parentID)
          break
        case "session.status": // busy | retry | idle
          if (parent.has(sid)) break // a subagent: its parent is still busy
          if (p.status?.type === "idle") send(sid, "idle", "Waiting for prompt")
          else send(sid, "working", "Thinking")
          break
        case "permission.asked":
        case "permission.updated": // its name in opencode 1.0.x
          send(root(sid), "idle", "Waiting for approval")
          break
        case "question.asked":
          send(root(sid), "idle", "Waiting for input")
          break
        case "permission.replied":
        case "question.replied":
        case "question.rejected":
          send(root(sid), "working", "Thinking")
          break
        case "session.deleted":
          if (!p.info?.parentID) send(sid, "ended")
          break
      }
    },
    dispose: async () => {
      for (const [sid, status] of last) if (status !== "ended") send(sid, "ended")
      await queue
    },
  }
}
'''

AMP_PLUGIN = r'''// Managed by Lucid (install-hooks.sh). Reports Amp thread state to the Lucid menu bar
// app through ~/.lucid/lucid-notify. Remove with: install-hooks.sh amp --uninstall
import type { PluginAPI } from '@ampcode/plugin'
import { homedir } from 'node:os'

export const description = 'Tells the Lucid menu bar app whether Amp is working or waiting for you.'

const NOTIFY = `${homedir()}/.lucid/lucid-notify`
type Status = 'working' | 'idle' | 'ended'

export default function (amp: PluginAPI) {
  if (amp.system?.executor?.kind === 'remote') return // nothing local to keep awake

  const last = new Map<string, Status>()
  const running = new Set<string>()
  let queue: Promise<unknown> = Promise.resolve()

  const spawn = (thread: string, status: Status, detail: string) =>
    Bun.spawn([NOTIFY, 'amp', status, detail], {
      stdin: null, stdout: 'ignore', stderr: 'ignore',
      env: { ...process.env, LUCID_SESSION_ID: thread },
    }).exited

  // Serialized so events arrive in order; handlers never await it, so Amp is not delayed.
  // Only changes are sent: a spawn per tool result adds nothing the app does not know.
  const send = (thread: string, status: Status, detail: string) => {
    if (last.get(thread) === status) return
    last.set(thread, status)
    queue = queue.then(() => spawn(thread, status, detail)).catch(() => {})
  }

  amp.on('session.start', async (e, ctx) => {
    // Also fires when switching to a thread that is still running, and the set above is
    // empty after a plugin reload, so ask the thread itself where the API allows it.
    let state: unknown
    try { state = await (ctx as any)?.thread?.state?.get?.() } catch {}
    if (state === 'running' || running.has(e.thread.id)) return
    send(e.thread.id, 'idle', 'Waiting for prompt')
  })
  amp.on('agent.start', (e) => {
    running.add(e.thread.id)
    send(e.thread.id, 'working', 'Thinking')
    return {}
  })
  amp.on('tool.result', (e) => {
    running.add(e.thread.id)
    send(e.thread.id, 'working', 'Tool Running')
  })
  amp.on('agent.end', (e) => {
    running.delete(e.thread.id)
    send(e.thread.id, 'idle', 'Turn complete')
  })
  amp.onDispose(async () => {
    // What is already queued lands first, or a late "working" would revive the session.
    // Then the ends in parallel: dispose has a budget of a few seconds.
    await queue
    await Promise.all([...last].filter(([, s]) => s !== 'ended')
      .map(([t]) => spawn(t, 'ended', '').catch(() => {})))
  })
}
'''

# --- Agents ------------------------------------------------------------------------
#
# verified: event names and file format checked against an installed copy of the tool.
# Everything else follows the tool's own documentation and is labelled best-effort.
#
# layout "grouped": event -> [ {matcher?, hooks: [handler]} ]   (Claude Code's shape)
# layout "flat":    event -> [ handler ]
# wrap:             the key the event map sits under, or None if it is the whole file

WORKING, IDLE, ENDED = "working", "idle", "ended"
CLINE_VSCODE = "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"
SCRIPT_HEAD = "#!/bin/sh\n# Managed by Lucid (install-hooks.sh). Remove with: install-hooks.sh {agent} --uninstall\n"

AGENTS = {
    "claude-code": dict(
        name="Claude Code", verified=True, detect="~/.claude", path="~/.claude/settings.json",
        layout="grouped", wrap="hooks", handler=claude_handler, stdin=True, guard=True, timeout=5,
        events=[
            ("SessionStart", "startup|resume|clear", IDLE, "Waiting for prompt"),
            ("UserPromptSubmit", None, WORKING, "Thinking"),
            ("PreToolUse", None, WORKING, "Tool Running"),
            ("PostToolUse", None, WORKING, "Tool Running"),
            ("PostToolUseFailure", None, WORKING, "Tool Running"),
            ("SubagentStart", None, WORKING, "Subagent Running"),
            ("SubagentStop", None, WORKING, "Subagent Running"),
            # Only the types that mean the main session is waiting on you. The agent_*
            # types are background agents, and treating one as idle could release the
            # lock in the middle of a long tool call.
            ("Notification", "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog",
             IDLE, "Waiting for input"),
            ("Stop", None, IDLE, "Turn complete"),
            ("StopFailure", None, IDLE, "Turn failed"),
            ("SessionEnd", None, ENDED, ""),
        ]),
    "codex": dict(
        name="Codex CLI", verified=True, detect="~/.codex", path="~/.codex/hooks.json",
        layout="grouped", wrap="hooks", handler=claude_handler, stdin=True, guard=True, timeout=5,
        legacy_toml="~/.codex/config.toml",
        note="Codex skips new hooks until you trust them: run /hooks in Codex once.",
        # No SessionStart: Codex runs it lazily inside the first turn, where an idle
        # would land after the turn had started.
        events=[
            ("UserPromptSubmit", None, WORKING, "Thinking"),
            ("PreToolUse", None, WORKING, "Tool Running"),
            ("PostToolUse", None, WORKING, "Tool Running"),
            ("SubagentStart", None, WORKING, "Subagent Running"),
            ("SubagentStop", None, WORKING, "Subagent Running"),
            ("PermissionRequest", None, IDLE, "Waiting for approval"),
            ("Stop", None, IDLE, "Turn complete"),
            ("Interrupt", None, IDLE, "Interrupted", 3),     # Codex caps these at 3 s
            ("SessionEnd", None, ENDED, "", 3),
        ]),
    "gemini": dict(
        name="Gemini CLI", verified=True, detect="~/.gemini", path="~/.gemini/settings.json",
        # No --stdin: Gemini puts the session id in GEMINI_SESSION_ID, which lucid-notify reads.
        layout="grouped", wrap="hooks", handler=gemini_handler, stdin=False, guard=True, timeout=5,
        note="Gemini runs hooks only in trusted folders, and only in sessions started after this.",
        events=[
            ("SessionStart", None, IDLE, "Waiting for prompt"),
            ("BeforeAgent", None, WORKING, "Thinking"),
            ("BeforeTool", None, WORKING, "Tool Running"),
            ("AfterTool", None, WORKING, "Tool Running"),
            ("Notification", None, IDLE, "Waiting for approval"),
            ("AfterAgent", None, IDLE, "Turn complete"),
            ("SessionEnd", None, ENDED, ""),
        ]),
    "cursor": dict(
        name="Cursor", verified=False, detect="~/.cursor", path="~/.cursor/hooks.json",
        # Unguarded: Cursor can append the payload as a heredoc, which binds to the last
        # command on the line, so this has to be a single simple command.
        layout="flat", wrap="hooks", version=1, handler=cursor_handler, stdin=True, guard=False,
        timeout=5,
        events=[
            ("sessionStart", None, IDLE, "Waiting for prompt"),
            ("beforeSubmitPrompt", None, WORKING, "Thinking"),
            ("preToolUse", None, WORKING, "Tool Running"),
            ("postToolUse", None, WORKING, "Tool Running"),
            ("postToolUseFailure", None, WORKING, "Tool Running"),
            ("subagentStart", None, WORKING, "Subagent Running"),
            ("subagentStop", None, WORKING, "Subagent Running"),
            ("stop", None, IDLE, "Turn complete"),
            ("sessionEnd", None, ENDED, ""),
        ]),
    "copilot": dict(
        name="Copilot CLI", verified=False, detect="~/.copilot", path="~/.copilot/hooks/lucid.json",
        own=True, layout="flat", wrap="hooks", version=1, handler=copilot_handler, stdin=True,
        guard=True, timeout=5,
        events=[
            ("sessionStart", None, IDLE, "Waiting for prompt"),
            ("userPromptSubmitted", None, WORKING, "Thinking"),
            ("preToolUse", None, WORKING, "Tool Running"),
            ("postToolUse", None, WORKING, "Tool Running"),
            ("postToolUseFailure", None, WORKING, "Tool Running"),
            ("subagentStart", None, WORKING, "Subagent Running"),
            ("subagentStop", None, WORKING, "Subagent Running"),
            ("agentStop", None, IDLE, "Turn complete"),
            ("notification", "permission_prompt|elicitation_dialog", IDLE, "Waiting for input"),
            ("sessionEnd", None, ENDED, ""),
        ]),
    "droid": dict(
        name="Factory Droid", verified=False, detect="~/.factory", path="~/.factory/hooks.json",
        layout="grouped", wrap=None, handler=claude_handler, stdin=True, guard=True, timeout=5,
        events=[
            ("SessionStart", None, IDLE, "Waiting for prompt"),
            ("UserPromptSubmit", None, WORKING, "Thinking"),
            ("PreToolUse", None, WORKING, "Tool Running"),
            ("PostToolUse", None, WORKING, "Tool Running"),
            ("SubagentStop", None, WORKING, "Subagent Running"),
            ("Notification", None, IDLE, "Waiting for input"),
            ("Stop", None, IDLE, "Turn complete"),
            ("SessionEnd", None, ENDED, ""),
        ]),
    "qwen": dict(
        name="Qwen Code", verified=False, detect="~/.qwen", path="~/.qwen/settings.json",
        layout="grouped", wrap="hooks", handler=claude_handler, stdin=True, guard=True, timeout=5,
        note="Qwen Code reads hooks at session start: restart open sessions.",
        events=[
            ("SessionStart", "startup|resume|clear", IDLE, "Waiting for prompt"),
            ("UserPromptSubmit", None, WORKING, "Thinking"),
            ("PreToolUse", None, WORKING, "Tool Running"),
            ("PostToolUse", None, WORKING, "Tool Running"),
            ("PostToolUseFailure", None, WORKING, "Tool Running"),
            ("SubagentStart", None, WORKING, "Subagent Running"),
            ("SubagentStop", None, WORKING, "Subagent Running"),
            # idle_prompt fires whenever the TUI goes idle, which also covers an Esc and
            # the API errors that end a turn without a Stop.
            ("Notification", "permission_prompt|idle_prompt", IDLE, "Waiting for input"),
            ("Stop", None, IDLE, "Turn complete"),
            ("SessionEnd", None, ENDED, ""),
        ]),
    "devin": dict(
        name="Devin", verified=False, detect="~/.config/devin", path="~/.config/devin/config.json",
        # Unguarded: were the command ever split into argv rather than run by a shell, the
        # guard's /bin/[ would exit 2, which Devin treats as "block the tool call". A missing
        # notifier exits 127, which Devin only logs. Only Devin's own event names: one it
        # does not know reportedly makes it drop the file's whole hooks block.
        layout="grouped", wrap="hooks", handler=claude_handler, stdin=True, guard=False, timeout=5,
        note="Devin CLI, and Devin Local in Devin Desktop. Restart open sessions.",
        events=[
            ("SessionStart", None, IDLE, "Waiting for prompt"),
            ("UserPromptSubmit", None, WORKING, "Thinking"),
            ("PreToolUse", None, WORKING, "Tool Running"),
            ("PostToolUse", None, WORKING, "Tool Running"),
            ("PermissionRequest", None, IDLE, "Waiting for approval"),
            ("Stop", None, IDLE, "Turn complete"),
            ("SessionEnd", None, ENDED, ""),
        ]),
    "cline": dict(
        # One executable per hook, named after it. The VS Code extension reads only this
        # directory; the CLI reads it too, so a second copy in ~/.cline/hooks would make
        # it fire twice. Cline has no session-end event: the app sees the process exit.
        name="Cline", verified=False, detect=["~/.cline", CLINE_VSCODE],
        path="~/Documents/Cline/Hooks/TaskStart", dir="~/Documents/Cline/Hooks",
        stdin=True, guard=True,
        note="Cline has no hook for waiting on approval, so a task reads as working while one is open.",
        scripts=[
            ("TaskStart", WORKING, "Thinking"),
            ("TaskResume", WORKING, "Thinking"),        # the CLI's TaskStart on resume
            ("UserPromptSubmit", WORKING, "Thinking"),
            ("PreToolUse", WORKING, "Tool Running"),
            ("PostToolUse", WORKING, "Tool Running"),
            ("TaskComplete", IDLE, "Turn complete"),
            ("TaskCancel", IDLE, "Cancelled"),
            ("TaskError", IDLE, "Turn failed"),        # CLI only
        ]),
    "opencode": dict(
        name="opencode", verified=False, detect="~/.config/opencode",
        path="~/.config/opencode/plugins/lucid.js", plugin=OPENCODE_PLUGIN,
        legacy_json="~/.config/opencode/config.json",
        note="opencode loads plugins at startup: restart it."),
    "amp": dict(
        name="Amp", verified=False, detect="~/.config/amp", path="~/.config/amp/plugins/lucid.ts",
        plugin=AMP_PLUGIN, note="Reload Amp's plugins (plugins: reload) or restart it."),
}

# Agents Lucid installs no hooks for: a wrapper script is the only precise option.
MANUAL = {
    "aider": ("Aider", "has no hook interface."),
    # Cascade's hooks have no event for a cancelled or failed turn, so a session could stay
    # "working" and hold the Mac awake; and Devin Desktop 3.9.19 removed Cascade anyway.
    "windsurf": ("Windsurf", "gets no hooks from Lucid: Cascade was removed in Devin Desktop 3.9.19 "
                             "(for Devin Local, run: install-hooks.sh devin)."),
}

def wrapper(agent_id):
    return f'''#!/bin/sh
# Reports "working" for as long as the agent process runs. It cannot tell working
# from waiting for input, so use it only for an agent that has no hooks.
export LUCID_SESSION_ID="wrap-$$" LUCID_PID=$$
"{notify}" {agent_id} working "Running"
<real-agent-binary> "$@"
rc=$?
"{notify}" {agent_id} ended
exit $rc
'''

# --- File handling -------------------------------------------------------------------

def expand(p):
    return os.path.expanduser(p)

def strip_jsonc(t):
    """Comments and trailing commas out, strings untouched. Only used to tell a JSONC
    file from a broken one: writing it back would lose the comments."""
    out, i, n, in_str = [], 0, len(t), False
    while i < n:
        c = t[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(t[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1; continue
        if c == '"':
            in_str = True
        elif t.startswith("//", i):
            j = t.find("\n", i); i = n if j < 0 else j; continue
        elif t.startswith("/*", i):
            j = t.find("*/", i + 2); i = n if j < 0 else j + 2; continue
        out.append(c); i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))

def read_text(path):
    # surrogateescape: a file that is not UTF-8 (a compiled Cline hook) reads as foreign
    # text instead of raising, and anything written back keeps its original bytes.
    try:
        with open(path, encoding="utf-8", errors="surrogateescape") as f:
            return f.read()
    except FileNotFoundError:
        return None

def load_json(path):
    text = read_text(path)
    if text is None or not text.strip():
        return text, {}
    # JSON must be UTF-8. Bytes that are not come back from read_text as lone surrogates;
    # written back, they gave the agent a file it misreads and the app one it cannot read.
    if re.search("[\udc80-\udcff]", text):
        raise Refuse(f"{path} is not UTF-8 text, so Lucid will not rewrite it.")
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        try:
            json.loads(strip_jsonc(text))
        except json.JSONDecodeError:
            raise Refuse(f"{path} is not valid JSON ({e}). Fix it, then run this again.")
        raise Refuse(f"{path} has comments, which rewriting it would lose. "
                     f"Add the hooks by hand (run preview for the entries), or remove the comments.")
    if not isinstance(data, dict):
        raise Refuse(f"{path} is not a JSON object.")
    return text, data

def render(data):
    # A lone surrogate can only come from a \uXXXX escape in a string: write it back as
    # that escape, not as a raw byte that is not UTF-8.
    return re.sub("[\ud800-\udfff]", lambda m: f"\\u{ord(m[0]):04x}",
                  json.dumps(data, indent=2, ensure_ascii=False)) + "\n"

def umask():
    m = os.umask(0); os.umask(m); return m

def write_file(path, text, backup=True, mode=None):
    real = os.path.realpath(path)   # a symlinked config stays a symlink
    os.makedirs(os.path.dirname(real), exist_ok=True)
    if os.path.exists(real):
        mode = mode or stat.S_IMODE(os.stat(real).st_mode)
        if backup:
            back_up(real)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real), prefix=f".{os.path.basename(real)}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.write(text)
        os.chmod(tmp, mode if mode is not None else 0o666 & ~umask())
        os.replace(tmp, real)       # atomic
    except BaseException:
        os.unlink(tmp)
        raise

def delete_file(path, backup=True):
    if backup and os.path.isfile(path):
        back_up(path)
    os.remove(path)

def back_up(path):
    # Never over an earlier backup: an --apply and an --uninstall in the same second
    # left only the second one, and lost the file as it was before Lucid touched it.
    base = f"{os.path.realpath(path)}.bak.{int(time.time())}"
    bak, n = base, 1
    while os.path.exists(bak):
        bak, n = f"{base}.{n}", n + 1
    shutil.copy2(path, bak)
    print(f"  backed up -> {bak}")

# --- Merging -------------------------------------------------------------------------

def is_ours(handler):
    if not isinstance(handler, dict):
        return False
    text = " ".join(str(handler.get(k, "")) for k in ("command", "bash", "powershell"))
    return any(m in text for m in MARKERS)

def strip_ours(entries, layout):
    """The entries with every Lucid handler removed, and groups left empty dropped."""
    if not isinstance(entries, list):
        return entries
    out = []
    for e in entries:
        if layout == "flat":
            if not is_ours(e):
                out.append(e)
            continue
        hooks = e.get("hooks") if isinstance(e, dict) else None
        if not isinstance(hooks, list):
            out.append(e); continue
        kept = [h for h in hooks if not is_ours(h)]
        if len(kept) == len(hooks):
            out.append(e)
        elif kept:
            out.append({**e, "hooks": kept})
    return out

def wanted_entries(spec):
    out = {}
    for ev in spec["events"]:
        event, matcher, status, detail = ev[:4]
        timeout = ev[4] if len(ev) > 4 else spec["timeout"]
        cmd = command(agent, status, detail, spec["stdin"], spec["guard"])
        handler = spec["handler"](event, cmd, timeout)
        if spec["layout"] == "flat":
            entry = {**handler, **({"matcher": matcher} if matcher else {})}
        else:
            entry = {**({"matcher": matcher} if matcher else {}), "hooks": [handler]}
        out[event] = entry
    return out

def merge(event_map, spec, install):
    """New event map. An event whose only Lucid entry is already exactly right is left
    alone, so a reinstall moves nothing: Codex keys its trust records by position."""
    wanted = wanted_entries(spec) if install else {}
    result = {}
    for event, entries in event_map.items():
        cleaned = strip_ours(entries, spec["layout"])
        if event in wanted:
            if not isinstance(entries, list):
                raise Refuse(f'"{event}" is not a list; fix it by hand first.')
            want = wanted.pop(event)
            ours = [e for e in entries if e not in cleaned]
            if ours == [want] and cleaned == [e for e in entries if e != want]:
                result[event] = entries
                continue
            cleaned = cleaned + [want]
        # Dropped only when removing Lucid's entries emptied it, never a list that was
        # already empty: that would rewrite a file with nothing of ours in it.
        if cleaned != [] or entries == []:
            result[event] = cleaned
    for event, want in wanted.items():
        result[event] = [want]
    return result

def count_ours(event_map, layout):
    n = 0
    for entries in (event_map or {}).values():
        if not isinstance(entries, list):
            continue
        for e in entries:
            if layout == "flat":
                n += is_ours(e)
            elif isinstance(e, dict) and isinstance(e.get("hooks"), list):
                n += sum(is_ours(h) for h in e["hooks"])
    return n

# --- Plans: every file an action would touch, and its new contents -------------------

# The line command() writes for a script, whatever the notifier path, status or detail.
LUCID_LINE = re.compile(r'\[ -x "[^"]*-notify" \] && exec "[^"]*(lucid|liddownai)-notify"'
                        r'( --stdin)? [a-z-]+ (working|idle|ended)( "[^"$`\\]*")?; exit 0')

def lucid_script(text):
    """Lucid's own hook script, from this version or an older one: the header, then the
    one line Lucid writes. Anything else, on a line of its own or on that line, is the
    user's, and never overwritten or deleted."""
    head = SCRIPT_HEAD.format(agent=agent)
    rest = text[len(head):].strip().splitlines() if text.startswith(head) else []
    return len(rest) == 1 and LUCID_LINE.fullmatch(rest[0]) is not None

def plan_config(spec, install):
    """[(path, old_text, new_text or None to delete)]"""
    path = expand(spec["path"])

    if "scripts" in spec:
        plans = []
        for event, status, detail in spec["scripts"]:
            p = os.path.join(expand(spec["dir"]), event)
            old = read_text(p)
            if old is not None and not lucid_script(old):
                # No line to paste into it: the hook's payload, and with it the task id the
                # other scripts report under, is the user's script's to read, so a session
                # started from there would never see its idle and stay working.
                what = f"{p} is a hook of your own, or Lucid's with lines added"
                if install:
                    raise Refuse(f"{what}. Cline runs one script per hook, so Lucid would "
                                 f"have to replace it, and will not. Move it aside and run this again.")
                if any(m in old for m in MARKERS):
                    raise Refuse(f"{what}, and it calls lucid-notify. "
                                 f"Remove that line from it, then run this again.")
                continue
            new = (SCRIPT_HEAD.format(agent=agent)
                   + command(agent, status, detail, spec["stdin"], spec["guard"]) + "\n"
                   if install else None)
            if old != new or (new and not os.access(p, os.X_OK)):
                plans.append((p, old, new))
        return plans

    if "plugin" in spec:
        old = read_text(path)
        new = spec["plugin"] if install else None
        return [] if old == new else [(path, old, new)]

    if spec.get("own"):
        old = read_text(path)
        new = render({"version": spec["version"],
                      "hooks": merge({}, spec, True)}) if install else None
        return [] if old == new or (old is None and new is None) else [(path, old, new)]

    # Droid reads the "hooks" key of settings.json only while hooks.json does not exist,
    # so creating hooks.json next to one that holds hooks would hide them.
    wrap = spec["wrap"]
    if agent == "droid" and not os.path.exists(path):
        settings = expand("~/.factory/settings.json")
        if load_json(settings)[1].get("hooks"):
            path, wrap = settings, "hooks"

    old, data = load_json(path)
    if wrap:
        current = data.get(wrap) or {}
        if not isinstance(current, dict):
            raise Refuse(f'{path}: "{wrap}" is not an object.')
    else:
        current = data
    merged = merge(current, spec, install)
    if merged == current:
        return []
    # An emptied file that is nothing but the event map goes: an empty Droid hooks.json
    # would still hide any hooks in settings.json.
    if not wrap and not merged:
        return [(path, old, None)]
    new = dict(data)
    if wrap:
        # Cursor rejects the whole file when "hooks" is missing, so a versioned file keeps
        # an empty one.
        if merged or spec.get("version"):
            new[wrap] = merged
        else:
            new.pop(wrap, None)
    else:
        new = merged
    if spec.get("version") and "version" not in new:
        new = {"version": spec["version"], **new}
    return [(path, old, render(new))]

TOML_HEADER = re.compile(r"\s*\[\[?[^\[\]]+\]\]?\s*(#.*)?$")

def strip_legacy_block(block):
    """Lucid 0.10's marked block minus Lucid's own lines. Codex writes its hook trust
    records ([hooks.state."..."]) where its TOML editor places them, which can be inside
    this block, so every table that is not Lucid's stays."""
    def ours(line):
        return (re.match(r"\s*(pre_turn|post_turn)\s*=", line)
                and any(m in line for m in MARKERS))
    tables, cur = [], []
    for line in block.split("\n"):
        if TOML_HEADER.match(line) and cur:
            tables.append(cur); cur = []
        cur.append(line)
    tables.append(cur)
    kept = []
    for t in tables:
        t = [l for l in t if not ours(l)]
        # [hooks] goes only once nothing but Lucid's keys were in it.
        if t and t[0].strip() == "[hooks]" and not any(
                l.strip() and not l.lstrip().startswith("#") for l in t[1:]):
            continue
        kept += t
    return "\n".join(kept).strip("\n")

def plan_legacy(spec):
    """Leftovers from Lucid 0.10, which wrote hooks these tools never read."""
    plans = []
    toml = spec.get("legacy_toml")
    if toml:
        path = expand(toml)
        text = read_text(path)
        begin, end = "# >>> lucid >>>", "# <<< lucid <<<"
        if text and begin in text and end in text.split(begin, 1)[1]:
            pre, rest = text.split(begin, 1)
            block, post = rest.split(end, 1)
            parts = (pre.rstrip("\n"), strip_legacy_block(block), post.strip("\n"))
            new = "\n\n".join(p for p in parts if p.strip())
            plans.append((path, text, new + "\n" if new else ""))
    js = spec.get("legacy_json")
    if js:
        path = expand(js)
        # Parsed only if Lucid wrote to it: a config.json of the user's own, comments and
        # all, must not block the install.
        if any(m in (read_text(path) or "") for m in MARKERS):
            old, data = load_json(path)
            hooks = data.get("hooks")
            if isinstance(hooks, dict) and count_ours(hooks, "grouped"):
                cleaned = {k: v for k, v in ((k, strip_ours(v, "grouped")) for k, v in hooks.items()) if v}
                new = dict(data)
                if cleaned:
                    new["hooks"] = cleaned
                else:
                    new.pop("hooks")
                # Lucid created this file; once its entry is gone, nothing else is left.
                plans.append((path, old, None if set(new) <= {"$schema"} else render(new)))
    return plans

# --- Main ------------------------------------------------------------------------------

def show_list():
    print("Supported agents:\n")
    for k, s in AGENTS.items():
        detected = any(os.path.isdir(expand(d)) for d in
                       ([s["detect"]] if isinstance(s["detect"], str) else s["detect"]))
        # Droid's hooks can live in settings.json instead; see plan_config. Only read once
        # detected, as the app does: Cline's live in ~/Documents, behind a privacy prompt.
        paths = [s["path"]] + (["~/.factory/settings.json"] if k == "droid" else [])
        try:
            marked = detected and any(m in (read_text(expand(p)) or "") for p in paths for m in MARKERS)
        except OSError:
            marked = None
        state = ("unreadable" if marked is None else "installed" if marked
                 else "detected" if detected else "not found")
        tag = "verified" if s["verified"] else "best-effort"
        print(f"  {k:<12} {s['name']:<14} {tag:<12} {state:<10} {s['path']}")
    for k, (name, _) in MANUAL.items():
        print(f"  {k:<12} {name:<14} {'manual':<12} {'':<10} no hooks: wrap the binary ({k} preview)")

def main():
    if mode == "--list":
        show_list(); return 0
    if agent in MANUAL:
        name, why = MANUAL[agent]
        print(f"{name} {why} Wrap the binary instead:\n")
        print(wrapper(agent))
        print("Or leave it to the process fallback in Settings > Agents.")
        return 0
    spec = AGENTS.get(agent)
    if spec is None:
        print(f"unknown agent '{agent}'. Try --list.", file=sys.stderr)
        return 2

    install = mode != "--uninstall"
    try:
        plans = plan_legacy(spec) + plan_config(spec, install)
    except (Refuse, OSError) as e:
        print(f"{spec['name']}: {e}", file=sys.stderr)
        # What the refusal says to add by hand.
        if mode == "preview" and "events" in spec:
            where = f' under "{spec["wrap"]}"' if spec["wrap"] else ""
            print(f"\nThe entries to add{where}:\n")
            print(render(merge({}, spec, True)), end="")
        return 1

    tag = "verified" if spec["verified"] else "best-effort: follows the tool's documentation"
    if mode == "preview":
        print(f"PREVIEW ONLY, nothing written. {spec['name']} ({tag})\n")
        if not plans:
            print("Already up to date." if install else "Nothing to remove.")
        for path, old, new in plans:
            diff = difflib.unified_diff((old or "").splitlines(True), (new or "").splitlines(True),
                                        fromfile=path, tofile=path + (" (deleted)" if new is None else ""))
            sys.stdout.writelines(diff)
            print()
        return 0

    for path, old, new in plans:
        script = "scripts" in spec
        own = script or (("plugin" in spec or spec.get("own")) and path == expand(spec["path"]))
        try:
            if new is None:
                delete_file(path, backup=not own)
                print(f"  removed {path}")
            else:
                write_file(path, new, backup=not own, mode=0o755 if script else None)
                print(f"  wrote {path}")
        except OSError as e:
            print(f"{spec['name']}: {e}", file=sys.stderr)
            return 1
    verb = "Installed" if install else "Removed"
    if not plans:
        print(f"{spec['name']}: already up to date." if install else f"{spec['name']}: nothing to remove.")
    else:
        print(f"{verb} Lucid hooks for {spec['name']} ({tag}).")
    if install and spec.get("note"):
        print(spec["note"])
    return 0

sys.exit(main())
PY
