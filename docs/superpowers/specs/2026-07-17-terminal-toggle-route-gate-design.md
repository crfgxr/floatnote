# Terminal Toggle Route Gate — Design

**Date:** 2026-07-17
**Status:** Approved
**Relates to:** `docs/superpowers/specs/2026-07-16-project-folders-design.md` (routing), `docs/superpowers/specs/2026-07-17-terminal-claude-auto-resume-design.md` (auto-resume), `docs/superpowers/specs/2026-07-17-terminal-focus-follows-route-design.md` (focus)

## Problem

On a note with no terminal route (no linked ancestor folder, no per-note override), the toolbar terminal toggle still opens the panel — and `showTerminal()` merely reveals whatever tab was last active, then focuses it. Observed: creating a fresh routeless note and toggling the terminal dropped the user into a *different project's* live Claude session (the last-active routed tab), where typing would land in an unrelated conversation. Terminals should be exclusively project-scoped: no route → no terminal.

## Behavior

- **Routeless note:** the toolbar terminal button renders disabled/grayed and does nothing when clicked. Tooltip: `Link a folder to use the terminal`. The panel cannot be opened from such a note.
- **Routed note:** the toggle keeps working. Hide branch unchanged. The show branch **re-applies the active note's own route** (dedup-or-create that project's tab via the existing route machinery, open panel, focus terminal) instead of revealing the last-active tab — the toggle can never surface a different project's session.
- **Auto behavior on note switch is unchanged:** route → panel auto-opens on the note's tab; no route → panel auto-hides (both already shipped).
- **Chip taps stay as-is:** selecting another project's chip inside the open panel is a deliberate act and still works (with reverse note-navigation). Only the *toggle's* show path snaps to the active note's route — so a foreign chip selection followed by hide + re-toggle lands back on the note's own project. Accepted and intended.

## Consequences — HOME fallback terminal retires

- Nothing can create a HOME tab anymore: the toggle is the only entry point to the panel from a routeless note, and `+` / Cmd+N (in-panel affordances, so only reachable on routed notes) use the active note's route.
- `showTerminal()`'s create-a-HOME-tab-when-empty branch becomes dead and is **removed**. If no callers of `showTerminal()` remain after the toggle rewire, delete the function.
- Edge case this fixes for free: on a routed note, close all tabs (✕ — last close hides the panel), then toggle — old code would have fabricated a HOME tab; new code re-applies the note's route and recreates the correct project tab.
- `claudeLaunchCommand`'s `dir == home` early-return branch (auto-resume spec) **stays** as a harmless safety net; it just becomes unreachable in normal use.
- Terminal tabs are runtime-only state (not persisted), so no migration: after this change a HOME tab simply never comes into existence.

## Implementation points

- `FormatToolbar`'s terminal toggle button (`App.swift`, the `vm.toggleTerminal()` call site): disabled + grayed when `vm.terminalRoute(for: activeTab) == nil`, with the tooltip above. Follow the toolbar's existing disabled-button styling conventions if any exist; otherwise reduced-opacity foreground with `.disabled(...)`.
- `EditorViewModel.toggleTerminal()`: hide branch unchanged; show branch calls the existing `applyTerminalRouteForActiveNote()` (route → `switchToRoute` + focus; no-route → no-op guard, defensive since the button is already disabled).
- No changes to `TerminalSessions`, `TerminalSession`, routing resolution (`effectiveRoute`/`terminalRoute`), chips, close/exit paths, hide≠kill, or focus rules beyond the toggle's show path.

## Out of scope

- No alternative access to a scratch/HOME shell (user decision: terminals are project-only).
- No change to the keyboard shortcuts or the panel's `+`.
- No restart affordance work (separate open item).

## Docs & versioning

- Bump `APP_VERSION` to `v1.51.0`.
- CLAUDE.md **Terminal** section: in the **Tab system** bullet, `` `+` adds a tab at the active note's route (or HOME) `` loses the `(or HOME)`; append one new bullet at the section's end: terminals are project-scoped — the toolbar toggle is disabled on routeless notes and its show path re-applies the active note's route; the HOME-fallback tab is retired (`claudeLaunchCommand`'s HOME branch remains as a safety net). Reference this spec's path.
