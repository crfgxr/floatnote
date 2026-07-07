# Terminal Route Ancestor Walk (Subfolder Notes Inherit the Parent's Terminal)

**Date:** 2026-07-07
**Status:** Approved design, pending implementation

## Problem

Folder-routed terminal tabs (`docs/superpowers/specs/2026-06-18-folder-routed-terminal-tabs-design.md`) resolve a note's terminal route from its **direct folder only**: `terminalRoute(for:)` looks for a "terminal path" note in `tab.folderId` and gives up otherwise. Notes in subfolders therefore hide the terminal panel even when a parent folder has a terminal route.

Real example: the `agentforce` folder contains `agentforce terminal path` plus a subfolder `toplantı notları` full of meeting notes. Switching to any meeting note hides the terminal instead of keeping the `agentforce` terminal open.

## Decisions (user-confirmed)

1. **Top-most ancestor wins.** When resolving a route for a note, walk the folder's ancestor chain and use the *highest* folder that has a "terminal path" note — even if a nearer folder (including the note's own) also has one. One terminal per tree.
2. **Reverse navigation covers the whole subtree.** Tapping a terminal chip returns to the last note the user had open *anywhere in that folder's subtree* (including subfolder notes), falling back to the first non-"terminal path" note in the owning folder.

## Design

### Route resolution (note → terminal)

New private helper on the ViewModel:

```swift
/// The folder whose "terminal path" note governs `folderId`'s subtree:
/// the TOP-MOST non-trashed ancestor (self included) containing a
/// non-trashed "terminal path" note. Nil when no ancestor has one.
private func terminalRouteFolder(startingAt folderId: UUID) -> Folder?
```

- Walk `parentId` links from the starting folder to the root, self first.
- Skip trashed folders entirely (a trashed ancestor contributes no route). Loose-trashed path notes are already excluded because their `folderId` is the Trash sentinel.
- Track the **last** (highest) folder seen that has a "terminal path" note (case-insensitive title substring, same predicate as today) and return it after the walk finishes.
- Cap the walk at 64 hops as a defensive guard against parent cycles (`moveFolder` already rejects cycles, but the walk must never hang on corrupt data).

`terminalRoute(for:)` changes to:

- Resolve `terminalRouteFolder(startingAt: tab.folderId)`; nil → no route (panel hides, unchanged behavior for notes outside any routed tree).
- Path = the winning folder's path note's first non-empty plain-text line, `~`-expanded — parsing identical to today.
- Label = the winning folder's name (so a `toplantı notları` note shows the `agentforce` chip).

No changes to `applyTerminalRouteForActiveNote()`, `switchToRoute`, dedup-by-path, pinned-mode guard, or hide-vs-kill semantics.

### Reverse navigation (terminal chip → note)

`folderForTerminalPath(_:)` is unchanged: a chip's path still maps to the folder that directly owns the matching "terminal path" note (which, per decision 1, is the tree root for routing purposes).

Two changes make chip-taps subtree-aware:

1. **Bookkeeping in `switchTab`:** in addition to `lastActiveNotePerFolder[note.folderId] = note.id`, also resolve the note's route-owning folder (`terminalRouteFolder(startingAt:)`) and, when it differs from the note's own folder, record `lastActiveNotePerFolder[owningFolder.id] = note.id`. The owning folder's entry thus remembers the last note opened anywhere in its subtree.
2. **Validation in `noteToActivate(forTerminalFolder:)`:** accept the remembered note when its `folderId` is the owning folder **or any descendant** (reuse the existing `descendantFolderIds` helper), instead of requiring an exact folder match. Fallback unchanged: the owning folder's first non-"terminal path" note.

### No ping-pong (invariant preserved)

Chip-tap → subtree note → that note's route resolves back to the same top-most path → `switchToRoute` dedups by path to the same chip → `activeTerminalId` doesn't re-fire. Chips whose path maps to no folder (e.g. the default HOME terminal) still leave the active note untouched.

## Out of scope

- Nearest-ancestor override semantics (explicitly rejected: top-most wins).
- Any change to manual `+` tab creation, ✕ close, `exit` handling, or panel sizing.
- Persisting subtree bookkeeping beyond the existing in-memory `lastActiveNotePerFolder`.

## Docs & versioning

- Update the **Folder-routed switching** and **Reverse routing** bullets in `CLAUDE.md` (remove "Direct folder only — no ancestor walk", describe top-most-ancestor + subtree reverse nav, link this spec).
- Bump `APP_VERSION` in `App.swift`.

## Testing (manual)

1. Note in `agentforce` → `agentforce` terminal opens (regression: unchanged).
2. Note in `agentforce/toplantı notları` → same `agentforce` terminal opens/stays; label is `agentforce`.
3. Give a subfolder its own "terminal path" note → subtree notes still route to the top-most (`agentforce`) terminal.
4. Chip-tap after being on a `toplantı notları` note → returns to that note.
5. Chip-tap with no prior subtree visit → lands on the owning folder's first non-"terminal path" note.
6. Note in a folder tree with no "terminal path" note anywhere → panel hides.
7. Loose-trash the "terminal path" note → subtree notes stop routing (panel hides); restore it → routing returns.
