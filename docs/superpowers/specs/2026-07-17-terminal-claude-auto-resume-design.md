# Terminal Claude Auto-Resume — Design

**Date:** 2026-07-17
**Status:** Approved
**Relates to:** `docs/superpowers/specs/2026-07-16-project-folders-design.md` (project-folder terminal routing)

## Problem

Every FloatNote terminal auto-types `claude` 0.6 s after its shell starts (`TerminalSession.startShell()`). For a project folder that already has an ongoing Claude conversation, this always starts a *new* conversation; the user must quit and manually run `claude --resume`/`--continue` to pick up where they left off. The desired default for a project terminal is: open with the latest Claude conversation for that directory.

## Behavior

- A terminal whose working directory comes from a **real route** — a folder's linked `localPath` or a note's per-note override — auto-types `claude --continue` when that directory has at least one saved Claude conversation, resuming the most recent one.
- If the directory has **no saved conversation** (first-ever open of the project), it auto-types plain `claude`. The user never sees Claude's "No conversation found" error.
- The **HOME fallback terminal** (the default terminal when a note has no route) always auto-types plain `claude`, unchanged.
- A shell restart re-runs the decision (via the `.floatnoteTerminalReset` notification → `restart()`; mechanism only — no UI trigger currently posts it): a terminal restarted mid-conversation resumes that conversation instead of losing it.

## Decision rule (all inside `TerminalSession.startShell()`)

The existing 0.6 s `asyncAfter` auto-run block computes the command **at send time**:

1. Let `dir` be the resolved launch directory (the session's `cwd`, already falling back to HOME when the path no longer exists).
2. If `dir == NSHomeDirectory()` → send `claude\n`. (This is exactly the HOME-fallback tab; a folder deliberately linked to HOME also lands here — accepted corner case.)
3. Otherwise, map `dir` to Claude Code's session store:
   `~/.claude/projects/<munged>` where `<munged>` = the absolute path with **every character outside `[A-Za-z0-9]` replaced by `-`** (slashes, dots, underscores, spaces all become dashes; verified against all 14 real entries in `~/.claude/projects/` on this machine).
4. If that directory exists and its top level (non-recursive) contains at least one `*.jsonl` file → send `claude --continue\n`; else → send `claude\n`.

No API changes: `TerminalSessions`, `TerminalTab`, the ViewModel, and all routing code are untouched. The generation guard (`sessionGen`) keeps working as-is since only the string being sent changes.

## Why `claude --continue` (not `--resume <id>`)

`claude --continue` resumes the most recent conversation *for the current directory* — precisely the wanted semantics — and keeps session-selection logic inside Claude Code. Resolving the newest `.jsonl` ourselves and passing `--resume <id>` would duplicate that logic and break if the session-file layout changes. The `.jsonl` existence check is only a boolean gate to avoid the no-history error, and any misdetection (symlinked paths, future layout changes) degrades safely to a fresh `claude`, never to an error.

## Edge cases

- **Conversation open elsewhere:** if the latest conversation is simultaneously active in another client (e.g. Terminal.app), `--continue` forks it — Claude Code's normal resume behavior; acceptable.
- **Symlinks / path normalization:** the munge uses the path FloatNote launches the shell with. If Claude Code recorded a differently-normalized path, detection misses and a fresh `claude` starts — safe fallback.
- **Restart while claude is running:** a restart kills the shell and re-runs `startShell()`; the just-used conversation's `.jsonl` exists, so the terminal comes back with `claude --continue` and re-enters it.

## Out of scope

- No per-folder or global toggle to opt out of resuming (YAGNI; `Ctrl+C` + `claude` gets a fresh session manually).
- No picker UI for choosing among past conversations (`claude --resume`'s interactive picker remains a manual option).

## Docs & versioning

- Bump `APP_VERSION` in `App.swift`.
- Add one line to the CLAUDE.md **Terminal** section describing the rule: routed terminals auto-run `claude --continue` when `~/.claude/projects/<munged-cwd>` has session files; HOME and first-open projects run plain `claude`.
