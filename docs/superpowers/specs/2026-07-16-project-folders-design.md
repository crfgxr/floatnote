# Project Folders — folder-linked local directories replace "terminal path" notes

**Date:** 2026-07-16
**Status:** Design approved, ready for implementation plan
**Supersedes:** the "terminal path" note convention from
`2026-06-18-folder-routed-terminal-tabs-design.md` and
`2026-07-07-terminal-route-ancestor-walk-design.md` (mechanism only — the
terminal panel, tab dedup, and reverse-routing behaviors are kept).

## Problem

Today a folder is wired to a terminal working directory by creating a note whose
**title contains "terminal path"** and whose **first body line is the path**.
This works but is a hidden magic-string convention: it clutters the note list,
nothing in the UI signals that a folder is routed, and the path is buried inside
a note body. A folder-ancestor walk picks the **top-most** such note.

## Goal

Make the folder↔directory link a **first-class property**, the way Claude Code /
cowork treat a workspace: a folder that is linked to a local directory *is a
project*. Its notes inherit that directory; the terminal opens there
automatically. No magic note.

## Model (decisions)

- **Path lives on folders, with a per-note override.** A `Folder` gets an
  optional `localPath`; a `NoteTab` gets an optional `localPath` (its own
  override). (Decision: "Folders + note override".)
- **Resolution order for a note's directory** (`terminalRoute`):
  1. **Note override.** If the note's own `localPath` is set and non-empty, use
     it. Always wins.
  2. **Nearest project.** Otherwise walk UP the folder chain from the note's
     own folder and use the **first** folder with a non-empty `localPath`. A
     sub-project (`AgentforceX`) overrides its parent (`Work`). *(This reverses
     today's top-most-wins.)*
  3. **None.** No override and no linked ancestor → no route; terminal panel
     stays hidden (same as an unrouted note today).
- **Chip / sidebar display:** show the **folder name** (last path component),
  full path on hover. (Decisions: chip = name+hover; sidebar = 🔗 icon + hover.)
- **Setting a path:** clicking the toolbar chip / the folder context-menu item
  opens the **native macOS folder picker** (`NSOpenPanel`,
  `canChooseDirectories`). Straight to the picker — no intermediate menu.
- **Migration:** one-time auto-migrate on upgrade — see below.

## Data model changes (`App.swift`)

```
struct FolderData: Codable {
    …
    var localPath: String? = nil   // NEW — nil = plain folder (back-compat)
}
class Folder {
    @Published var localPath: String?   // NEW
    // update init / toData / from
}

struct TabData: Codable {
    …
    var localPath: String? = nil   // NEW — nil = inherit from folder chain
}
class NoteTab {
    @Published var localPath: String?   // NEW  (the per-note override)
    // update toData / from
}
```

Paths are stored as returned by the picker (absolute). Display abbreviates the
home prefix to `~` and shows the last component in chip/sidebar.
`expandingTildeInPath` is applied on read (harmless on absolute paths, keeps any
`~`-form paths from migration working).

## Resolution logic (`EditorViewModel`, replaces the note-walk)

- **`effectiveRoute(for tab) -> (path: String, label: String, source: .own | .inherited(Folder) | .none)`**
  implements the 3-step order above. `label` is the **terminal-tab** label:
  the FloatNote `folder.name` for the inherited case (unchanged from today, so
  reverse-routing labels stay stable), the path's last component for the
  override case.
- **Two distinct labels, don't conflate them.** The **terminal-tab chip** (in
  the terminal panel) uses `effectiveRoute.label` above. The **toolbar folder
  chip** always shows the effective **directory's last path component** (e.g.
  `agentforce-x`), full path on hover — independent of the FloatNote folder's
  name. In the common case they coincide; when a folder named `AgentforceX`
  links `~/work/af-x`, the terminal chip reads `AgentforceX` and the toolbar
  chip reads `af-x`.
- **`terminalRoute(for:)`** becomes a thin wrapper returning `(path, label)` for
  `.own`/`.inherited`, `nil` for `.none`. `applyTerminalRouteForActiveNote`,
  `switchToRoute`, `addTerminal`, dedup-by-path, and pin handling are **unchanged**.
