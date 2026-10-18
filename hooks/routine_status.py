"""UserPromptSubmit / Stop / PermissionRequest hook: record each *routine* session's state in
~/.claude/routine-status.json for the tray list (skills/routine-notify/tray.ps1).
running = working, go = waiting for the person, done = turn ended. notify.ps1 also writes go/fail.
Interactive sessions are ignored. Never blocks anything."""
import json, os, sys, time
from pathlib import Path

SESS = Path.home() / "AppData/Roaming/Claude/claude-code-sessions"
STATUS = Path.home() / ".claude/routine-status.json"

def load():
    try: return json.loads(STATUS.read_text(encoding="utf-8-sig"))
    except Exception: return {}

def save(st):
    tmp = STATUS.with_suffix(".tmp")
    tmp.write_text(json.dumps(st, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, STATUS)

def find_session(cli):
    # cliSessionId sits in the first ~200 bytes; only parse the one file that matches
    for f in SESS.glob("*/*/local_*.json"):
        try:
            with open(f, "rb") as fh:
                if cli.encode() not in fh.read(400): continue
            meta = json.loads(f.read_text(encoding="utf-8"))
            return meta["sessionId"] if meta.get("scheduledTaskId") else ""
        except Exception:
            continue
    return ""

def main():
    ev = json.loads(sys.stdin.buffer.read().decode("utf-8-sig"))
    cli, kind = ev.get("session_id", ""), ev.get("hook_event_name", "")
    if not cli: return
    st = load()
    cache = st.setdefault("_cli", {})
    sid = cache.get(cli)
    # A routine's session record may not be written yet on its first event, so "not a routine"
    # is only remembered for 2 minutes (a number = when we last looked), then looked up again.
    if not isinstance(sid, str) or not sid:
        if isinstance(sid, (int, float)) and time.time() - sid < 120: return
        sid = find_session(cli)
        cache[cli] = sid or time.time()
        if not sid:
            save(st); return
    s = st.setdefault(sid, {})
    if kind == "UserPromptSubmit":
        s.update(state="running", label="")
    elif kind == "PermissionRequest":
        s.update(state="go", label="承認待ち")
    elif kind == "Stop":
        # a GO/failure from notify.ps1 stays until the person replies; a permission wait ends with the turn
        if s.get("state") == "fail" or (s.get("state") == "go" and s.get("label") != "承認待ち"):
            pass
        else:
            s.update(state="done", label="")
    s["at"] = time.time()
    save(st)

try:
    main()
except Exception:
    pass  # status tracking must never affect the session
