#!/bin/bash
# Reliable relaunch of /Applications/FloatNote.app.
#
# Why this exists: build.sh's own relaunch can silently no-op from a sandboxed
# shell (its pkill is blocked, and `open` then just re-focuses the STALE
# instance), and a bare `open` right after a quit fails with LaunchServices
# error -600 because the old process hasn't exited yet. This quits, WAITS for
# the pid to go away, opens, and verifies the running process is newer than the
# binary — retrying if it isn't. No `sleep` (blocked in some sandboxed shells).
set -u
APP=/Applications/FloatNote.app
BIN="$APP/Contents/MacOS/FloatNote"
PATTERN='FloatNote.app/Contents/MacOS'

osascript -e 'tell application "FloatNote" to quit' >/dev/null 2>&1

python3 - "$APP" "$BIN" "$PATTERN" <<'PY'
import os, subprocess, sys, time

app, binary, pattern = sys.argv[1:4]

def pids():
    out = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout
    return [int(p) for p in out.split()]

def started(pid):
    out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    return time.mktime(time.strptime(out))

# 1. wait for the quit (then force it)
for _ in range(60):
    if not pids():
        break
    time.sleep(0.1)
else:
    for pid in pids():
        try: os.kill(pid, 15)
        except OSError: pass
    for _ in range(30):
        if not pids(): break
        time.sleep(0.1)

built = os.path.getmtime(binary)

# 2. open, and verify the process we get is the NEW binary
for attempt in range(1, 4):
    subprocess.run(["open", "-a", app], capture_output=True)
    for _ in range(60):
        live = [p for p in pids() if (started(p) or 0) >= built - 1]
        if live:
            print(f"relaunched pid {live[0]} (binary {time.ctime(built)}) attempt {attempt}")
            sys.exit(0)
        time.sleep(0.1)
    print(f"attempt {attempt}: not up yet, retrying")

print("FAILED to relaunch — start it by hand")
sys.exit(1)
PY