- **`terminalRouteFolder(startingAt:)`** changes from "top-most ancestor with a
  terminal-path note" to "**nearest** ancestor with a non-empty `localPath`"
  (keep the 64-hop cycle cap and trashed-folder skip).
- **`terminalPathNote(in:)`** is deleted.
- **`folderForTerminalPath(_:)`** (reverse routing, terminal chip → note)
  changes to: first non-trashed folder whose `localPath` (expanded) == path.
  Override-only paths that match no folder return `nil` (chip leaves the active
  note untouched — same "no ping-pong" contract as today).
- **`noteToActivate(forTerminalFolder:)`** drops the `!title.contains("terminal
  path")` exclusion (that convention is gone); otherwise unchanged.

## UI

### Note toolbar chip (`FormatToolbar`)
- New trailing control after `pinButton`. Renders the note's **effective**
  directory: folder name, `.help(fullPath)` for the hover tooltip.
- Visual state: accent (inherited), amber + trailing ✕ (own override), faint
  dashed "Set folder…" (none). Uses `Tokens` (link blue `#6cb6ff`, amber for
  override) — add tokens rather than hard-coding.
- **Click** → `NSOpenPanel` (directory) → set `activeTab.localPath` → save +
  `applyTerminalRouteForActiveNote()`. The ✕ (override state only) clears
  `activeTab.localPath = nil` and re-resolves.
- Hidden when there is no active note.

### Folder context menu + row (`SidebarFolderView`)
- Context menu: **Link Local Folder…** when unlinked; **Change Folder…** +
  **Unlink Folder** when linked. Each opens `NSOpenPanel` / mutates
  `folder.localPath`, then reassigns `folders = folders` (the @Published refire
  pattern) and saves.
- Folder row: small 🔗 glyph when `localPath != nil`, `.help(path)` on hover.

## Persistence & external sync

- `localPath` rides along in `FolderData`/`TabData`, so `saveFoldersLocal` /
  `saveTabsLocal` persist it with no format change (new optional field).
- `checkExternalFolderChanges` and the external-tab merge must sync `localPath`
  the same way they sync `name` / `parentId` / `folderId` today (reassign the
  parent array so `@Published` refires).
- **MCP (`mcp-server.js`):** the server round-trips whole folder/note objects,
  so the new field is preserved automatically. Verify the folder and note
  read-modify-write paths don't drop unknown keys; add explicit passthrough if
  they do. (No new MCP tools in v1.)

## Migration (one-time, at launch)

Guarded by a `UserDefaults` flag `fn.projectFoldersMigrated` so it runs once:

1. After folders + tabs load, for each **non-trashed** folder whose `localPath`
   is `nil`: find a child note whose title contains "terminal path"
   (case-insensitive). If found, set `folder.localPath` = that note's first
   non-empty body line, `~`-expanded.
2. Leave the old note in place as an ordinary note (the user can delete it).
3. Save folders; set the flag.

This preserves every currently-routed folder with zero user action and no
fallback path in the resolver (the note convention is fully removed).

## Out of scope (v1)

- MCP tools to set a folder/note path programmatically.
- Opening the linked folder in Finder / a file tree in the sidebar.
- Any "recent folders" picker convenience.

## Affected files

- `FloatNote/FloatNote/App.swift` — models, resolver, toolbar chip, folder menu
  + row, external-sync merges, launch migration, `APP_VERSION` bump.
- `FloatNote/FloatNote/DesignTokens.swift` — chip/override color + size tokens.
- `mcp-server.js` — verify folder/note field passthrough.
- `CLAUDE.md` — rewrite the Terminal routing section (remove the terminal-path
  note convention; document project folders + override + nearest-wins).
- `build.sh` run after changes (per project rule).

## Testing / verification

- Migration: a folder with a "terminal path" note gets `localPath` set on first
  launch; the note remains; flag prevents re-migration.
- Resolution: note override > nearest project > none; sub-project overrides
  parent; trashed folders skipped; 64-hop cap holds.
- Reverse routing: terminal chip → correct note; override-only path leaves the
  active note untouched; no ping-pong.
- Persistence: set via picker → survives relaunch; MCP edit of the folders file
  preserves `localPath`; external edit shows up within the 2 s poll.
- UI: chip states (inherited / override+✕ / unset), hover tooltip shows full
  path, folder-row 🔗 + hover.
