# Folder-Routed Terminal Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the terminal panel a tab system whose active tab follows the working directory of the note you're reading, defined by a "terminal path" note inside each folder.

**Architecture:** Replace the side-by-side resizable terminal columns with a single-visible-terminal tab bar. A route resolver maps the active note → its folder's terminal-path note → a directory string. Navigation drives `applyTerminalRouteForActiveNote()`: a route auto-opens the panel and switches/creates that route's tab (dedup by path); no route hides the panel. Terminal sessions become cwd-parameterized.

**Tech Stack:** Swift, SwiftUI, AppKit, SwiftTerm. macOS 14+. No unit-test harness exists in this project — every task is verified by a clean `swift build` (compile gate) plus the described manual check after `./build.sh`.

## Global Constraints

- After ANY code change run `./build.sh` to rebuild and update `/Applications/FloatNote.app` — `swift build` alone is not sufficient for a finished task.
- Bump `APP_VERSION` at the top of `App.swift` once, in the final task.
- Spec: `docs/superpowers/specs/2026-06-18-folder-routed-terminal-tabs-design.md`.
- "hide ≠ kill": never terminate a shell on panel hide or view remount. Sessions die only via `TerminalSessions.shared.close(id)`.
- Direct folder only — never walk up the folder tree for a route.
- Route dedup key is the resolved path string.

---

## File Structure

- `FloatNote/FloatNote/Terminal.swift` — `TerminalSession`/`TerminalSessions` gain a `cwd` parameter; hardcoded `preferredCwd` removed.
- `FloatNote/FloatNote/App.swift` — terminal data model on `EditorViewModel` (replace columns with tabs), route resolver + navigation hook, `TerminalPanel` UI rebuild, `TerminalResizeHandle` simplification, `EditorView` panel mounting, `AppDelegate` shortcuts/focus.

---

## Task 1: cwd-parameterized terminal sessions

**Files:**
- Modify: `FloatNote/FloatNote/Terminal.swift`

**Interfaces:**
- Produces: `TerminalSession.init(id: UUID, cwd: String)`, `TerminalSessions.session(for id: UUID, cwd: String) -> TerminalSession`. Existing call sites that pass no cwd must be updated by later tasks.

- [ ] **Step 1: Add a stored cwd to `TerminalSession` and use it in `startShell`**

In `Terminal.swift`, change the `TerminalSession` declaration to store a cwd and accept it in `init`:

```swift
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let id: UUID
    let cwd: String
    let view: LocalProcessTerminalView
```

```swift
    init(id: UUID, cwd: String) {
        self.id = id
        self.cwd = cwd
        self.view = LocalProcessTerminalView(frame: .zero)
        super.init()
```

(leave the rest of `init` unchanged)

- [ ] **Step 2: Replace the hardcoded `preferredCwd` with the session's cwd**

In `startShell()`, replace the block that computes `preferredCwd` / `cwdExists` / `cwd` with:

```swift
        let home = NSHomeDirectory()
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : home
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("HOME=\(home)")
        term.startProcess(
            executable: shell,
            args: ["-l"],
            environment: env,
            execName: "-\(NSString(string: shell).lastPathComponent)",
            currentDirectory: dir
        )
```

(`shell` is still computed just above as before; only the directory logic changes)

- [ ] **Step 3: Thread cwd through `TerminalSessions.session(for:)`**

```swift
    func session(for id: UUID, cwd: String) -> TerminalSession {
        if let existing = sessions[id] { return existing }
        let s = TerminalSession(id: id, cwd: cwd)
        sessions[id] = s
        return s
    }
```

- [ ] **Step 4: Fix the in-file caller in `SwiftTermContainer`**

`SwiftTermContainer` will now carry the cwd. Update it:

```swift
struct SwiftTermContainer: NSViewRepresentable {
    let id: UUID
    let cwd: String

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attachTerminal(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attachTerminal(to: nsView)
    }

    private func attachTerminal(to container: NSView) {
        let term = TerminalSessions.shared.session(for: id, cwd: cwd).view
        guard term.superview !== container else { return }
        term.removeFromSuperview()
        term.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(term)
        NSLayoutConstraint.activate([
            term.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            term.topAnchor.constraint(equalTo: container.topAnchor),
            term.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
```

- [ ] **Step 5: Build to confirm `Terminal.swift` compiles in isolation**

Run: `cd /Users/cagdas.agirtas/CodTemp/floatnote/FloatNote && swift build 2>&1 | tail -30`
Expected: compile errors ONLY in `App.swift` (old `terminalIds`, `width(for:)`, `SwiftTermContainer(id:)` without cwd, `session(for:)` without cwd). `Terminal.swift` itself must report no errors. These App.swift errors are resolved by Tasks 2–5; do not commit yet.

