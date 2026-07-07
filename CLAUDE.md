# FloatNote macOS App

## Build & Deploy
After ANY code change, run `./build.sh` to rebuild and update the app in `/Applications/FloatNote.app`.

Do NOT just run `swift build` — the app bundle in /Applications must be updated too.

## Project Layout
- `FloatNote/FloatNote/App.swift` - SwiftUI app, views, ViewModel, editor
- `FloatNote/Package.swift` - SPM manifest (macOS 14+)
- `mcp-server.js` - MCP server exposing notes to Claude
- `build.sh` - Build + deploy script

## Versioning
- Version constant `APP_VERSION` is at the top of `App.swift` — bump it on each update
- Displayed in the status bar (bottom right)

## Key Details
- Fully local-only app (no cloud sync)
- Data stored at `~/.floatnote-local.html`, `~/.floatnote-tabs.json`, `~/.floatnote-folders.json`
- Recordings live in `~/.floatnote-recordings/`
- Excalidraw boards live in `~/.floatnote-excalidraw/<noteUUID>.excalidraw.json` (one per note)

## External File Sync (MCP)
- A 2-second polling timer in `AppDelegate` calls both `checkExternalTabChanges()` and `checkExternalFolderChanges()` so MCP-driven edits to `~/.floatnote-tabs.json` / `~/.floatnote-folders.json` show up in the UI without an app restart.
- Both `saveTabsLocal` and `saveFoldersLocal` capture the mod-date *after* writing so the watcher doesn't treat the app's own write as a foreign edit.
- If you add a new on-disk store, follow the same pattern: `lastXModDate` field + `checkExternalXChanges()` + capture-on-save + register in the timer.

## Excalidraw Boards
- Each note has its own Excalidraw whiteboard. The toolbar board button (`pencil.and.outline`, in `FormatToolbar`) toggles `vm.isBoardVisible`, which swaps `ExcalidrawBoardView` in for `RichTextEditor` in `EditorView.content`.
- Button has three states: gray = no diagram, accent = board has content, accent + filled bg = board open. "Has content" is driven by `vm.boardContentIds` (seeded at launch via `ExcalidrawStore.scanContentIds()`, updated on each save via the `.floatnoteBoardSaved` notification).
- Switching/adding notes resets `isBoardVisible = false` (return to note view).
- Storage: `ExcalidrawStore` (in `Excalidraw.swift`) reads/writes `~/.floatnote-excalidraw/<noteUUID>.excalidraw.json` with atomic temp+replace. Hard-delete / empty-trash deletes the board file; trashing keeps it.
- **MCP board access**: `draw_on_board` (simplified shapes → valid Excalidraw elements, modes `replace`/`add` with overlap auto-shift) and `read_board` (element summary) in `mcp-server.js`. Board files follow the External File Sync pattern: `lastBoardModDates` + `checkExternalBoardChanges()` (registered in the AppDelegate timer), capture-on-save inside the `.floatnoteBoardSaved` observer. A foreign change to the **active** note's board auto-opens the board view, or posts `.floatnoteBoardExternallyChanged` to reload it in place when already open. The server uppercases note UUIDs in board filenames to match Swift's `uuidString`. Spec: `docs/superpowers/specs/2026-06-12-mcp-excalidraw-boards-design.md`.
- **Excalidraw runs fully offline in a `WKWebView`.** Excalidraw 0.18 ships ESM with ~25 external npm deps (no UMD), so it MUST be bundled. `vendor/excalidraw/` (entry `main.jsx`, `build.mjs`) uses esbuild to produce a single self-contained `bundle.js` + `index.css` + `fonts/` into `FloatNote/FloatNote/Resources/excalidraw/`. Run `./vendor-excalidraw.sh` once and on Excalidraw upgrades — `./build.sh` does NOT re-vendor, it only copies the static assets.
- The JS↔Swift bridge: page posts `{type:"ready"}` / `{type:"save",...}` to `webkit.messageHandlers.floatnote`; Swift calls `window.floatnoteLoadScene(<json>)` / `floatnoteSetTheme(...)` / `floatnoteFlush()`. A note's saved JSON is injected directly as a JS object literal (valid JSON = valid JS).
- **Build gotcha:** SPM resources produce `FloatNote_FloatNote.bundle` in `.build/release/`. `build.sh` copies every `.build/release/*.bundle` into the app's `Contents/Resources/` so `Bundle.module` resolves them — without this the board assets are missing at runtime.

