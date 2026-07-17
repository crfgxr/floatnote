# Terminal Toggle Route Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate the FloatNote toolbar terminal toggle by route — disable it on notes with no terminal route, and make its show-path always re-apply the active note's *own* route instead of revealing whatever tab was last active, so the toggle can never surface a different project's live session.

**Architecture:** Two small, self-contained edits to the existing `EditorViewModel`/`FormatToolbar` machinery in `App.swift` (no new types, no new files): (1) rewire `toggleTerminal()`'s show branch onto the already-existing `applyTerminalRouteForActiveNote()`, delete the now-dead `showTerminal()` HOME-fallback, and fix `togglePin()`'s one other caller of it; (2) gate the toolbar's `terminalButton` on `vm.terminalRoute(for: vm.activeTab) != nil`, following the file's existing `let x = ...; return Button(...)` stateful-button convention (see `boardButton`). Docs (`CLAUDE.md`) and `APP_VERSION` follow.

**Tech Stack:** Swift 5 / SwiftUI, SPM (macOS 14+), no test target.

## Global Constraints

- Toolbar terminal button is disabled/grayed with tooltip `Link a folder to use the terminal` exactly when `vm.terminalRoute(for: vm.activeTab) == nil`.
- `EditorViewModel.toggleTerminal()`: hide branch (`hideTerminal()`) is unchanged; show branch calls `applyTerminalRouteForActiveNote()` instead of `showTerminal()`.
- `showTerminal()`'s create-a-HOME-tab-when-empty branch is removed entirely; the function is deleted once it has zero remaining callers (verified below — it has exactly one other caller, in `togglePin()`, which this plan also fixes).
- No changes to `TerminalSessions`, `TerminalSession`, `effectiveRoute`/`terminalRoute` resolution, chips, close/exit paths, hide≠kill, or focus rules beyond the toggle's (and `togglePin`'s) show path.
- No test target exists; do not add one. Verification is `./build.sh` (never bare `swift build` — the app bundle in `/Applications` must be updated too) plus a manual GUI checklist (Task 2, final section).
- `DesignTokens.swift` and `mcp-server.js` are dirty with unrelated work and must NOT be touched by this feature at all. The disabled-button state uses plain inline SwiftUI styling (`Color.secondary.opacity(0.4)`, `.disabled(...)`), matching the file's own existing ad-hoc disabled-button convention (the Transcript/Summary recording buttons) — no new design tokens.
- Bump `APP_VERSION` from `"v1.50.0"` to `"v1.51.0"` in `App.swift`.
- CLAUDE.md **Tab system** bullet (Terminal section): drop `(or HOME)` from `` `+` adds a tab at the active note's route (or HOME) ``. Append one new bullet at the end of the Terminal section referencing `docs/superpowers/specs/2026-07-17-terminal-toggle-route-gate-design.md`.
- Commit message format: subject line, blank line, `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Git hygiene invariant (both tasks):** `FloatNote/FloatNote/App.swift` and `CLAUDE.md` each carry dozens of unrelated uncommitted edits already in the working tree (do not touch `DesignTokens.swift` / `mcp-server.js` — they are dirty too but out of scope). Before every commit, `git diff --cached <file>` must show **exactly and only** this feature's changes. After every commit, `git status` must still list all four files (`App.swift`, `CLAUDE.md`, `DesignTokens.swift`, `mcp-server.js`) as modified.

### Why hand-written patches, not `git add -p`

Investigation (done during planning, against the branch's current HEAD) found:
- `App.swift` has ~70 unrelated dirty hunks. Driving `git add -p` non-interactively via piped `y`/`n`/`s` answers would require correctly counting through all of them — fragile and not verifiable in advance.
- Worse: this feature's `showTerminal()` deletion sits *directly adjacent*, with zero separating context line, to an unrelated already-dirty hunk that inserted `focusActiveTerminal()`/`focusTerminal()`/`focusEditor()` right after it. `git add -p`'s `s` (split) cannot separate a hunk when there's no unchanged line between two changes — only whole-hunk stage/skip, or `e` (manual edit), which needs an interactive editor we don't have without a TTY.
- However, deleting `showTerminal()` **as it exists in the committed HEAD** (7 lines, no `focusActiveTerminal()` call — that call was added later, uncommitted, and disappears along with the rest of the function when it's deleted) is a clean, self-contained edit against HEAD. The other three target regions (`toggleTerminal()`, `togglePin()`'s restore branch, `terminalButton`) were confirmed (via `git diff -U0` hunk-range inspection) to be **completely untouched** by any other dirty hunk.

So: for both files, this plan uses the deterministic fallback uniformly — `git reset <file>` (defensive; nothing is staged yet) → apply a hand-written unified diff (computed against HEAD, with exact `@@` line numbers verified below) via `git apply --cached` → verify `git diff --cached <file>` matches the expected shape exactly → commit. This is more reliable here than mixing interactive splitting for some hunks with hand-patching for others.

---

### Task 1: `EditorViewModel` route-gate rewire + toolbar disabled state (`App.swift`)

**Files:**
- Modify: `FloatNote/FloatNote/App.swift`
  - `EditorViewModel.showTerminal()` (deleted, current lines 499–508)
  - `EditorViewModel.toggleTerminal()` (current line 544)
  - `EditorViewModel.togglePin()` restore branch (current lines 1624–1632)
  - `FormatToolbar.terminalButton` (current lines 3992–4008)

**Interfaces:**
- Consumes (pre-existing, unchanged): `EditorViewModel.terminalRoute(for tab: NoteTab?) -> (path: String, label: String)?`; `EditorViewModel.applyTerminalRouteForActiveNote(focusTerminal: Bool = true)`; `EditorViewModel.activeTab: NoteTab?`; `EditorViewModel.isTerminalVisible: Bool`; `EditorViewModel.hideTerminal()`.
- Produces: `EditorViewModel.toggleTerminal()` (show branch now calls `applyTerminalRouteForActiveNote()`); `EditorViewModel.showTerminal()` **removed** (no later task or file references it); `FormatToolbar.terminalButton` gated on a local `hasRoute: Bool`.

- [ ] **Step 1: Confirm no drift — re-verify each target region's dirty-overlap status before editing**

Run these from the repo root (`/Users/cagdas.agirtas/CodTemp/floatnote`):

```bash
git show HEAD:FloatNote/FloatNote/App.swift > /tmp/head_App.swift
git diff -U0 FloatNote/FloatNote/App.swift > /tmp/appswift_u0.diff
grep -n "^@@" /tmp/appswift_u0.diff
grep -n "func showTerminal\|func toggleTerminal\|showTerminal()\|private var terminalButton\|func togglePin" FloatNote/FloatNote/App.swift
```

Expected (as of this plan's writing — re-check if the file has moved since):
- `func showTerminal()` at line 500, its two call sites at line 544 (`toggleTerminal`) and line 1630 (`togglePin`), `private var terminalButton` at line 3992. `func togglePin()` starts a few lines before 1630 (search for it if line numbers drifted).
- Cross-reference the `@@ -OLD,oldcount +NEW,newcount @@` headers: `showTerminal()`'s region (current ~499–541, i.e. HEAD lines ~472–511) falls inside the hunk `@@ -479,0 +507,34 @@` (an unrelated addition of `focusActiveTerminal()`/`focusTerminal()`/`focusEditor()` right after `showTerminal()`) — this is the one entangled region, handled by hand-patching HEAD's original (smaller) `showTerminal()` in Step 5. `toggleTerminal()` (line 544 / HEAD 483), `togglePin()`'s restore branch (lines 1624–1632 / HEAD 1448–1456), and `terminalButton` (lines 3992–4008 / HEAD 3716–3732) each fall in gaps between hunks — confirm no `@@` header's new-range `[NEW, NEW+newcount-1]` contains those line numbers. If any of them now DO overlap a hunk (i.e. the file changed since this plan was written), stop and recompute the corresponding patch hunk in Step 5 against the new HEAD content before proceeding — do not hand-apply a patch whose context no longer matches HEAD.

- [ ] **Step 2: Delete `showTerminal()` and rewire `toggleTerminal()`**

In `FloatNote/FloatNote/App.swift`, find:

```swift
    /// Show the panel, creating a HOME-rooted tab only if none exist.
    func showTerminal() {
        if terminalTabs.isEmpty {
            let id = UUID()
            terminalTabs.append(TerminalTab(id: id, path: NSHomeDirectory(), label: "terminal"))
            activeTerminalId = id
        }
        isTerminalVisible = true
        focusActiveTerminal()
    }
    /// Hide the panel but keep all sessions mounted/alive (hide ≠ kill).
    func hideTerminal() { isTerminalVisible = false }
