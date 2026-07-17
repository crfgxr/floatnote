# Claude Hook → Native Notifications — Design

**Date:** 2026-07-17
**Status:** Approved (user picked: FloatNote-terminals only; always notify; click jumps to terminal)

## Problem

Claude Code sessions run inside FloatNote's terminal panels. When Claude
finishes a response or needs input, the user gets no signal unless they're
watching. Wanted: a native macOS notification for those moments; clicking it
focuses FloatNote and jumps to the right terminal.

## Pipeline

`Claude Code hook → spool file → FloatNote watcher → UNUserNotification → click routes back`

1. **Hook script** — `docs/floatnote-claude-hook.sh` (repo source), installed at
   `~/.claude/hooks/floatnote-notify.sh`, registered globally in
   `~/.claude/settings.json` for the `Stop` and `Notification` events. Reads the
   hook JSON from stdin (python3), writes one file per event into the
   `~/.floatnote-claude-events/` spool dir via temp+rename:
   `{event, cwd, message, ts}`. One-file-per-event avoids write races between
   concurrent sessions. Always exits 0 — the hook must never block Claude.
2. **Watcher** — `vm.checkClaudeEvents()` joins the existing 2-second
   AppDelegate timer (External File Sync pattern). Consumes and deletes every
   spool file; keeps only events whose standardized `cwd` equals an open
   terminal tab's path. Claude runs in external terminals (no matching tab) are
   dropped silently — this is the "FloatNote terminals only" filter, done
   app-side so the hook can stay global and dumb.
3. **Notification** — `UNUserNotificationCenter` (required for click-to-focus).
   Title = the terminal tab's label (project name), body = "Claude finished
   working" for `Stop`, or the hook's own message for `Notification` (e.g.
   permission requests). `userInfo` carries the tab's path. Banner + sound are
   shown even while FloatNote is frontmost (`willPresent` returns
   `[.banner, .sound]`) — per the "always notify" decision.
4. **Click** — `didReceive` (AppDelegate is the center's delegate): activate the
   app, resolve the tab by path (id may be stale), `selectTerminal(tab.id)` —
   reusing reverse routing: activates the chip, navigates to the project's
   last-open note, focuses the terminal. Tab gone → just activate the app.
5. **Permission** — `requestAuthorization([.alert, .sound])` at launch; the
   grant persists across rebuilds thanks to the stable "FloatNote Dev" signing
   identity.

## Known semantics

- `Stop` fires at the end of EVERY Claude response — banners are per-turn, not
  per-task (Claude Code can't distinguish "done with everything"). Chatty by
  design; tune later (e.g. only-when-backgrounded) if unwanted.
- The cwd filter can false-positive if the user runs claude in an external
  terminal at exactly a project folder's path while a FloatNote tab for it is
  open. Accepted.

## Verification

Manual: with the floatnote project terminal open, write a fake spool file with
this repo's path as `cwd` → banner appears within 2s; click → FloatNote
activates on the project note with the terminal focused. Real path: ask Claude
something in a FloatNote terminal, get the turn-end banner. External-terminal
claude runs in an unrelated dir must NOT notify.