## Terminal
- Shell lifecycle is owned by `TerminalSessions` (in `Terminal.swift`), NOT the SwiftUI view. A `TerminalSession` (LocalProcessTerminalView + child shell, started in a per-session `cwd`) is created lazily per terminal id via `session(for:cwd:)` and lives until `TerminalSessions.shared.close(id)` (called from `vm.closeTerminal`, i.e. the ✕ button). Use `existing(_:)` for a non-creating lookup. The shell's working directory is fixed at creation; `cwd` is ignored for an already-live session.
- **Tab system (one visible at a time)**: the panel is a tab bar (`TerminalPanel`) over `vm.terminalTabs: [TerminalTab]` (`{id, path, label}`) with `vm.activeTerminalId` selecting the visible one. Each chip is labelled by folder name, path on hover; `+` adds a tab at the active note's route (or HOME), ✕ closes one (activates a neighbor; last close hides the panel). There are no side-by-side columns and no per-column widths — `terminalWidth` is the single panel width.
- **Folder-routed switching (note → terminal)**: `vm.terminalRoute(for:)` maps the active note → its folder's "terminal path" note (a note in the same folder whose title contains "terminal path", case-insensitive) → first non-empty line of that note's plain-text body, `~`-expanded. **Direct folder only — no ancestor walk.** `vm.applyTerminalRouteForActiveNote()` runs on every `activeTabId` change (`switchTab`, `addTab`, launch `loadTabs`): a route → `switchToRoute(path:label:)` which dedups by path (switch to the existing tab for that path, else create one) and auto-opens the panel; no route → hide the panel. Spec: `docs/superpowers/specs/2026-06-18-folder-routed-terminal-tabs-design.md`.
- **Reverse routing (terminal → note)**: tapping a terminal chip calls `vm.selectTerminal(id)` (not a bare `activeTerminalId =` assignment), which sets the active terminal and then navigates to the related note. `folderForTerminalPath(_:)` reverse-maps the chip's path to the folder whose "terminal path" note resolves to it; `noteToActivate(forTerminalFolder:)` picks the last note the user had open there (`lastActiveNotePerFolder`, updated in `switchTab`), falling back to the folder's first non-"terminal path" note. **No ping-pong**: the resulting note→terminal route dedups by path back to the same chip, so `activeTerminalId` doesn't re-fire. Chips whose path maps to no folder (e.g. the default HOME terminal) leave the active note untouched. Spec: `docs/superpowers/specs/2026-06-18-unchecked-badges-and-terminal-note-nav-design.md`.
- **Hiding ≠ killing**: `SwiftTermContainer.makeNSView` returns the cached session view and has no teardown, so hiding the panel (toolbar toggle / no-route navigation → `isTerminalVisible=false`) or any view remount never kills the shell. Do not move shell termination into `dismantleNSView`.
- **Panel always fits the window**: the panel is rendered at `min(terminalWidth, availablePanelWidth())` and the editor↔panel `TerminalResizeHandle` caps drags to `availablePanelWidth()` (window − sidebar − handles). Never render the panel wider than the window — chips get clipped.
- **Terminal-scoped shortcuts**: a local `NSEvent` key monitor in `AppDelegate` intercepts Cmd+N (new terminal) and Shift+Enter/Cmd+Enter (newline without submit) ONLY when `TerminalSessions.shared.id(containing: firstResponder)` matches; otherwise they keep default behavior. Cmd+W is swallowed app-wide (returns nil for every Cmd+W, regardless of focus) — it must never close the window, which would take the terminal panel with it; terminal tabs close only via the ✕ button or `exit`.
- **`exit` closes the pane**: `processTerminated` posts `.floatnoteTerminalExited` (object = session UUID), observed in `AppDelegate` → `vm.closeTerminal`. Intentional kills (restart / ✕) set `expectedTermination` on the session first so they don't self-close — keep that guard if you add new kill paths.