```

Replace with:

```swift
    /// Hide the panel but keep all sessions mounted/alive (hide ≠ kill).
    func hideTerminal() { isTerminalVisible = false }
```

Then find:

```swift
    func toggleTerminal() { isTerminalVisible ? hideTerminal() : showTerminal() }
```

Replace with:

```swift
    func toggleTerminal() { isTerminalVisible ? hideTerminal() : applyTerminalRouteForActiveNote() }
```

- [ ] **Step 3: Fix `togglePin()`'s other `showTerminal()` call**

`showTerminal()` has one more caller — `togglePin()`'s unpin restore logic — which the spec doesn't mention explicitly but which must change too: it's the only other place that could resurrect a HOME tab, and after Step 2 it's the only remaining reference to `showTerminal()` (verify with `grep -n "showTerminal()" FloatNote/FloatNote/App.swift` — it must return zero matches after this step).

Find:

```swift
            if prePinTerminalVisible == true {
                // Prefer the current note's route (the note may have changed
                // while pinned); fall back to re-showing the manual terminal.
                if terminalRoute(for: activeTab) != nil {
                    applyTerminalRouteForActiveNote()
                } else {
                    showTerminal()
                }
            }
```

Replace with:

```swift
            if prePinTerminalVisible == true {
                // Re-apply the active note's route; a routeless note simply
                // stays hidden (no HOME-fallback terminal — see toggleTerminal()).
                applyTerminalRouteForActiveNote()
            }
