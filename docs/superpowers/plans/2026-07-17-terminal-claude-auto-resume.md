# Terminal Claude Auto-Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every FloatNote terminal's auto-run command decide, at send time, between plain `claude` and `claude --continue`, so a terminal routed to a directory with an existing Claude Code conversation resumes it instead of always starting fresh.

**Architecture:** `TerminalSession.startShell()` already auto-types a command 0.6s after the shell starts, guarded by a `sessionGen` generation counter. We add a small pure static function, `TerminalSession.claudeLaunchCommand(dir:home:projectsRoot:fileManager:)`, that inspects Claude Code's on-disk session store (`~/.claude/projects/<munged-path>/*.jsonl`) and returns the right command string. `startShell()`'s existing 0.6s `asyncAfter` closure calls it instead of hard-coding `"claude\n"`. No other file, API, or the routing system is touched.

**Tech Stack:** Swift 5.9 / SwiftUI / AppKit, SwiftTerm (SPM dependency), macOS 14+. The `FloatNote` SPM package (`FloatNote/Package.swift`) has a single `.executableTarget` and **no test target** — do not add one. Verification for the pure function happens via a standalone `swift <script>.swift` run outside the package (see Task 1), and via `./build.sh` + manual observation for the wiring.

## Global Constraints

- Platform: macOS 14+, SPM `.executableTarget` only (`FloatNote/Package.swift`) — **no test target exists; do not create one.**
- Build/Deploy: after ANY code change, run `./build.sh` from the repo root — **never** bare `swift build`. It rebuilds the SPM package AND overwrites `/Applications/FloatNote.app`. Success = exit code 0, last line of output is `Done — app updated and launched.`
- The existing 0.6s `DispatchQueue.main.asyncAfter` auto-run block and its `sessionGen` generation guard in `TerminalSession.startShell()` (`FloatNote/FloatNote/Terminal.swift:107-113`) must remain structurally unchanged — only the string passed to `term?.send(txt:)` becomes computed at send time, inside the same closure.
- Munge rule (verbatim from spec): `<munged>` = the launch directory's absolute path with **every character outside `[A-Za-z0-9]` replaced by `-`**.
- Decision rule (verbatim from spec, `docs/superpowers/specs/2026-07-17-terminal-claude-auto-resume-design.md`):
  1. Let `dir` be the resolved launch directory (the session's `cwd`, already falling back to HOME when the path no longer exists) — this is the existing `dir` local in `startShell()`.
  2. If `dir == NSHomeDirectory()` (the existing `home` local) → send `claude\n`.
  3. Otherwise map `dir` to `~/.claude/projects/<munged>`.
  4. If that directory exists and its top level (non-recursive) contains at least one `*.jsonl` file → send `claude --continue\n`; else → send `claude\n`.
- `APP_VERSION` (`FloatNote/FloatNote/App.swift:19`) bumps from the current working-tree value `"v1.49.1"` to **`"v1.50.0"`**.
- Commit message style (from `git log`): `feat: ...` / `docs: ...`, one commit per task, every message ending with a blank line then `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Git hygiene:** the working tree already carries unrelated, uncommitted edits in `CLAUDE.md`, `FloatNote/FloatNote/App.swift`, `FloatNote/FloatNote/DesignTokens.swift`, and `mcp-server.js` (pre-existing, unrelated to this feature). Every `git add` in this plan must target only the exact file(s)/hunk(s) the task itself produced — **never** `git add -A` or a bare whole-file `git add` on `App.swift` or `CLAUDE.md`. Task 3 spells out the exact `git add -p` sequence needed because those two files have other pending changes nearby.

---

## File Structure

- `FloatNote/FloatNote/Terminal.swift` — the only production Swift file touched.
  - Task 1 adds two new `static func`s to the `TerminalSession` class (unused by production code yet, but compiled and unit-checkable via a standalone script).
  - Task 2 changes 6 lines inside `startShell()`'s existing `asyncAfter` closure to call the new function instead of hard-coding `"claude\n"`.
- `FloatNote/FloatNote/App.swift` — one-line `APP_VERSION` bump (Task 3).
- `CLAUDE.md` — one new bullet appended to the end of the **Terminal** section (Task 3).
- A throwaway verification script (not part of the git repo) written to the scratchpad directory in Task 1, used once and not committed.

---

## Task 1: Pure decision function + algorithm verification script

**Files:**
- Modify: `FloatNote/FloatNote/Terminal.swift:113-115` (insert two new methods between the closing brace of `startShell()` and the start of `restart()`)
- Create (scratchpad, NOT committed): `/private/tmp/claude-501/-Users-cagdas-agirtas-CodTemp-floatnote/8185bf0e-082e-4b23-89f5-6883d2d04bf1/scratchpad/claude-launch-command-check.swift` — if you are executing this plan in a different session, substitute your own writable scratch directory; the path is not load-bearing, only the script's self-contained content is.

**Interfaces:**
- Produces: `TerminalSession.mungedClaudeProjectDirName(for path: String) -> String` and `TerminalSession.claudeLaunchCommand(dir: String, home: String, projectsRoot: String, fileManager: FileManager = .default) -> String`. Task 2 calls `claudeLaunchCommand` from inside `startShell()`'s `asyncAfter` closure — that is the only consumer.

- [ ] **Step 1: Add the two static functions to `TerminalSession`**

Open `FloatNote/FloatNote/Terminal.swift`. Locate the end of `startShell()` and the start of `restart()` (currently lines 113-115):

```swift
    func restart() {
```

immediately preceded by `startShell()`'s closing brace (line 113):

```swift
        }
    }

    func restart() {
```

Insert the following two methods **between** `startShell()`'s closing brace and `func restart()`, so the result reads:

```swift
        }
    }

    /// Munges an absolute path into Claude Code's session-store directory
    /// name convention: every character outside `[A-Za-z0-9]` becomes `-`.
    /// e.g. `/Users/x/CodTemp/floatnote` → `-Users-x-CodTemp-floatnote`.
    static func mungedClaudeProjectDirName(for path: String) -> String {
        String(path.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        })
    }

    /// Decides the command to auto-send when a shell starts in `dir`. HOME
    /// always gets a fresh `claude`; any other directory resumes the most
    /// recent Claude Code conversation (`claude --continue`) if Claude
    /// Code's session store (`projectsRoot/<munged dir>`) has at least one
    /// saved `.jsonl` conversation for it, else starts fresh with plain
    /// `claude`. Pure and parameterized (no `NSHomeDirectory()` /
    /// `FileManager.default` baked in) so it can be exercised outside the
    /// app.
    static func claudeLaunchCommand(
        dir: String,
        home: String,
        projectsRoot: String,
        fileManager: FileManager = .default
    ) -> String {
        guard dir != home else { return "claude\n" }
        let sessionDir = projectsRoot + "/" + mungedClaudeProjectDirName(for: dir)
        let hasSession = (try? fileManager.contentsOfDirectory(atPath: sessionDir))?
            .contains { $0.hasSuffix(".jsonl") } ?? false
        return hasSession ? "claude --continue\n" : "claude\n"
    }

    func restart() {
```

Do not touch `startShell()`'s body in this step — these two methods are added but not yet called from anywhere (that's Task 2).

- [ ] **Step 2: Build to confirm it compiles**

Run: `cd /Users/cagdas.agirtas/CodTemp/floatnote && ./build.sh`
Expected: exits 0; last line of output is `Done — app updated and launched.`

- [ ] **Step 3: Write the algorithm verification script**

This script cannot `import` the FloatNote executable target (it isn't a library) or SwiftTerm, so it duplicates the two functions' bodies verbatim as a **manual copy** — the header comment says so explicitly. If Task 1's Step 1 code ever changes, re-copy the bodies here before trusting this script again.

Write to `/private/tmp/claude-501/-Users-cagdas-agirtas-CodTemp-floatnote/8185bf0e-082e-4b23-89f5-6883d2d04bf1/scratchpad/claude-launch-command-check.swift`:

```swift
import Foundation

// Manual copy of TerminalSession.mungedClaudeProjectDirName /
// TerminalSession.claudeLaunchCommand from FloatNote/FloatNote/Terminal.swift,
// used ONLY to verify the decision algorithm outside the app (this script
// cannot import the FloatNote executable target or SwiftTerm). This is a
// copy, not a shared source file — if the real functions in Terminal.swift
// change, re-copy their bodies here before trusting this script again.

func mungedClaudeProjectDirName(for path: String) -> String {
    String(path.map { ch -> Character in
        (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
    })
}

func claudeLaunchCommand(
    dir: String,
    home: String,
    projectsRoot: String,
    fileManager: FileManager = .default
) -> String {
    guard dir != home else { return "claude\n" }
    let sessionDir = projectsRoot + "/" + mungedClaudeProjectDirName(for: dir)
    let hasSession = (try? fileManager.contentsOfDirectory(atPath: sessionDir))?
        .contains { $0.hasSuffix(".jsonl") } ?? false
    return hasSession ? "claude --continue\n" : "claude\n"
}

let home = NSHomeDirectory()
let projectsRoot = home + "/.claude/projects"

var failed = false
func check(_ label: String, _ actual: String, _ expected: String) {
    let ok = actual == expected
    print("\(ok ? "PASS" : "FAIL") \(label): got \(actual.debugDescription), want \(expected.debugDescription)")
    if !ok { failed = true }
}

// 1. HOME directory -> plain claude (the HOME-fallback terminal case).
check("home dir", claudeLaunchCommand(dir: home, home: home, projectsRoot: projectsRoot), "claude\n")

// 2. Real project dir with existing session files -> claude --continue.
let floatnoteDir = "/Users/cagdas.agirtas/CodTemp/floatnote"
check(
    "floatnote project dir",
    claudeLaunchCommand(dir: floatnoteDir, home: home, projectsRoot: projectsRoot),
    "claude --continue\n"
)

// 3. Directory Claude Code has never seen -> plain claude (no error).
let neverUsedDir = "/tmp/floatnote-claude-auto-resume-verify-\(UUID().uuidString)"
check(
    "never-used project dir",
    claudeLaunchCommand(dir: neverUsedDir, home: home, projectsRoot: projectsRoot),
    "claude\n"
)

if failed {
    print("FAILED")
    exit(1)
}
print("All checks passed.")
```

- [ ] **Step 4: Run the verification script**

Run: `cd /private/tmp/claude-501/-Users-cagdas-agirtas-CodTemp-floatnote/8185bf0e-082e-4b23-89f5-6883d2d04bf1/scratchpad && swift claude-launch-command-check.swift`

Expected output (exact — already run once while writing this plan):
```
PASS home dir: got "claude\n", want "claude\n"
PASS floatnote project dir: got "claude --continue\n", want "claude --continue\n"
PASS never-used project dir: got "claude\n", want "claude\n"
All checks passed.
```

Case 2 works only because `~/.claude/projects/-Users-cagdas-agirtas-CodTemp-floatnote/` already contains 36 `.jsonl` files on this machine (verified: `ls ~/.claude/projects/-Users-cagdas-agirtas-CodTemp-floatnote/*.jsonl | wc -l` → `36`). If you run this on a machine without that history, case 2 will legitimately print `FAIL` (the directory won't exist yet) — that's a machine-state issue, not a bug in the function; re-derive an equivalent "known project with history" path for that machine, or run this whole plan on `/Users/cagdas.agirtas/CodTemp/floatnote` on the original machine as intended.

- [ ] **Step 5: Commit**

```bash
git add FloatNote/FloatNote/Terminal.swift
git commit -m "$(cat <<'EOF'
feat: add pure claude-launch-command decision function to TerminalSession

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Wire the decision function into `startShell()`

**Files:**
- Modify: `FloatNote/FloatNote/Terminal.swift:86-113` (`startShell()` — only the `asyncAfter` closure body changes; the rest of the method is untouched)

**Interfaces:**
- Consumes: `TerminalSession.claudeLaunchCommand(dir:home:projectsRoot:fileManager:)` from Task 1 (signature unchanged).
- Produces: nothing new — `startShell()`'s public behavior (still `func startShell()`, still called from `init` and `restart()`) is unchanged from the caller's point of view.

- [ ] **Step 1: Replace the `asyncAfter` block**

Current `startShell()` (lines 86-113):

```swift
    func startShell() {
        let term = view
        // Disable caret blink — steady block cursor.
        term.terminal?.setCursorStyle(.steadyBlock)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let home = NSHomeDirectory()
        // The session's route directory; fall back to HOME if it no longer exists.
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
        // Auto-run `claude` once the login shell has finished initializing.
        // The shell already starts in the target folder (via currentDirectory).
        // The generation guard ensures a restart invalidates a pending send
        // from the previous shell.
        sessionGen += 1
        let gen = sessionGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak term] in
            guard let self, self.sessionGen == gen else { return }
            term?.send(txt: "claude\n")
        }
    }
```

Replace it with:

```swift
    func startShell() {
        let term = view
        // Disable caret blink — steady block cursor.
        term.terminal?.setCursorStyle(.steadyBlock)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let home = NSHomeDirectory()
        // The session's route directory; fall back to HOME if it no longer exists.
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
        // Auto-run `claude` (or `claude --continue`, see claudeLaunchCommand)
        // once the login shell has finished initializing. The shell already
        // starts in the target folder (via currentDirectory). The generation
        // guard ensures a restart invalidates a pending send from the
        // previous shell. The command is decided at send time so a restart
        // picks up whatever conversation history exists by then.
        sessionGen += 1
        let gen = sessionGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak term] in
            guard let self, self.sessionGen == gen else { return }
            let command = TerminalSession.claudeLaunchCommand(
                dir: dir,
                home: home,
                projectsRoot: home + "/.claude/projects"
            )
            term?.send(txt: command)
        }
    }
```

(`dir` and `home` are the same pre-existing `let`s a few lines up — the closure captures them automatically, no capture-list change needed.)

- [ ] **Step 2: Build**

Run: `cd /Users/cagdas.agirtas/CodTemp/floatnote && ./build.sh`
Expected: exits 0; last line of output is `Done — app updated and launched.`

- [ ] **Step 3: Manual regression smoke test**

1. FloatNote relaunches automatically at the end of `build.sh` (it calls `open /Applications/FloatNote.app`). Bring it to the foreground.
2. Open a note that has **no** project route (e.g. any root-level note not inside a linked folder, or one with no folder override) and either use its existing terminal or press `+` to add one.
3. Wait about a second after the shell prompt appears. **Expected:** the terminal auto-types and runs plain `claude` exactly as before — no crash, no hang, no visible change from pre-Task-2 behavior. This directory is HOME, so `claudeLaunchCommand` takes the early-return branch regardless of any `~/.claude/projects` contents.
4. Click a note inside the **floatnote** project folder (already linked to `/Users/cagdas.agirtas/CodTemp/floatnote` in this environment) — e.g. the note titled exactly **💡floatnote ideas**. Its terminal chip should route to `/Users/cagdas.agirtas/CodTemp/floatnote`. Wait a second. **Expected:** the terminal auto-types `claude --continue` (not bare `claude`) and Claude Code resumes the most recent conversation for that directory — this is the first observable proof the wiring works, ahead of Task 3's fuller checklist.
5. Press the ↻ restart button on that same terminal. **Expected:** the shell restarts and again auto-types `claude --continue` (the session guard `sessionGen` still prevents any stale send from the old shell).

- [ ] **Step 4: Commit**

```bash
git add FloatNote/FloatNote/Terminal.swift
git commit -m "$(cat <<'EOF'
feat: auto-run claude --continue for terminals with existing session history

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Version bump, CLAUDE.md doc line, end-to-end verification

**Files:**
- Modify: `FloatNote/FloatNote/App.swift:19` (`APP_VERSION`)
- Modify: `CLAUDE.md` (append one bullet to the end of the **Terminal** section, currently ending at the `` - **`exit` closes the pane**... `` line)

**Interfaces:** none — this task adds no new code, only metadata/docs, and end-to-end verification of Tasks 1-2's behavior.

- [ ] **Step 1: Bump `APP_VERSION`**

In `FloatNote/FloatNote/App.swift`, change line 19 from:

```swift
let APP_VERSION = "v1.49.1"
```

to:

```swift
let APP_VERSION = "v1.50.0"
```

- [ ] **Step 2: Add one line to CLAUDE.md's Terminal section**

The **Terminal** section's last bullet (currently the final line before the blank line + `## Folders & Trash` header) is:

```
- **`exit` closes the pane**: `processTerminated` posts `.floatnoteTerminalExited` (object = session UUID), observed in `AppDelegate` → `vm.closeTerminal`. Intentional kills (restart / ✕) set `expectedTermination` on the session first so they don't self-close — keep that guard if you add new kill paths.
```

Append a new bullet immediately after it (before the blank line that precedes `## Folders & Trash`):

```
- **`exit` closes the pane**: `processTerminated` posts `.floatnoteTerminalExited` (object = session UUID), observed in `AppDelegate` → `vm.closeTerminal`. Intentional kills (restart / ✕) set `expectedTermination` on the session first so they don't self-close — keep that guard if you add new kill paths.
- **Claude auto-resume**: routed terminals auto-run `claude --continue` when `~/.claude/projects/<munged-cwd>` has session files; HOME and first-open projects run plain `claude`; ↻ restart re-evaluates. Decision lives in `TerminalSession.claudeLaunchCommand` (`Terminal.swift`), computed at send time inside the existing 0.6s auto-run. Spec: `docs/superpowers/specs/2026-07-17-terminal-claude-auto-resume-design.md`.
```

This insertion point (end of the section, not interleaved with the "Tab system"/"Project folders"/"Reverse routing"/"Focus follows" bullets) was chosen deliberately: those earlier bullets already carry unrelated, uncommitted edits from prior work, and appending at the end keeps this task's line separable from them for staging in Step 5.

- [ ] **Step 3: Build**

Run: `cd /Users/cagdas.agirtas/CodTemp/floatnote && ./build.sh`
Expected: exits 0; last line of output is `Done — app updated and launched.` (CLAUDE.md is documentation only and doesn't affect compilation; this confirms the `APP_VERSION` edit still compiles and the version bump is reflected in the running app's status bar.)

- [ ] **Step 4: End-to-end manual verification**

Relaunch FloatNote (or use the instance `build.sh` just relaunched) and check the status bar shows `v1.50.0`. Then verify all three documented scenarios:

1. **Routed terminal with existing conversation → resumes it.** Click the note titled exactly **💡floatnote ideas** (inside the "floatnote" project folder, linked to `/Users/cagdas.agirtas/CodTemp/floatnote`). Its terminal auto-opens routed to that directory. **Expected:** within ~1s the terminal auto-types `claude --continue` and Claude Code loads the previous conversation for this directory (you'll see prior conversation context/summary rather than a blank new-session prompt).

2. **Routed terminal, first-ever open of that project → starts fresh, no error.** Create a temporary FloatNote folder (sidebar `+` → new folder), link it via its context menu's **Link Local Folder…** to a directory Claude Code has never used, e.g. run `mkdir -p /tmp/floatnote-claude-resume-verify-e2e` first, then link to that path. Add a note inside this temp folder and open it. **Expected:** the terminal routes to `/tmp/floatnote-claude-resume-verify-e2e` and auto-types plain `claude` (not `--continue`) — Claude Code starts a brand-new conversation with no "No conversation found" error. Afterward, clean up: unlink/trash the temp folder from the sidebar and `rm -rf /tmp/floatnote-claude-resume-verify-e2e`.

3. **HOME fallback terminal → always plain `claude`.** Open a note with no project route (no linked ancestor folder, no per-note override) — e.g. a root-level note, or press `+` for a new terminal tab while such a note is active. **Expected:** the terminal routes to HOME and auto-types plain `claude`, regardless of any Claude Code history that may exist for `$HOME` itself.

- [ ] **Step 5: Stage only this task's hunks**

Both `App.swift` and `CLAUDE.md` carry other, unrelated uncommitted changes right now. Stage precisely — and only — the two hunks this task produced.

**`App.swift`:** the `APP_VERSION` line is its own isolated hunk (no unrelated change sits within 3 lines of it). Run:

```bash
git add -p FloatNote/FloatNote/App.swift
```

The first hunk shown will be:
```
@@ -16,7 +16,7 @@ func dbg(_ msg: String) {
     }
 }
 
-let APP_VERSION = "v1.37.0"
+let APP_VERSION = "v1.50.0"
 let LOCAL_SAVE_PATH = NSHomeDirectory() + "/.floatnote-local.html"
 let LOCAL_TABS_PATH = NSHomeDirectory() + "/.floatnote-tabs.json"
 let LOCAL_FOLDERS_PATH = NSHomeDirectory() + "/.floatnote-folders.json"
```
Answer `y` (stage this hunk) to it, then `d` (do not stage this hunk or any of the later hunks in the file) to skip App.swift's ~70 other unrelated hunks without reviewing them one by one.

Verify: `git diff --cached FloatNote/FloatNote/App.swift` shows exactly that one-line change and nothing else.

**`CLAUDE.md`:** the Terminal section already has unrelated uncommitted edits nearby, so your new bullet lands in the same top-level hunk as them. Run:

```bash
git add -p CLAUDE.md
```

Answer the prompts in this order:
1. Hunk (Code Signing section addition, near the top of the file) → `n`
2. Hunk (the Terminal section — contains both the pre-existing "Project folders"/"Reverse routing"/"Focus follows" edits AND your new bullet at the end) → `s` (split into 2 hunks)
3. First half of the split (the pre-existing Terminal-section edits) → `n`
4. Second half of the split (just your new `- **Claude auto-resume**...` line, with 3-4 lines of unchanged context on each side) → `y`
5. Remaining hunk (Default-Open Note + Editor Features additions, further down the file) → `n`

This exact `n, s, n, y, n` sequence was verified while writing this plan against the real file content — splitting the Terminal-section hunk at that point cleanly isolates only the new line. If your `git diff CLAUDE.md` shows different hunk boundaries by the time you run this (e.g. because other unrelated edits changed in the meantime), the invariant to hold onto is: after staging, `git diff --cached CLAUDE.md` must show **only** the new `Claude auto-resume` bullet as an addition, nothing else — keep adjusting which sub-hunk you `y`/`n` (or use `e` to manually edit a hunk down to just your line) until that's true.

Expected final staged diff (verify with `git diff --cached CLAUDE.md`):
```
diff --git a/CLAUDE.md b/CLAUDE.md
index 1956c18..<newhash> 100644
--- a/CLAUDE.md
+++ b/CLAUDE.md
@@ -45,6 +45,7 @@ Do NOT just run `swift build` — the app bundle in /Applications must be update
 - **Panel always fits the window**: the panel is rendered at `min(terminalWidth, availablePanelWidth())` and the editor↔panel `TerminalResizeHandle` caps drags to `availablePanelWidth()` (window − sidebar − handles). Never render the panel wider than the window — chips get clipped.
 - **Terminal-scoped shortcuts**: a local `NSEvent` key monitor in `AppDelegate` intercepts Cmd+N (new terminal) and Shift+Enter/Cmd+Enter (newline without submit) ONLY when `TerminalSessions.shared.id(containing: firstResponder)` matches; otherwise they keep default behavior. Cmd+W is swallowed app-wide (returns nil for every Cmd+W, regardless of focus) — it must never close the window, which would take the terminal panel with it; terminal tabs close only via the ✕ button or `exit`.
 - **`exit` closes the pane**: `processTerminated` posts `.floatnoteTerminalExited` (object = session UUID), observed in `AppDelegate` → `vm.closeTerminal`. Intentional kills (restart / ✕) set `expectedTermination` on the session first so they don't self-close — keep that guard if you add new kill paths.
+- **Claude auto-resume**: routed terminals auto-run `claude --continue` when `~/.claude/projects/<munged-cwd>` has session files; HOME and first-open projects run plain `claude`; ↻ restart re-evaluates. Decision lives in `TerminalSession.claudeLaunchCommand` (`Terminal.swift`), computed at send time inside the existing 0.6s auto-run. Spec: `docs/superpowers/specs/2026-07-17-terminal-claude-auto-resume-design.md`.
 
 ## Folders & Trash
 - Folders live in `~/.floatnote-folders.json`: `{id, name, isExpanded, isTrashed?, parentId?}`
```

- [ ] **Step 6: Commit**

```bash
git commit -m "$(cat <<'EOF'
docs: claude auto-resume terminal routing in CLAUDE.md; bump v1.50.0

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 7: Confirm the commit contains only what this task intended**

Run: `git show --stat HEAD`
Expected: exactly two files listed — `CLAUDE.md` and `FloatNote/FloatNote/App.swift` — each with `1 +` (one insertion; `App.swift`'s line change counts as one line touched). Run `git status` afterward and confirm `App.swift`, `CLAUDE.md`, `DesignTokens.swift`, and `mcp-server.js` still show as modified (their pre-existing, unrelated hunks remain uncommitted, exactly as before this task started) — this task must not have touched or lost any of that other in-flight work.

---