---

## Task 2: Terminal tab data model on the ViewModel

**Files:**
- Modify: `FloatNote/FloatNote/App.swift` (the `EditorViewModel` terminal section, ~lines 391–470)

**Interfaces:**
- Consumes: `TerminalSessions.shared.session(for:cwd:)`, `TerminalSessions.shared.close(_:)` from Task 1.
- Produces:
  - `struct TerminalTab: Identifiable { let id: UUID; let path: String; let label: String }`
  - `@Published var terminalTabs: [TerminalTab]`
  - `@Published var activeTerminalId: UUID?`
  - `func switchToRoute(path: String, label: String)`
  - `func addTerminal()` (now: new tab at current route or HOME)
  - `func closeTerminal(_ id: UUID)`
  - `func showTerminal()`, `func hideTerminal()`, `func toggleTerminal()`
  - retains `@Published var terminalWidth: CGFloat`, `@Published var isTerminalVisible: Bool`, `availablePanelWidth()`

- [ ] **Step 1: Define the `TerminalTab` model**

Add immediately above the `EditorViewModel` terminal properties (just before the `isTerminalVisible` declaration):

```swift
/// One terminal in the panel's tab bar. Identified for dedup by `path` (the
/// shell's working directory); `label` is the folder name shown on the chip.
struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    let path: String
    let label: String
}
```

- [ ] **Step 2: Replace the column properties with tab properties**

Delete the `terminalIds` declaration (the `@Published var terminalIds: [UUID] = ...` seeded from `fn.terminalVisible`) and the `terminalWidths` declaration plus `width(for:)`, `setWidth(_:for:)`, `totalTerminalWidth`, `static let minTerminalColumnWidth`, and `clampTerminalWidths()`. Keep `isTerminalVisible`, `terminalWidth`, `windowContentWidth`, `availablePanelWidth()`.

Add in their place:

```swift
    /// Terminals shown in the panel, one visible at a time via the tab bar.
    /// Sessions are kept alive across re-renders by `TerminalSessions`.
    @Published var terminalTabs: [TerminalTab] = []
    /// The currently visible terminal tab.
    @Published var activeTerminalId: UUID?

    /// Narrowest the panel may get (also the resize-handle minimum).
    static let minTerminalColumnWidth: CGFloat = 200
```

- [ ] **Step 3: Rewrite show/hide/toggle, route-switch, add, close**

Replace the old `showTerminal`/`hideTerminal`/`toggleTerminal`/`addTerminal`/`closeTerminal` block with:

```swift
    /// Show the panel (creating a HOME-rooted tab only if none exist).
    func showTerminal() {
        if terminalTabs.isEmpty {
            let id = UUID()
            terminalTabs.append(TerminalTab(id: id, path: NSHomeDirectory(), label: "terminal"))
            activeTerminalId = id
        }
        isTerminalVisible = true
    }
    /// Hide the panel but keep every session alive (hide ≠ kill).
    func hideTerminal() { isTerminalVisible = false }
    func toggleTerminal() { isTerminalVisible ? hideTerminal() : showTerminal() }

    /// Activate the tab for `path` if one exists, else create it. Opens the panel.
    func switchToRoute(path: String, label: String) {
        if let existing = terminalTabs.first(where: { $0.path == path }) {
            activeTerminalId = existing.id
        } else {
            let id = UUID()
            terminalTabs.append(TerminalTab(id: id, path: path, label: label))
            activeTerminalId = id
        }
        isTerminalVisible = true
    }

    /// Manual "+": a fresh tab at the active note's route, else HOME.
    func addTerminal() {
        let route = terminalRoute(for: activeTab)
        let id = UUID()
        let path = route?.path ?? NSHomeDirectory()
        let label = route?.label ?? "terminal"
        terminalTabs.append(TerminalTab(id: id, path: path, label: label))
        activeTerminalId = id
        isTerminalVisible = true
    }

    /// Close (kill) one terminal. Activates a neighbor; hides the panel if it was
    /// the last one.
    func closeTerminal(_ id: UUID) {
        TerminalSessions.shared.close(id)
        guard let idx = terminalTabs.firstIndex(where: { $0.id == id }) else { return }
        terminalTabs.remove(at: idx)
        if activeTerminalId == id {
            if terminalTabs.isEmpty {
                activeTerminalId = nil
            } else {
                activeTerminalId = terminalTabs[min(idx, terminalTabs.count - 1)].id
            }
        }
        if terminalTabs.isEmpty { isTerminalVisible = false }
    }
```