```

(`applyTerminalRouteForActiveNote()` already does exactly what the old `if/else` did by hand: route → `switchToRoute` + focus; no route → `hideTerminal()`, which is a no-op here since the panel is already hidden while pinned.)

- [ ] **Step 4: Verify `showTerminal()` has zero remaining references**

```bash
grep -n "showTerminal" FloatNote/FloatNote/App.swift
```

Expected: no output (the function and both call sites are gone).

- [ ] **Step 5: Gate `terminalButton` on the active note's route**

In `FloatNote/FloatNote/App.swift`, find the `terminalButton` computed property:

```swift
    private var terminalButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) { vm.toggleTerminal() }
        }) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .frame(width: 26, height: 22)
                .foregroundColor(vm.isTerminalVisible ? .accentColor : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hoveredButton == "terminal" ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hoveredButton = $0 ? "terminal" : nil }
        .help(vm.isTerminalVisible ? "Hide terminal" : "Show terminal")
    }
```

Replace with (follows the same `let x = ...; return Button(...)` pattern already used by `boardButton` a few lines above it, and the same `.foregroundColor(cond ? .secondary : .accentColor)` + `.disabled(...)` + `.help(...)` convention already used by the Transcript/Summary recording buttons elsewhere in this file — no new design tokens):

```swift
    private var terminalButton: some View {
        let hasRoute = vm.terminalRoute(for: vm.activeTab) != nil
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) { vm.toggleTerminal() }
        }) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .frame(width: 26, height: 22)
                .foregroundColor(hasRoute ? (vm.isTerminalVisible ? .accentColor : .secondary) : Color.secondary.opacity(0.4))
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hoveredButton == "terminal" ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(!hasRoute)
        .onHover { hoveredButton = $0 ? "terminal" : nil }
        .help(hasRoute ? (vm.isTerminalVisible ? "Hide terminal" : "Show terminal") : "Link a folder to use the terminal")
    }