## Folders & Trash
- Folders live in `~/.floatnote-folders.json`: `{id, name, isExpanded, isTrashed?, parentId?}`
- Notes reference folders via `folderId` (UUID string). `null` = root.
- **Subfolders**: `Folder.parentId` (UUID, optional; `nil`/absent = root) nests folders arbitrarily deep. `SidebarFolderView` renders recursively (subfolders before notes, +16pt indent per level). Drag a folder header onto another folder to nest (`draggingFolderId` + `FolderDropDelegate`); drop on empty sidebar = move to root. `moveFolder` rejects cycles (can't drop a folder onto itself/a descendant). MCP-created folders have no `parentId` (land at root); the MCP server round-trips folder objects so it preserves `parentId`.
- Trashing/deleting a folder **cascades** to its whole subtree (`descendantFolderIds`); the Trash section shows only subtree roots; restoring a subtree whose parent is gone/trashed reparents the root to top level.
- **Trash is virtual**, not a real folder:
  - Trashed folder → `Folder.isTrashed = true` (its notes keep their `folderId` so they restore as a group)
  - Loose-trashed note → `folderId = TRASH_FOLDER_ID` sentinel (`00000000-0000-0000-0000-000000000001`)
  - The Trash sentinel UUID must stay in sync between `App.swift` and `mcp-server.js`
- Sidebar renders a pinned Trash section at the bottom; trashed items have Restore + Delete Permanently in the context menu. No auto-purge.
- When mutating a nested `@Published` property of a `Folder`/`NoteTab` that the sidebar partitions on (e.g. `isTrashed`, `folderId`), reassign the parent VM array (`folders = folders` / `tabs = tabs`) so `@Published` re-fires and the sidebar repartitions.

## Default-Open Note
- On launch, the app opens the first non-trashed note whose title contains "backlog - agentforce" (case/whitespace-insensitive substring), falling back to the first non-trashed tab.
- `switchToFirstVisibleTab(excluding:)` applies the same preference, so trashing the active note (or any other auto-switch path) lands back on the backlog note when it exists.

## Editor Features
- **Toolbar**: Minimal plain-style buttons with hover highlights, flexible layout (all buttons visible at any width)
- **Font + size pickers**: `FontPicker` (family) and `BodySizePicker` (size) in the toolbar. Both persist to UserDefaults via `Tokens` (`fn.fontFamily` / `fn.bodyFontSize`) and call `vm.reloadActive()` to re-render the document live. All editor fonts route through `Tokens.Typography.editorFont(...)`, so the selected family/size applies everywhere (load normalization in `htmlToAttributedString`, typing attrs, headings). `"System"` = the built-in default; coordinator fonts are computed (not captured) so changes take effect without recreating the editor.
- **Undo/Redo**: All programmatic edits (checkbox toggle, bullet/checklist continuation, indent/outdent, format toolbar, drag-drop reorder) are undoable via snapshot-based undo registration
- **Tab/Shift-Tab**: Indent (4 spaces) / outdent selected lines or list items
- **List insert**: Pressing bullet/checklist at the beginning of an existing list line inserts a new line above and pushes the current line down
- **List continuation**: Enter on bullet/checklist lines continues with same prefix + indentation level
- **Hanging indent**: Wrapped text on list lines aligns after the prefix
- **Smart Home**: Cmd+Left jumps to after list prefix first, then to column 0 on second press
- **Smart Select**: Cmd+Shift+Left extends selection to after prefix, mirroring smart home
- **Smart Backspace**: Backspace at/inside a list prefix removes the entire prefix; Cmd+Backspace deletes to prefix boundary first, then removes prefix on second press
- **Move lines**: Option+Up/Down swaps lines, preserving caret position
- **Drag-to-reorder**: Click and drag list prefixes to reorder; blue insertion line shows drop target; dropped lines match target indentation
- **Dictation auto-restart**: When mic is enabled, dictation auto-restarts after system timeout or when app regains focus
- **Audio recording**: Record system audio (via ScreenCaptureKit) + microphone per tab, PCM-level merge, stored as .m4a in ~/.floatnote-recordings/
- **Transcription**: Deepgram-powered transcription with multi-language support (English, Turkish); 5-min timeout for large files
- **AI Summary**: OpenRouter-powered meeting summary (transcribe → summarize via AI); models: `openai/gpt-oss-120b:free` primary, `openai/gpt-oss-20b:free` fallback; outputs plain text with FloatNote-native formatting (• bullets, ☐ action items); auto-retry with model fallback on rate limits; API key at `~/.floatnote-openrouter.key`
- **Recording playback**: In-app audio player with seek, play/pause, stop; recordings linked to tabs

## Sidebar Unchecked-Item Badges
- Each sidebar note row (`SidebarNoteItemView`) shows a red `UncheckedBadge` pill (white number, `#ff3b30`) = count of unchecked `☐` glyphs in that note. Hidden when 0; counts >99 render as `99+`.
- Source of truth: `NoteTab.uncheckedCount` (`@Published`). `NoteTab.countUnchecked(in:)` counts `☐` chars; `recomputeUncheckedFromHTML()` runs it over the stored HTML (which keeps `☐` literal — no parsing needed).
- Recompute points: `NoteTab.from` (load + external merge of non-active tabs), the external-change merge for the active tab, and — for **live** updates — the editor coordinator's `textDidChange`, which counts the live `NSTextStorage.string` and passes it to `vm.textDidChange(html:length:uncheckedCount:)` → `activeTab?.uncheckedCount`. Checkbox toggles route through `didChangeText()` → `textDidChange`, so the badge drops the instant a box is checked, before any save. Spec: `docs/superpowers/specs/2026-06-18-unchecked-badges-and-terminal-note-nav-design.md`.