(`terminalRoute(for:)` is added in Task 3; this task will not compile until Task 3 lands — that's expected.)

- [ ] **Step 4: Note — defer build to Task 3**

This task references `terminalRoute(for:)` (Task 3) and `EditorView`/`TerminalPanel`/`AppDelegate` still use the old API. Do not build or commit standalone; proceed to Task 3, then build at the end of Task 3.

---

## Task 3: Route resolver + navigation hook

**Files:**
- Modify: `FloatNote/FloatNote/App.swift` (add resolver near the terminal methods; hook `switchTab`, `addTab`, and launch `loadTabs` path)

**Interfaces:**
- Consumes: `terminalTabs`, `switchToRoute`, `hideTerminal`, `activeTab`, `htmlToAttributedString(_:)`, `folders`, `tabs`.
- Produces: `func terminalRoute(for tab: NoteTab?) -> (path: String, label: String)?`, `func applyTerminalRouteForActiveNote()`.

- [ ] **Step 1: Add the route resolver**

Add these methods to `EditorViewModel` (place right after `closeTerminal`):

```swift
    /// The terminal route for a note: its folder's "terminal path" note's first
    /// non-empty body line, with `~` expanded. Direct folder only (no ancestor
    /// walk). Returns nil when there's no folder, no path note, or an empty path.
    func terminalRoute(for tab: NoteTab?) -> (path: String, label: String)? {
        guard let tab, let folderId = tab.folderId,
              let folder = folders.first(where: { $0.id == folderId }) else { return nil }
        guard let pathNote = tabs.first(where: { n in
            n.folderId == folderId &&
            n.title.lowercased().contains("terminal path")
        }) else { return nil }
        let plain = htmlToAttributedString(pathNote.html)?.string ?? ""
        guard let firstLine = plain
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        let expanded = (firstLine as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        return (expanded, folder.name)
    }

    /// Drive the terminal panel from the active note: route → open + switch/create
    /// that tab; no route → hide the panel (sessions survive).
    func applyTerminalRouteForActiveNote() {
        if let route = terminalRoute(for: activeTab) {
            switchToRoute(path: route.path, label: route.label)
        } else {
            hideTerminal()
        }
    }
```

- [ ] **Step 2: Hook `switchTab`**

At the end of `switchTab(_:)` (after `status = "Loaded"`, line ~1084), add:

```swift
        applyTerminalRouteForActiveNote()
```

- [ ] **Step 3: Hook `addTab`**

In `addTab()`, after `activeTabId = tab.id` (line ~1098), add:

```swift
        applyTerminalRouteForActiveNote()
```

- [ ] **Step 4: Hook the launch default-open**

In `loadTabs` (the launch block), after `lastTabsModDate = tabsFileModDate()` (line ~656), add:

```swift
        applyTerminalRouteForActiveNote()
```

- [ ] **Step 5: Build (App.swift logic layer)**

Run: `cd /Users/cagdas.agirtas/CodTemp/floatnote/FloatNote && swift build 2>&1 | tail -30`
Expected: errors now ONLY from `TerminalPanel`/`TerminalResizeHandle`/`EditorView`/`AppDelegate` still using `terminalIds`, `width(for:)`, `totalTerminalWidth`, `SwiftTermContainer(id:)`. The ViewModel logic (Tasks 2–3) must compile clean. Resolved by Tasks 4–5.

---

## Task 4: Terminal panel tab-bar UI + resize simplification

**Files:**
- Modify: `FloatNote/FloatNote/App.swift` — `TerminalPanel` (~2396), `TerminalResizeHandle` (~2300s), `EditorView` panel mounting (~2249–2262)

**Interfaces:**
- Consumes: `terminalTabs`, `activeTerminalId`, `addTerminal`, `closeTerminal`, `width`/`terminalWidth`, `availablePanelWidth`, `SwiftTermContainer(id:cwd:)`.

- [ ] **Step 1: Rebuild `TerminalPanel` as a tab bar + single terminal**

Replace the entire `TerminalPanel` struct with:

```swift
struct TerminalPanel: View {
    @EnvironmentObject var vm: EditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let activeId = vm.activeTerminalId,
               let tab = vm.terminalTabs.first(where: { $0.id == activeId }) {
                SwiftTermContainer(id: tab.id, cwd: tab.path)
                    .id(tab.id)
                    .background(Color.black)
            } else {
                Color.black
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(vm.terminalTabs) { tab in
                tabChip(tab)
                Divider().frame(height: 20)
            }
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) { vm.addTerminal() }
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .frame(width: 30, height: 28)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("New terminal at current route")
            Spacer(minLength: 0)
        }
        .background(vm.theme.chromeBackground)
    }

    private func tabChip(_ tab: TerminalTab) -> some View {
        let isActive = vm.activeTerminalId == tab.id
        return HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isActive ? .accentColor : .secondary)
            Text(tab.label)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .primary : .secondary)
                .lineLimit(1)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) { vm.closeTerminal(tab.id) }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Close this terminal")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: 180)
        .background(isActive ? Color.black : Color.clear)
        .overlay(alignment: .top) {
            if isActive { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { vm.activeTerminalId = tab.id }
        .help(tab.path)
    }
}
```

- [ ] **Step 2: Simplify `TerminalResizeHandle` to the editor↔panel boundary only**

The handle no longer resizes between columns. Replace the `TerminalResizeHandle` struct's stored properties and gesture with a single-boundary version. Set its properties to:

```swift
struct TerminalResizeHandle: View {
    @EnvironmentObject var vm: EditorViewModel
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var startWidth: CGFloat = 0

    private let hitWidth: CGFloat = 10
    private let minWidth = EditorViewModel.minTerminalColumnWidth
    private let maxWidth: CGFloat = 1200
```

Keep the existing visual `body` (the colored bar + hover cursor) but replace its `.gesture(...)` with:

```swift
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging { isDragging = true; startWidth = vm.terminalWidth }
                    let dx = value.translation.width
                    // Drag-left → wider (subtract dx); cap to the window.
                    let cap = min(maxWidth, max(minWidth, vm.availablePanelWidth()))
                    vm.terminalWidth = min(cap, max(minWidth, startWidth - dx))
                }
                .onEnded { _ in isDragging = false }
        )
```

Remove any `leftId`/`rightId`/`startLeft`/`startRight` properties and the `init` taking them. If the visual `body` references `rightId`, drop those references — the handle is now parameterless.

- [ ] **Step 3: Update `EditorView` panel mounting**

Replace the terminal mounting block (the `if vm.isTerminalVisible, let firstId = vm.terminalIds.first` handle + the `TerminalPanel().frame(width: vm.totalTerminalWidth)` block, ~lines 2249–2262) with:

```swift
                if vm.isTerminalVisible && !vm.terminalTabs.isEmpty {
                    TerminalResizeHandle()
                        .environmentObject(vm)
                }
                if vm.isTerminalVisible && !vm.terminalTabs.isEmpty {
                    TerminalPanel()
                        .environmentObject(vm)
                        .frame(width: min(vm.terminalWidth, vm.availablePanelWidth()))
                }
```

- [ ] **Step 4: Remove now-dead `clampTerminalWidths` callers**

Search `App.swift` for `clampTerminalWidths` (the GeometryReader `onChange` blocks ~lines 2165–2174 and any add/show call). Delete each `vm.clampTerminalWidths()` line. (The method itself was removed in Task 2.)

- [ ] **Step 5: Build**

Run: `cd /Users/cagdas.agirtas/CodTemp/floatnote/FloatNote && swift build 2>&1 | tail -30`
Expected: errors now ONLY from `AppDelegate` (`terminalIds`, `neighborTerminal`, `focusTerminal`, `addTerminal` last-id). Resolved by Task 5.

---

## Task 5: AppDelegate shortcuts + focus

**Files:**
- Modify: `FloatNote/FloatNote/App.swift` — `AppDelegate` key monitor (~80–92), `.floatnoteTerminalExited` observer (~103–105), `neighborTerminal` (~113–117), `focusTerminal` (~121–128)

**Interfaces:**
- Consumes: `vm.terminalTabs`, `vm.activeTerminalId`, `vm.closeTerminal`, `vm.addTerminal`, `TerminalSessions.shared.session(for:cwd:)`.

- [ ] **Step 1: Rework `neighborTerminal` for the tab model**

```swift
    @MainActor
    private func neighborTerminal(of id: UUID, in vm: EditorViewModel) -> UUID? {
        guard let idx = vm.terminalTabs.firstIndex(where: { $0.id == id }) else { return nil }
        let remaining = vm.terminalTabs.filter { $0.id != id }
        guard !remaining.isEmpty else { return nil }
        return remaining[min(max(idx - 1, 0), remaining.count - 1)].id
    }
```

- [ ] **Step 2: Rework `focusTerminal` to look up the session's cwd**

```swift
    private func focusTerminal(_ id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated {
                guard let session = TerminalSessions.shared.existing(id) else { return }
                let view = session.view
                guard view.window != nil else { return }
                view.window?.makeFirstResponder(view)
            }
        }
    }
```

Add a non-creating lookup to `TerminalSessions` in `Terminal.swift`:

```swift
    /// The live session for `id` if one exists, without creating it.
    func existing(_ id: UUID) -> TerminalSession? { sessions[id] }
```

- [ ] **Step 3: Update the Cmd+W / Cmd+N key monitor and new-terminal focus**

In the key monitor block (~80–92): Cmd+N path — after `vm.addTerminal()`, replace `if let newId = vm.terminalIds.last` with:

```swift
                    if let newId = vm.activeTerminalId { self.focusTerminal(newId) }
```

The Cmd+W path already calls `vm.closeTerminal(focusedId)` — leave it. The `\n` send path (`TerminalSessions.shared.session(for: focusedId)...`) needs a cwd now; replace with the non-creating accessor:

```swift
                    TerminalSessions.shared.existing(focusedId)?.view.send(txt: "\n")
```

- [ ] **Step 4: Update the `.floatnoteTerminalExited` observer guard**

Replace `vm.terminalIds.contains(id)` (~line 103) with:

```swift
                  vm.terminalTabs.contains(where: { $0.id == id }) else { return }
```

- [ ] **Step 5: Build (must be clean now)**

Run: `cd /Users/cagdas.agirtas/CodTemp/floatnote/FloatNote && swift build 2>&1 | tail -30`
Expected: BUILD SUCCEEDED, no errors.

- [ ] **Step 6: Commit the full feature**

```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote
git add FloatNote/FloatNote/Terminal.swift FloatNote/FloatNote/App.swift
git commit -m "feat: folder-routed terminal tabs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Bump version, deploy, manual verification

**Files:**
- Modify: `FloatNote/FloatNote/App.swift` (`APP_VERSION`)

- [ ] **Step 1: Bump `APP_VERSION`**

At the top of `App.swift`, increment the `APP_VERSION` constant (e.g. patch bump). Keep the format identical to the existing value.

- [ ] **Step 2: Build + deploy the app bundle**

Run: `cd /Users/cagdas.agirtas/CodTemp/floatnote && ./build.sh 2>&1 | tail -20`
Expected: build succeeds and `/Applications/FloatNote.app` is updated (script prints its completion line).

- [ ] **Step 3: Manual verification checklist**

Launch `/Applications/FloatNote.app` and confirm:
- A folder containing a note titled e.g. "terminal path" (body first line = a real directory) — opening any note in that folder opens the terminal panel with a tab labelled the folder name, shell cwd at that directory, `claude` auto-running.
- Opening a second routed folder's note adds a second tab and activates it; the first tab stays.
- Re-opening a note in the first folder activates the existing tab (no duplicate).
- Opening a root note (no folder / no path note) hides the panel; returning to a routed note re-shows its tab with the shell intact.
- The `+` button adds a terminal at the current route; ✕ closes a tab and activates a neighbor; closing the last hides the panel.
- Dragging the editor↔panel divider resizes the panel and it never exceeds the window width.
- With focus inside a terminal: ⌘W closes that tab, ⌘N opens a new one; typing `exit` closes the tab.

- [ ] **Step 4: Commit the version bump**

```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote
git add FloatNote/FloatNote/App.swift
git commit -m "chore: bump APP_VERSION for folder-routed terminal tabs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Route source ("terminal path" note, first non-empty line, ~ expansion, direct folder only) → Task 3 Step 1. ✓
- Data model (TerminalTab, terminalTabs, activeTerminalId; removed column machinery) → Task 2. ✓
- Dedup by path / switchToRoute → Task 2 Step 3. ✓
- Navigation rule (route → open+switch; none → hide), hooked at all activeTabId change points → Task 3 Steps 2–4. ✓
- Session cwd + HOME fallback + claude auto-run preserved → Task 1. ✓
- UI tab bar + single terminal, resize simplification, EditorView mount → Task 4. ✓
- AppDelegate ⌘W/⌘N, neighbor, focus, exit observer → Task 5. ✓
- Persistence removed (fn.terminalVisible seed dropped) → Task 2 Step 2. ✓
- APP_VERSION bump + build.sh deploy → Task 6. ✓

**Placeholder scan:** No TBD/TODO; all code blocks concrete. ✓

**Type consistency:** `TerminalTab(id:path:label:)`, `session(for:cwd:)`, `existing(_:)`, `SwiftTermContainer(id:cwd:)`, `switchToRoute(path:label:)`, `terminalRoute(for:) -> (path:label:)?`, `applyTerminalRouteForActiveNote()` used identically across tasks. ✓
