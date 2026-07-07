# Terminal Route Ancestor Walk Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Notes in subfolders route to (and stay in) the terminal of the top-most ancestor folder that has a "terminal path" note, and terminal chip-taps navigate back to the last note opened anywhere in that subtree.

**Architecture:** All changes live in the ViewModel in `FloatNote/FloatNote/App.swift`. A new `terminalRouteFolder(startingAt:)` helper walks the folder `parentId` chain and returns the top-most folder with a "terminal path" note; `terminalRoute(for:)` uses it instead of the direct folder. Reverse navigation gets subtree-aware bookkeeping in `switchTab` and subtree validation in `noteToActivate(forTerminalFolder:)`.

**Tech Stack:** Swift / SwiftUI (macOS 14+), SPM. No test target exists — each task verifies via `./build.sh` (builds AND deploys to /Applications; never bare `swift build`), plus a manual test pass in Task 3.

**Spec:** `docs/superpowers/specs/2026-07-07-terminal-route-ancestor-walk-design.md`

## Global Constraints

- After ANY code change run `./build.sh` (never just `swift build`) — it must exit 0.
- Bump `APP_VERSION` (`App.swift:19`, currently `v1.36.1`) once, in Task 3, to `v1.37.0`.
- "terminal path" note predicate is case-insensitive title substring `"terminal path"` — identical everywhere.
- Loose-trashed notes have `folderId == TRASH_FOLDER_ID`, so folder-scoped note lookups exclude them automatically; no extra trash checks on notes.
- Ancestor walk must skip trashed folders and cap at 64 hops (cycle guard).

---

### Task 1: Ancestor-walk route resolution

**Files:**
- Modify: `FloatNote/FloatNote/App.swift` — `folderForTerminalPath(_:)` (~line 499), `terminalRoute(for:)` (~line 551), plus two new private helpers next to `terminalRoute`.

**Interfaces:**
- Produces: `private func terminalPathNote(in folderId: UUID) -> NoteTab?` and `private func terminalRouteFolder(startingAt folderId: UUID) -> Folder?` (Task 2 consumes the latter). `terminalRoute(for:)` signature unchanged: `(path: String, label: String)?`.

- [ ] **Step 1: Add the two helpers**

Insert immediately above `terminalRoute(for:)` (currently at ~line 548, the comment `/// The terminal route for a note: ...`):

```swift
    /// The "terminal path" note directly inside `folderId`, if any. Loose-trashed
    /// notes are excluded automatically (their folderId is the Trash sentinel).
    private func terminalPathNote(in folderId: UUID) -> NoteTab? {
        tabs.first { $0.folderId == folderId && $0.title.lowercased().contains("terminal path") }
    }

    /// The folder whose "terminal path" note governs `folderId`'s subtree: the
    /// TOP-MOST non-trashed ancestor (self included) that contains a "terminal
    /// path" note. Nil when no ancestor has one. Capped at 64 hops so a corrupt
    /// parent cycle can never hang the walk (moveFolder already rejects cycles).
    private func terminalRouteFolder(startingAt folderId: UUID) -> Folder? {
        var winner: Folder? = nil
        var currentId: UUID? = folderId
        var hops = 0
        while let cid = currentId, hops < 64 {
            hops += 1
            guard let folder = folders.first(where: { $0.id == cid }) else { break }
            if !folder.isTrashed && terminalPathNote(in: cid) != nil {
                winner = folder
            }
            currentId = folder.parentId
        }
        return winner
    }
```

- [ ] **Step 2: Rewire `terminalRoute(for:)` to the ancestor walk**

Replace the whole existing function (doc comment + body, ~lines 548–565):

```swift
    /// The terminal route for a note: the TOP-MOST ancestor folder (the note's
    /// own folder included) with a "terminal path" note; path = that note's
    /// first non-empty body line, `~`-expanded; label = that folder's name.
    /// Returns nil when there's no folder, no path note anywhere up the chain,
    /// or an empty path.
    func terminalRoute(for tab: NoteTab?) -> (path: String, label: String)? {
        guard let tab, let folderId = tab.folderId,
              let folder = terminalRouteFolder(startingAt: folderId),
              let pathNote = terminalPathNote(in: folder.id) else { return nil }
        let plain = htmlToAttributedString(pathNote.html)?.string ?? ""
        guard let firstLine = plain
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        let expanded = (firstLine as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        return (expanded, folder.name)
    }
```

Note the direct-folder guard `folders.first(where: { $0.id == folderId })` is gone on purpose — `terminalRouteFolder` does that lookup. A note whose `folderId` is the Trash sentinel finds no matching folder and returns nil, same as before.

- [ ] **Step 3: DRY `folderForTerminalPath(_:)` onto the shared predicate**

In `folderForTerminalPath(_:)` (~lines 499–513), replace the inline path-note lookup:

```swift
            guard let pathNote = tabs.first(where: { n in
                n.folderId == folder.id && n.title.lowercased().contains("terminal path")
            }) else { continue }
```

with:

```swift
            guard let pathNote = terminalPathNote(in: folder.id) else { continue }
```

Behavior is unchanged: the chip's path still maps to the folder that directly owns the path note (the routing root, per the spec's top-most-wins rule).

- [ ] **Step 4: Build**

Run: `./build.sh`
Expected: exits 0, ends with the app deployed to `/Applications/FloatNote.app`.

- [ ] **Step 5: Commit**

