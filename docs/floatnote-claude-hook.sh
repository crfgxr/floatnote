#!/bin/bash
# FloatNote ← Claude Code hook bridge.
#
# Registered in ~/.claude/settings.json for the Stop and Notification events;
# installed at ~/.claude/hooks/floatnote-notify.sh (source of truth lives in
# the FloatNote repo at docs/floatnote-claude-hook.sh).
#
# Reads the hook JSON from stdin and drops one small file per event into the
# ~/.floatnote-claude-events/ spool dir (temp+rename, so FloatNote's 2s watcher
# never sees a half-written file). FloatNote decides whether to notify — only
# events whose cwd matches an open FloatNote terminal tab produce a banner.
#
# Must never block or fail Claude: always exits 0.

SPOOL="$HOME/.floatnote-claude-events"
mkdir -p "$SPOOL" 2>/dev/null || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 -c '
import json, sys, os, time, uuid
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
# A Stop hook that itself re-enters would spool a duplicate event (and, with
# hands-free voice on, speak the same turn twice).
if str(data.get("stop_hook_active", "")).lower() == "true":
    sys.exit(0)
evt = {
    "event": data.get("hook_event_name", ""),
    "cwd": data.get("cwd", ""),
    "message": data.get("message", ""),
    # Claude last turn text, for hands-free voice. Absent on older hook
    # installs and on events that carry no assistant message.
    "last_assistant_message": data.get("last_assistant_message", ""),
    # Which conversation this pane is running, for the transcript pane. Claude
    # Code puts both on every hook event; cwd alone cannot identify a session
    # (two panes on one project are two different .jsonl files).
    "session_id": data.get("session_id", ""),
    "transcript_path": data.get("transcript_path", ""),
    "ts": time.time(),
}
spool = sys.argv[1]
tmp = os.path.join(spool, ".tmp-" + uuid.uuid4().hex)
final = os.path.join(spool, uuid.uuid4().hex + ".json")
try:
    with open(tmp, "w") as f:
        json.dump(evt, f)
    os.replace(tmp, final)
except Exception:
    pass
' "$SPOOL" 2>/dev/null

exit 0