```

- [ ] **Step 6: Build and deploy**

```bash
./build.sh
```

Expected: exit code 0, last line of output is exactly `Done — app updated and launched.` If it fails, fix the compile error (most likely a typo in one of the edits above) and re-run — do not proceed to staging/committing until this passes.

- [ ] **Step 7: Write the hand-crafted patch for `App.swift`**

Write this exact unified diff to `/tmp/2026-07-17-terminal-toggle-appswift.patch` (all three hunks were computed against `HEAD:FloatNote/FloatNote/App.swift` during planning AND round-trip-verified — `git apply --check --cached`, `git apply --cached`, `git diff --cached` showed exactly these three hunks, then `git reset` restored the original state — so this patch is known-good as of this plan's writing. Re-verify the context text still matches your `/tmp/head_App.swift` from Step 1 before applying; if it drifted, recompute the `@@` header and surrounding context the same way: locate the exact HEAD lines for each edit, count context/added/removed lines, and set `old_start,old_count`/`new_start,new_count` accordingly):

```diff
diff --git a/FloatNote/FloatNote/App.swift b/FloatNote/FloatNote/App.swift
--- a/FloatNote/FloatNote/App.swift
+++ b/FloatNote/FloatNote/App.swift
@@ -469,18 +469,9 @@
         return max(0, windowContentWidth - sidebar - 10)
     }
 
-    /// Show the panel, creating a HOME-rooted tab only if none exist.
-    func showTerminal() {
-        if terminalTabs.isEmpty {
-            let id = UUID()
-            terminalTabs.append(TerminalTab(id: id, path: NSHomeDirectory(), label: "terminal"))
-            activeTerminalId = id
-        }
-        isTerminalVisible = true
-    }
     /// Hide the panel but keep all sessions mounted/alive (hide ≠ kill).
     func hideTerminal() { isTerminalVisible = false }
