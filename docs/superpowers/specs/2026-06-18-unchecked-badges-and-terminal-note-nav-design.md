# Unchecked-item badges + bidirectional terminal↔note navigation

Date: 2026-06-18

Two related sidebar/terminal features for FloatNote.

## Feature A — Unchecked-item count badges

### Goal
On each sidebar note row, show a red pill with a white number = count of unchecked
checklist items (`☐`) in that note. Hidden when the count is 0. Updates instantly as
the user types or toggles a checkbox in the open note.

### Decisions
- Color: `#ff3b30` (iOS notification red), white text.
- Counts above 99 render as `99+`.

### Data
- Add `@Published var uncheckedCount: Int = 0` to `NoteTab`.
- Helper to count `☐` glyphs in a note's plain text:
  `static func countUnchecked(in plainText: String) -> Int`
  (count occurrences of the `☐` character).
- For HTML-backed notes, decode via `htmlToAttributedString(html)?.string` then count.
  Provide `NoteTab.recomputeUncheckedFromHTML()`.

### When it recomputes
1. **Load** — in `loadTabs` / `checkExternalTabChanges` (and `NoteTab.from` callers),
   call `recomputeUncheckedFromHTML()` for every tab. Handles non-active notes and
   external/MCP edits.
2. **Save** — wherever a tab's `html` is persisted, recompute that tab's count.
3. **Live (active note)** — the `RichTextEditor` coordinator recounts `☐` directly from
   the live `NSTextStorage.string` on every text change AND inside the checkbox-toggle
   path, then sets `vm.activeTab?.uncheckedCount`. This makes the badge drop the instant
   a box is checked, before any save.

### View
In `SidebarNoteView` (App.swift ~3109), between the title `Text` and the trailing edge,
add a badge shown only when `tab.uncheckedCount > 0`:
- A `Capsule` filled `Color(red:1, green:0.23, blue:0.19)` (#ff3b30), white bold number,
  ~9pt, min width ~16, height ~16, horizontal padding ~5.
- Display string: `count > 99 ? "99+" : "\(count)"`.
`NoteTab` is already an `@ObservedObject` in the row, so the `@Published` change
re-renders the badge automatically.

## Feature B — Terminal → note navigation (make routing bidirectional)

### Current state
Note → terminal already works: `terminalRoute(for:)` maps the active note → its folder's
"terminal path" note → a shell path; `applyTerminalRouteForActiveNote()` runs on every
`activeTabId` change and switches/creates the matching terminal tab.

### Goal
Reverse direction: tapping a terminal chip jumps to the related note in that terminal's
folder. Target note = "last note you had open in that folder".

### Mapping
- `folderForTerminalPath(_ path: String) -> Folder?` — reverse of `terminalRoute`:
  for each folder that has a "terminal path" note, resolve that note's path (same
  first-non-empty-line, `~`-expanded logic) and return the folder whose resolved path
  equals `path`.

### Target-note tracking
- `lastActiveNotePerFolder: [UUID: UUID]` on the VM, updated in `switchTab` whenever the
  newly-active note has a non-nil `folderId` (and is not trashed).
- `noteToActivate(forTerminalFolder folder:)`:
  1. `lastActiveNotePerFolder[folder.id]` if that note still exists and is in the folder.
  2. else the folder's first note whose title does NOT contain "terminal path".
  3. else nil (do nothing).

### Wiring
- New `func selectTerminal(_ id: UUID)`: sets `activeTerminalId = id`, then if the chip's
  path maps to a folder + target note, calls `switchTab(targetNoteId)`.
- The terminal chip `.onTapGesture` (App.swift ~2480) calls `vm.selectTerminal(tab.id)`
  instead of assigning `activeTerminalId` directly.
- **No loop**: `switchTab` → `applyTerminalRouteForActiveNote` → `switchToRoute(path)`
  dedups by path to the same terminal tab, so `activeTerminalId` is unchanged and nothing
  re-fires. Chips whose path maps to no folder (e.g. default HOME terminal) leave the
  active note untouched.

## Build
Run `./build.sh` after changes to update `/Applications/FloatNote.app`. Bump `APP_VERSION`.
