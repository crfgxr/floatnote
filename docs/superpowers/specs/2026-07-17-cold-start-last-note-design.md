# Cold Start Opens the Last-Open Note — Design

**Date:** 2026-07-17
**Status:** Approved (user picked: restore last-open note; keep "agentforce tasks" as fallback)

## Problem

Launch always opened the "agentforce tasks" note (or the first non-trashed
tab). The user wants cold start to land on the note they were last working in.

## Design

- **Persist:** `activeTabId.didSet` writes the note's UUID string to the
  `fn.lastActiveNoteId` UserDefault (same pattern as `fn.terminalVisible`).
  Every note switch refreshes it, so it's crash-safe with no extra file I/O.
  `nil` assignments are ignored — the default always names a real last note.
- **Restore:** `load()` resolves the launch note in priority order:
  1. the tab matching `fn.lastActiveNoteId`, if it still exists and is visible
     (not loose-trashed, not in a trashed folder);
  2. the existing "agentforce tasks" title match (case/whitespace-insensitive);
  3. the first non-trashed tab;
  4. `tabs[0]`.
- **Unchanged:** `switchToFirstVisibleTab(excluding:)` (used when trashing the
  active note, external tab deletion, etc.) keeps the agentforce-tasks
  preference — the note being vacated *is* the most recent, so "last open"
  is meaningless there.
- **Composition:** the restored note's terminal route applies as usual on
  launch (`applyTerminalRouteForActiveNote` at the end of `load()`), so a
  project note comes back with its terminal open and focused.

## Verification

Manual: open some note X (not agentforce tasks), quit, relaunch → X is active.
Trash X, relaunch → agentforce tasks note. Fresh defaults
(`defaults delete` the key) → agentforce tasks note.
