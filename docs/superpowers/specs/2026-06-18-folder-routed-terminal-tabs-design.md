# Folder-Routed Terminal Tabs — Design

**Date:** 2026-06-18
**Status:** Approved, pending implementation

## Problem

Each project folder in FloatNote corresponds to a real directory on disk where the
user runs Claude Code. Today the embedded terminal panel hardcodes a single working
directory (`preferredCwd` in `Terminal.swift`) and shows sessions as resizable
side-by-side columns. There is no link between the note you are reading and the
terminal's working directory.

The user wants: navigating to a note that lives in a folder with a known directory
should make the terminal panel reflect that directory. Terminals become a **tab
system** (one window, one visible terminal at a time, tabs to switch). If a terminal
for that route is already open, switch to it; otherwise create a new one.

## Route source: the "terminal path" note

A folder's working directory is defined by a note **inside that folder whose title
contains the substring "terminal path"** (case-insensitive). The directory is that
note's body — converted to plain text — **first non-empty line**, with a leading `~`
expanded to the home directory.

This keeps the path editable as an ordinary note, visible in the sidebar, and
reachable via MCP, with no new data-model field.

### Route resolution

New `EditorViewModel` helper:

```swift
func terminalRoute(for tab: NoteTab?) -> (path: String, label: String)?
```

- Resolve `tab.folderId` → the folder. **Direct folder only** — do NOT walk up to
  ancestor folders. A subfolder without its own terminal-path note has no route.
- Find a non-trashed note with the same `folderId` whose title contains
  "terminal path" (case-insensitive).
- Convert that note's HTML body to plain text (reuse `htmlToAttributedString(...).string`),
  take the first non-empty trimmed line → `path`. Expand a leading `~`.
- `label` = the folder's name.
- Return `nil` when: the note has no folder, no terminal-path note exists in that
  folder, or the resolved path is empty.

## Terminal data model

Replace the side-by-side column machinery with a tab model.

**New:**
```swift
struct TerminalTab: Identifiable { let id: UUID; let path: String; let label: String }
@Published var terminalTabs: [TerminalTab] = []
@Published var activeTerminalId: UUID?
```

**Removed from `EditorViewModel`:** `terminalIds`, `terminalWidths`, `width(for:)`,
`setWidth(_:for:)`, `totalTerminalWidth`, `clampTerminalWidths()`,
`minTerminalColumnWidth` (the proportional multi-column clamp is gone — only one
terminal is visible at a time).

**Kept:** `terminalWidth` — the single width of the panel, driven by the
editor↔panel divider. `isTerminalVisible`. `availablePanelWidth()`.

### Switching to a route (dedup by path)

```swift
func switchToRoute(path: String, label: String)
```
- If a `TerminalTab` with the same resolved `path` exists → set it active.
- Else append a new `TerminalTab(id:, path:, label:)` and set it active.
- Set `isTerminalVisible = true`.

## Navigation rule (core behavior)

A single method, called wherever `activeTabId` changes (`switchTab`, `addTab`,
`switchToFirstVisibleTab`, and the launch default-open path):

```swift
func applyTerminalRouteForActiveNote()
```
- If `terminalRoute(for: activeTab)` returns a route → `switchToRoute(path:label:)`
  (auto-opens the panel).
- Otherwise → hide the panel (`isTerminalVisible = false`).

Hiding never kills sessions (existing "hide ≠ kill" rule), so returning to a routed
note re-shows its tab with the shell intact.

**Accepted consequence:** creating a new untitled note (`addTab`, lands at root → no
route) hides the terminal panel. This is consistent with the rule and was confirmed
acceptable.

## Session working directory (`Terminal.swift`)

- `TerminalSession.init(id:cwd:)` and `TerminalSessions.session(for:cwd:)` take the
  route path.
- Remove the hardcoded `preferredCwd`. Use the passed `cwd`; if it does not exist on
  disk, fall back to `HOME`.
- `claude` auto-run on shell start is unchanged (this is the point — Claude Code
  launched per project folder).
- Existing sessions ignore the `cwd` argument (a session's directory is fixed at
  creation); only first-time creation uses it.

## UI (`TerminalPanel`)

- **Tab bar** across the top: one chip per `terminalTab`, showing the folder-name
  `label`, with an active-state highlight and a ✕ to close. Path shown as tooltip.
  A `+` button at the end.
- **Body:** a single `SwiftTermContainer(id: activeTerminalId)` filling the rest.
- Clicking a chip sets `activeTerminalId`.
- `+` opens a new terminal at the **current note's route** (or `HOME` if none) — a
  fresh tab regardless of dedup.
- ✕ closes a tab: `TerminalSessions.shared.close(id)`, remove from `terminalTabs`,
  activate a neighbor; closing the last tab hides the panel.
- Remove the inter-column `TerminalResizeHandle`. Keep the editor↔panel handle,
  simplified: drag adjusts `terminalWidth`, capped to `availablePanelWidth()`
  (no per-id widths, no proportional clamp).

## AppDelegate

- Cmd+W (close focused terminal) / Cmd+N (new terminal) key monitor: rework from
  `terminalIds` to `terminalTabs` / `activeTerminalId`.
- `neighborTerminal(of:in:)` and `focusTerminal(_:)`: operate on `terminalTabs` and
  set `activeTerminalId` instead of indexing the column array.
- The `.floatnoteTerminalExited` observer still routes to `closeTerminal`.

## Persistence

Terminal tabs are not persisted across app restarts (shells do not survive a restart
anyway). At launch, after the default-open note is selected,
`applyTerminalRouteForActiveNote()` drives the initial terminal state. The
`fn.terminalVisible`-based seeding of an initial empty session is removed.

## Edge cases

- Path note's first line is not a valid directory → shell opens at `HOME`.
- Multiple folders pointing at the same path → share one tab (dedup by resolved path).
- Editing the terminal-path note's text does not retroactively move an already-open
  session; the new path takes effect next time that route is resolved (a fresh tab
  is created if the path string changed).

## Out of scope (YAGNI)

- Inheriting a route from ancestor folders.
- Persisting/restoring terminal tabs across launches.
- Re-homing a live shell when the path note is edited.
- A default/home terminal tab for no-route notes (panel just hides).
