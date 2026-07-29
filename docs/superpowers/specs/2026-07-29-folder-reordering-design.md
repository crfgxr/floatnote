# Folder Reordering (drag-and-drop) — Design

Date: 2026-07-29

## Problem

Sidebar folders cannot be reordered. A folder drag has exactly one outcome today:
`FolderDropDelegate.performDrop` → `vm.moveFolder(_:toParent:)`, i.e. "nest inside the
target". Sibling order is the relative order of `vm.folders` (the sidebar filters by
`parentId`, and `filter` preserves order), and nothing ever changes it — new folders are
appended, so the order is creation order, permanently.

Notes, by contrast, already reorder via hover-swap (`TabDropDelegate.dropEntered` →
`moveTab(from:to:)`).

## Interaction model

`FolderDropDelegate` gains a position concept. When `vm.draggingFolderId != nil`, the
delegate reads `info.location.y` against the folder header row's height and resolves one
of three intents:

| Zone            | Intent   | Action                                              |
| --------------- | -------- | --------------------------------------------------- |
| top 30%         | above    | insert as previous sibling of the target             |
| middle 40%      | inside   | nest inside the target (today's behavior)            |
| bottom 30%      | below    | insert as next sibling of the target                 |

**A sibling drop adopts the target's `parentId`.** Dropping a subfolder above/below a root
folder promotes it to root; dropping a root folder next to a subfolder demotes it into that
parent. Without this the gesture would silently no-op whenever the two folders had
different parents.

Out of scope — unchanged behavior:

- A dragged **note** on a folder row ignores zones: any position moves it into the folder.
- Note-on-note still hover-swaps.
- The empty-sidebar drop target (`FolderDropDelegate(folderId: nil)`) still means "move to
  root", appended at the end.

### Feedback

- **inside** → the existing accent fill on the row.
- **above/below** → a 2pt accent insertion line on that edge of the row, and *no* fill.

Exactly one of the two ever shows.

## State

- `vm.dropTargetFolderId: UUID?` — unchanged, drives the fill.
- `vm.folderInsertIndicator: FolderInsertIndicator?` — new; `{ id: UUID, below: Bool }`
  drives the line. Cleared on `dropExited` and after any drop.
- Row height: a `GeometryReader` in the header's `.background`, captured into a `@State` on
  `SidebarFolderView` and handed to the delegate. `DropInfo.location` is already expressed
  in the coordinate space of the view the `.onDrop` is attached to (the header `HStack`).

**No new persisted field.** Reordering moves the element within `vm.folders`; the existing
`saveFoldersLocal()` writes array order, and the MCP server round-trips folder objects, so
`~/.floatnote-folders.json` needs no schema change.

## New ViewModel method

```swift
func moveFolder(_ folderId: UUID, relativeTo targetId: UUID, below: Bool)
```

1. Reject `folderId == targetId`.
2. Reject cycles: `isSelfOrDescendant(targetId, of: folderId)` — you cannot drop a folder
   next to one of its own descendants, because that would reparent it under itself.
3. Set `parentId = target.parentId`, auto-expanding that parent if collapsed.
4. Remove the dragged element from `folders` and reinsert it immediately before (or after,
   when `below`) the target's index — recomputed *after* the removal.
5. `folders = folders` to re-fire `@Published`, then `saveFoldersLocal()`.

Only the dragged folder's element moves. Descendants keep their `parentId` links, so the
subtree travels with it; array contiguity is irrelevant because rendering is by `parentId`.

## Error handling

Rejected drops (self, cycle) clear the indicators and return `true` — nothing moves and no
error is surfaced. Trashed folders are already filtered out of the rendered lists, so they
can never be drop targets.

## Testing

Manual, matching how the rest of the sidebar is verified:

1. Reorder two root folders, both directions.
2. Reorder subfolders within one parent.
3. Promote a subfolder to root by dropping it between two root folders.
4. Demote a root folder by dropping it between two subfolders.
5. Drop a parent between its own children → must no-op.
6. Order survives quit/relaunch (`~/.floatnote-folders.json`).
7. A note dragged onto a folder row still nests, from every vertical position.