-    func toggleTerminal() { isTerminalVisible ? hideTerminal() : showTerminal() }
+    func toggleTerminal() { isTerminalVisible ? hideTerminal() : applyTerminalRouteForActiveNote() }
 
     /// Activate the tab for `path` if one exists, else create it. Opens the panel.
     func switchToRoute(path: String, label: String) {
@@ -1446,13 +1437,9 @@
             prePinWindowFrame = nil
             if let collapsed = prePinSidebarCollapsed { isSidebarCollapsed = collapsed }
             if prePinTerminalVisible == true {
-                // Prefer the current note's route (the note may have changed
-                // while pinned); fall back to re-showing the manual terminal.
-                if terminalRoute(for: activeTab) != nil {
-                    applyTerminalRouteForActiveNote()
-                } else {
-                    showTerminal()
-                }
+                // Re-apply the active note's route; a routeless note simply
+                // stays hidden (no HOME-fallback terminal — see toggleTerminal()).
+                applyTerminalRouteForActiveNote()
             }
             prePinSidebarCollapsed = nil
             prePinTerminalVisible = nil
@@ -3716,17 +3703,19 @@
     private var terminalButton: some View {
-        Button(action: {
+        let hasRoute = vm.terminalRoute(for: vm.activeTab) != nil
+        return Button(action: {
             withAnimation(.easeInOut(duration: 0.18)) { vm.toggleTerminal() }
         }) {
             Image(systemName: "terminal")
                 .font(.system(size: 11))
                 .frame(width: 26, height: 22)
-                .foregroundColor(vm.isTerminalVisible ? .accentColor : .secondary)
+                .foregroundColor(hasRoute ? (vm.isTerminalVisible ? .accentColor : .secondary) : Color.secondary.opacity(0.4))
                 .background(
                     RoundedRectangle(cornerRadius: 3)
                         .fill(hoveredButton == "terminal" ? Color.primary.opacity(0.08) : Color.clear)
                 )
         }
         .buttonStyle(.plain)
+        .disabled(!hasRoute)
         .onHover { hoveredButton = $0 ? "terminal" : nil }
-        .help(vm.isTerminalVisible ? "Hide terminal" : "Show terminal")
+        .help(hasRoute ? (vm.isTerminalVisible ? "Hide terminal" : "Show terminal") : "Link a folder to use the terminal")
     }
```

- [ ] **Step 8: Stage only this feature's hunks**

```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote
git reset FloatNote/FloatNote/App.swift
git apply --check --cached /tmp/2026-07-17-terminal-toggle-appswift.patch
git apply --cached /tmp/2026-07-17-terminal-toggle-appswift.patch
```

If `--check` fails with a context mismatch, the file drifted since planning — go back to Step 1, re-locate the exact HEAD text for whichever hunk failed, and rewrite that hunk's header/context before retrying. Do not force-apply a mismatched hunk.

- [ ] **Step 9: Verify the staged diff is exactly this feature's change — nothing else**

```bash
git diff --cached FloatNote/FloatNote/App.swift
```

Expected shape: exactly three hunks —
1. `showTerminal()`'s doc-comment + 9-line body deleted, plus the `toggleTerminal()` one-line change (`showTerminal()` → `applyTerminalRouteForActiveNote()`).
2. `togglePin()`'s restore `if/else` (7 lines) collapsed to a comment + single `applyTerminalRouteForActiveNote()` call (2 lines).
3. `terminalButton`: `let hasRoute = ...` + `return Button` (was bare `Button`), the `.foregroundColor`/`.help` ternaries extended with the `hasRoute` gate, and a new `.disabled(!hasRoute)` line.

No other hunk (no unrelated `focusActiveTerminal()`, `effectiveRoute`, `nearestLinkedFolder`, sidebar, recording, or editor changes) should appear in this output.

- [ ] **Step 10: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat: gate terminal toggle by the active note's route

Terminals are project-scoped: the toolbar toggle is now disabled on
routeless notes, and its show path re-applies the active note's own
route instead of revealing whatever tab was last active, so it can
never drop the user into a different project's live session. The
HOME-fallback terminal (showTerminal()) is retired.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 11: Verify `git status` still shows all four dirty files**

```bash
git status --short
```

Expected: `App.swift` still shows ` M` (this commit only took three of its ~70+ dirty hunks — the rest remain unstaged), and `CLAUDE.md`, `FloatNote/FloatNote/DesignTokens.swift`, `mcp-server.js` are all still listed as modified, untouched by this task.

---

### Task 2: `APP_VERSION` bump, `CLAUDE.md` docs, build, and human verification

**Files:**
- Modify: `FloatNote/FloatNote/App.swift:19` (`APP_VERSION`)
- Modify: `CLAUDE.md` (Terminal section)

**Interfaces:**
- Consumes: Task 1's finished, committed `toggleTerminal()`/`terminalButton` behavior (this task only touches the version string and docs — no further Swift logic changes).
- Produces: nothing consumed by later tasks — this is the plan's last task.

- [ ] **Step 1: Bump `APP_VERSION`**

In `FloatNote/FloatNote/App.swift`, find:

```swift
let APP_VERSION = "v1.50.0"
```

Replace with:

```swift
let APP_VERSION = "v1.51.0"
```

- [ ] **Step 2: Update the CLAUDE.md Terminal section**

In `CLAUDE.md`, find (inside the **Tab system** bullet):

```
`+` adds a tab at the active note's route (or HOME), ✕ closes one
```

Replace with:

```
`+` adds a tab at the active note's route, ✕ closes one
```

Then find the last bullet of the **Terminal** section:

```
- **Claude auto-resume**: routed terminals auto-run `claude --continue` when `~/.claude/projects/<munged-cwd>` has session files; HOME and first-open projects run plain `claude`; a shell restart (`.floatnoteTerminalReset` — mechanism only, no UI trigger posts it yet) re-evaluates. Decision lives in `TerminalSession.claudeLaunchCommand` (`Terminal.swift`), computed at send time inside the existing 0.6s auto-run. Spec: `docs/superpowers/specs/2026-07-17-terminal-claude-auto-resume-design.md`.
```

Append immediately after it (same section, new bullet, before the `## Folders & Trash` heading):

```
- **Terminal toggle is route-gated**: terminals are project-scoped — the toolbar terminal button is disabled (grayed, tooltip "Link a folder to use the terminal") when the active note has no route (`vm.terminalRoute(for: activeTab) == nil`), and its show path re-applies the active note's own route (`applyTerminalRouteForActiveNote()`) instead of revealing whatever tab was last active, so the toggle can never surface a different project's session. The HOME-fallback terminal is retired — `showTerminal()` is gone; `claudeLaunchCommand`'s `dir == home` branch (auto-resume spec) remains only as an unreachable safety net. Spec: `docs/superpowers/specs/2026-07-17-terminal-toggle-route-gate-design.md`.
```

- [ ] **Step 3: Build and deploy**

```bash
./build.sh
```

Expected: exit code 0, last line of output is exactly `Done — app updated and launched.`

- [ ] **Step 4: Write the hand-crafted patch for `App.swift`'s version line**

Write to `/tmp/2026-07-17-terminal-toggle-version.patch`:

```diff
diff --git a/FloatNote/FloatNote/App.swift b/FloatNote/FloatNote/App.swift
--- a/FloatNote/FloatNote/App.swift
+++ b/FloatNote/FloatNote/App.swift
@@ -16,7 +16,7 @@
     }
 }
 
-let APP_VERSION = "v1.50.0"
+let APP_VERSION = "v1.51.0"
 let LOCAL_SAVE_PATH = NSHomeDirectory() + "/.floatnote-local.html"
 let LOCAL_TABS_PATH = NSHomeDirectory() + "/.floatnote-tabs.json"
 let LOCAL_FOLDERS_PATH = NSHomeDirectory() + "/.floatnote-folders.json"
```

(This region — lines 1–23 of `App.swift` — is clean/untouched by any other dirty hunk: the first pre-existing dirty hunk in the file starts at line 67. Re-confirm with `grep -n "^@@" /tmp/appswift_u0.diff | head -1` if re-running Step 1's investigation from Task 1.)

- [ ] **Step 5: Write the hand-crafted patch for `CLAUDE.md`**

Write to `/tmp/2026-07-17-terminal-toggle-claudemd.patch`:

```diff
diff --git a/CLAUDE.md b/CLAUDE.md
--- a/CLAUDE.md
+++ b/CLAUDE.md
@@ -40,3 +40,3 @@
 - Shell lifecycle is owned by `TerminalSessions` (in `Terminal.swift`), NOT the SwiftUI view. A `TerminalSession` (LocalProcessTerminalView + child shell, started in a per-session `cwd`) is created lazily per terminal id via `session(for:cwd:)` and lives until `TerminalSessions.shared.close(id)` (called from `vm.closeTerminal`, i.e. the ✕ button). Use `existing(_:)` for a non-creating lookup. The shell's working directory is fixed at creation; `cwd` is ignored for an already-live session.
-- **Tab system (one visible at a time)**: the panel is a tab bar (`TerminalPanel`) over `vm.terminalTabs: [TerminalTab]` (`{id, path, label}`) with `vm.activeTerminalId` selecting the visible one. Each chip is labelled by folder name, path on hover; `+` adds a tab at the active note's route (or HOME), ✕ closes one (activates a neighbor; last close hides the panel). There are no side-by-side columns and no per-column widths — `terminalWidth` is the single panel width.
+- **Tab system (one visible at a time)**: the panel is a tab bar (`TerminalPanel`) over `vm.terminalTabs: [TerminalTab]` (`{id, path, label}`) with `vm.activeTerminalId` selecting the visible one. Each chip is labelled by folder name, path on hover; `+` adds a tab at the active note's route, ✕ closes one (activates a neighbor; last close hides the panel). There are no side-by-side columns and no per-column widths — `terminalWidth` is the single panel width.
 - **Folder-routed switching (note → terminal)**: `vm.terminalRoute(for:)` maps the active note → the **top-most ancestor folder** (own folder included; `terminalRouteFolder(startingAt:)`, trashed folders skipped, 64-hop cycle cap) that has a "terminal path" note (title contains "terminal path", case-insensitive) → first non-empty line of that note's plain-text body, `~`-expanded; the chip label is that top-most folder's name. Subfolder notes therefore inherit the parent's terminal; a nearer folder's own path note is ignored (top-most wins). Spec: `docs/superpowers/specs/2026-07-07-terminal-route-ancestor-walk-design.md`. `vm.applyTerminalRouteForActiveNote()` runs on every `activeTabId` change (`switchTab`, `addTab`, launch `loadTabs`): a route → `switchToRoute(path:label:)` which dedups by path (switch to the existing tab for that path, else create one) and auto-opens the panel; no route → hide the panel. Spec: `docs/superpowers/specs/2026-06-18-folder-routed-terminal-tabs-design.md`.
@@ -46,6 +46,7 @@
 - **Terminal-scoped shortcuts**: a local `NSEvent` key monitor in `AppDelegate` intercepts Cmd+N (new terminal) and Shift+Enter/Cmd+Enter (newline without submit) ONLY when `TerminalSessions.shared.id(containing: firstResponder)` matches; otherwise they keep default behavior. Cmd+W is swallowed app-wide (returns nil for every Cmd+W, regardless of focus) — it must never close the window, which would take the terminal panel with it; terminal tabs close only via the ✕ button or `exit`.
 - **`exit` closes the pane**: `processTerminated` posts `.floatnoteTerminalExited` (object = session UUID), observed in `AppDelegate` → `vm.closeTerminal`. Intentional kills (restart / ✕) set `expectedTermination` on the session first so they don't self-close — keep that guard if you add new kill paths.
 - **Claude auto-resume**: routed terminals auto-run `claude --continue` when `~/.claude/projects/<munged-cwd>` has session files; HOME and first-open projects run plain `claude`; a shell restart (`.floatnoteTerminalReset` — mechanism only, no UI trigger posts it yet) re-evaluates. Decision lives in `TerminalSession.claudeLaunchCommand` (`Terminal.swift`), computed at send time inside the existing 0.6s auto-run. Spec: `docs/superpowers/specs/2026-07-17-terminal-claude-auto-resume-design.md`.
+- **Terminal toggle is route-gated**: terminals are project-scoped — the toolbar terminal button is disabled (grayed, tooltip "Link a folder to use the terminal") when the active note has no route (`vm.terminalRoute(for: activeTab) == nil`), and its show path re-applies the active note's own route (`applyTerminalRouteForActiveNote()`) instead of revealing whatever tab was last active, so the toggle can never surface a different project's session. The HOME-fallback terminal is retired — `showTerminal()` is gone; `claudeLaunchCommand`'s `dir == home` branch (auto-resume spec) remains only as an unreachable safety net. Spec: `docs/superpowers/specs/2026-07-17-terminal-toggle-route-gate-design.md`.
 
 ## Folders & Trash
 - Folders live in `~/.floatnote-folders.json`: `{id, name, isExpanded, isTrashed?, parentId?}`
```

Both hunks target the **Terminal** section of `CLAUDE.md`. The first hunk's context lines (`- Shell lifecycle...`, `- **Folder-routed switching**...`) are HEAD's *original* text — those bullets were separately rewritten (to "Project folders"/"Reverse routing"/etc.) by unrelated uncommitted work, but since our hunk only *modifies* the Tab-system line and uses the surrounding lines purely as unchanged context matched against the INDEX (which still holds HEAD's original text — nothing is staged for `CLAUDE.md` yet either), this applies cleanly and leaves the unrelated rewrites exactly as dirty/uncommitted as they were.

Both patches (this one and Step 4's) were round-trip-verified the same way during planning (`git apply --check --cached`, `git apply --cached`, `git diff --cached`, `git reset`) — note the closing context line `` - Folders live in `~/.floatnote-folders.json`: `{id, name, isExpanded, isTrashed?, parentId?}` `` needs its backtick-wrapped code span exactly as shown, or the context match fails.

- [ ] **Step 6: Stage only this feature's hunks in both files**

```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote
git reset FloatNote/FloatNote/App.swift CLAUDE.md
git apply --check --cached /tmp/2026-07-17-terminal-toggle-version.patch
git apply --check --cached /tmp/2026-07-17-terminal-toggle-claudemd.patch
git apply --cached /tmp/2026-07-17-terminal-toggle-version.patch
git apply --cached /tmp/2026-07-17-terminal-toggle-claudemd.patch
```

If either `--check` fails, re-derive that hunk's context/line numbers from the current `HEAD:CLAUDE.md` / `HEAD:App.swift` before applying — do not force through a mismatch.

- [ ] **Step 7: Verify the staged diff in both files is exactly this feature's change**

```bash
git diff --cached FloatNote/FloatNote/App.swift
git diff --cached CLAUDE.md
```

Expected: `App.swift`'s staged diff is exactly the one-line `APP_VERSION` change. `CLAUDE.md`'s staged diff is exactly the `(or HOME)` removal plus the one new appended bullet — no other Terminal-section rewrites (Project folders, Reverse routing, Focus follows the terminal, etc.) or any other section's edits appear.

- [ ] **Step 8: Commit**

```bash
git commit -m "$(cat <<'EOF'
docs: terminal toggle route-gate; bump v1.51.0

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 9: Verify `git status` still shows all four dirty files**

```bash
git status --short
```

Expected: `App.swift` and `CLAUDE.md` still ` M` (each has more unstaged hunks left over from unrelated work), `FloatNote/FloatNote/DesignTokens.swift` and `mcp-server.js` still ` M`, untouched by either task.

- [ ] **Step 10: Human verification checklist**

This feature has no automated test target, and the GUI interactions below cannot be driven by an agent — a human must perform them against the freshly built `/Applications/FloatNote.app`. Check each one explicitly:

1. **Routeless note → button grayed, click does nothing.**
   - Create a brand-new note at the sidebar root (no folder, no project ancestor) — or open any existing note that lives outside every linked project folder and has no folder-chip override.
   - Confirm the toolbar's terminal icon (`terminal` SF Symbol) renders visibly dimmer/grayed compared to its normal `.secondary` tint, and hovering shows the tooltip **"Link a folder to use the terminal"**.
   - Click it. Confirm nothing happens: no panel appears, `isTerminalVisible` stays false (no terminal chip bar shows up at the bottom/side of the window).

2. **Routed note → toggle works and always lands on that note's own project tab.**
   - Switch to the note titled exactly **💡floatnote ideas** (in the **floatnote** project folder — confirm via the sidebar that this folder shows a 🔗 linked-path indicator).
   - Confirm the terminal button is NOT grayed (normal `.secondary`/`.accentColor` tint) and its tooltip reads **"Show terminal"** (or **"Hide terminal"** if already open).
   - Click it: the panel opens, and the active terminal chip's tab is the **floatnote** project's tab (label = folder name, hover shows the linked path) — not some other project's tab.
   - While the panel is open, click a *different* project's chip (if another linked folder/terminal tab exists) to switch away, then click the toolbar toggle to hide the panel, then click it again to show: confirm it snaps back to the **floatnote ideas** note's own project tab, not the foreign chip you'd switched to. This is the toggle's route-snap behavior — the deliberate exception is that chip-clicking itself still free-navigates, but the *toggle* always returns to the active note's own route.

3. **Close-all-tabs-then-toggle on a routed note recreates the project tab, not a HOME tab.**
   - On the **💡floatnote ideas** note with the panel open, close every terminal tab via each tab's ✕ (the last close should auto-hide the panel).
   - Click the toolbar toggle to show the panel again. Confirm a **new tab for the floatnote project** is created (label = "floatnote", correct linked path on hover) — NOT a tab labeled "terminal" rooted at your home directory (`~`). There must be no way to end up on a bare HOME shell from this note.

4. **Chip cross-switching still works.**
   - With the panel open and at least two project tabs present (e.g. floatnote + one other linked project), click between their chips. Confirm each click switches the visible terminal and — per the existing reverse-routing behavior — navigates the active note to that project's last-active note (unchanged behavior; this plan does not touch chip-tap routing, only the toolbar toggle's show-path and the button's enabled state).

Do not consider Task 2 complete until all four checklist items have been confirmed against the running app.