```bash
git add FloatNote/FloatNote/App.swift
git commit -m "feat: terminal route walks folder ancestors (top-most terminal path note wins)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Subtree-aware reverse navigation (chip → note)

**Files:**
- Modify: `FloatNote/FloatNote/App.swift` — `noteToActivate(forTerminalFolder:)` (~line 517), `switchTab(_:)` bookkeeping (~line 1189).

**Interfaces:**
- Consumes: `terminalRouteFolder(startingAt:)` from Task 1; existing `isSelfOrDescendant(_:of:)` (~line 999) and `lastActiveNotePerFolder: [UUID: UUID]` (~line 448).
- Produces: no new API; behavior change only.

- [ ] **Step 1: Record subtree notes under the route root in `switchTab`**

In `switchTab(_:)`, replace (~lines 1189–1191):

```swift
        if let fid = newTab.folderId, fid != TRASH_FOLDER_ID {
            lastActiveNotePerFolder[fid] = newTab.id
        }
```

with:

```swift
        if let fid = newTab.folderId, fid != TRASH_FOLDER_ID {
            lastActiveNotePerFolder[fid] = newTab.id
            // Also remember the note under its terminal-route root, so tapping
            // that terminal's chip returns to subtree notes, not just notes in
            // the root folder itself.
            if let routeRoot = terminalRouteFolder(startingAt: fid), routeRoot.id != fid {
                lastActiveNotePerFolder[routeRoot.id] = newTab.id
            }
        }
```

- [ ] **Step 2: Accept subtree notes in `noteToActivate(forTerminalFolder:)`**

Replace the whole function (~lines 515–524):

```swift
    /// The note to land on when entering `folder` via its terminal: the last note
    /// the user had open anywhere in the folder's subtree, else the folder's own
    /// first non-"terminal path" note.
    private func noteToActivate(forTerminalFolder folder: Folder) -> NoteTab? {
        if let lastId = lastActiveNotePerFolder[folder.id],
           let last = tabs.first(where: { $0.id == lastId }),
           let lastFolderId = last.folderId,
           lastFolderId != TRASH_FOLDER_ID,
           isSelfOrDescendant(lastFolderId, of: folder.id) {
            return last
        }
        return tabs.first(where: { $0.folderId == folder.id
            && !$0.title.lowercased().contains("terminal path") })
    }
```

(The `TRASH_FOLDER_ID` check keeps a since-trashed remembered note from being activated; `isSelfOrDescendant` covers "in the owning folder or any descendant".)

- [ ] **Step 3: Build**

Run: `./build.sh`
Expected: exits 0.

- [ ] **Step 4: Commit**

```bash
git add FloatNote/FloatNote/App.swift
git commit -m "feat: terminal chip-tap returns to last note anywhere in the route subtree

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Version bump, docs, manual verification

**Files:**
- Modify: `FloatNote/FloatNote/App.swift:19` (`APP_VERSION`), `CLAUDE.md` (Terminal section, two bullets).

- [ ] **Step 1: Bump version**

In `App.swift` line 19: `let APP_VERSION = "v1.36.1"` → `let APP_VERSION = "v1.37.0"`.

- [ ] **Step 2: Update CLAUDE.md Terminal bullets**

In the **Folder-routed switching (note → terminal)** bullet, replace the sentence:

> `vm.terminalRoute(for:)` maps the active note → its folder's "terminal path" note (a note in the same folder whose title contains "terminal path", case-insensitive) → first non-empty line of that note's plain-text body, `~`-expanded. **Direct folder only — no ancestor walk.**

with:

> `vm.terminalRoute(for:)` maps the active note → the **top-most ancestor folder** (own folder included; `terminalRouteFolder(startingAt:)`, trashed folders skipped, 64-hop cycle cap) that has a "terminal path" note (title contains "terminal path", case-insensitive) → first non-empty line of that note's plain-text body, `~`-expanded; the chip label is that top-most folder's name. Subfolder notes therefore inherit the parent's terminal; a nearer folder's own path note is ignored (top-most wins). Spec: `docs/superpowers/specs/2026-07-07-terminal-route-ancestor-walk-design.md`.

In the **Reverse routing (terminal → note)** bullet, replace:

> `noteToActivate(forTerminalFolder:)` picks the last note the user had open there (`lastActiveNotePerFolder`, updated in `switchTab`), falling back to the folder's first non-"terminal path" note.

with:

> `noteToActivate(forTerminalFolder:)` picks the last note the user had open **anywhere in that folder's subtree** (`lastActiveNotePerFolder` — `switchTab` records subtree notes under the route root too), falling back to the folder's own first non-"terminal path" note.

- [ ] **Step 3: Build & deploy**

Run: `./build.sh`
Expected: exits 0, app updated in `/Applications`.

- [ ] **Step 4: Manual verification (spec test list)**

With the deployed app (folder `agentforce` containing `agentforce terminal path` + subfolder `toplantı notları`):

1. Open a note directly in `agentforce` → `agentforce` terminal opens (regression).
2. Open a note in `toplantı notları` → the same `agentforce` terminal opens/stays; chip label `agentforce`; panel does NOT hide.
3. Temporarily add a "terminal path" note inside `toplantı notları` with a different path → subtree notes still route to the `agentforce` terminal (top-most wins). Remove it after.
4. While on a `toplantı notları` note, switch to an unrelated no-route note (panel hides), then tap/open the `agentforce` terminal chip → lands back on that `toplantı notları` note.
5. Fresh state (restart app), tap the chip without visiting subtree notes → lands on the owning folder's first non-"terminal path" note.
6. Open a note in a folder tree with no "terminal path" note anywhere → panel hides.
7. Loose-trash `agentforce terminal path` → subtree notes stop routing (panel hides); restore it → routing returns.

Expected: all 7 pass. Fix and re-run `./build.sh` if any fail.

- [ ] **Step 5: Commit**

```bash
git add FloatNote/FloatNote/App.swift CLAUDE.md
git commit -m "docs: ancestor-walk terminal routing in CLAUDE.md; bump v1.37.0

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
