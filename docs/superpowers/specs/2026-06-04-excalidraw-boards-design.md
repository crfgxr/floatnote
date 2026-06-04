# Per-Note Excalidraw Boards — Design

**Date:** 2026-06-04
**Status:** Approved (design); implementation plan pending

## Summary

Add an Excalidraw whiteboard to each note in FloatNote. A toolbar button toggles
a full-view board (in-window) for the active note. Each note has its own board,
stored locally. The button reflects three states so the user can tell at a glance
whether a board exists and whether it is open. Excalidraw runs fully offline inside
a `WKWebView`. No MCP integration in this pass (UI-only).

## Decisions (locked)

- **Placement:** Full-view toggle. When on, the board replaces the editor area
  (`RichTextEditor`) for the active note; the sidebar and `FormatToolbar` stay
  visible so the toggle is always reachable.
- **Hosting:** Excalidraw bundled locally (offline). No internet required.
- **MCP:** None this pass. The connected `claude.ai` Excalidraw MCP server is a
  *chat diagram renderer* (renders inline in the Claude conversation, checkpoints
  live in the chat client, `export_to_excalidraw` uploads to excalidraw.com). It
  cannot store or serve FloatNote's per-note boards, so it is out of scope here.
  The only thing shared with the in-app boards is the Excalidraw element JSON
  format. MCP read/write of boards can be revisited later.
- **Tab switch:** Switching notes returns to note view (does not keep board mode).
- **Board lifecycle:** Trashing a note keeps its board file (note may be
  restored). Hard-delete / empty-trash deletes the board file.

## Hosting approach (offline Excalidraw)

**Chosen: Prebuilt UMD + script tags.**

- `npm i @excalidraw/excalidraw react react-dom` to fetch prebuilt `dist` assets.
- Copy the prebuilt `dist` files (Excalidraw UMD build + CSS), the React/ReactDOM
  UMD builds, and Excalidraw's font/asset folder into
  `FloatNote/FloatNote/Resources/excalidraw/`.
- A small static `index.html` + `bridge.js` load them via `<script>` tags.
- `window.EXCALIDRAW_ASSET_PATH` is set to the local assets directory so fonts and
  any wasm/asset files resolve offline.
- The `WKWebView` loads `index.html` from disk via
  `loadFileURL(_:allowingReadAccessTo:)` scoped to the `excalidraw` resource dir.

Rejected alternative: a custom Vite/esbuild bundle — smaller output but adds a JS
build toolchain to every app build. Not worth the machinery.

## Storage

- Directory: `~/.floatnote-excalidraw/` (created on first use).
- One file per note: `<noteUUID>.excalidraw.json`, containing the Excalidraw scene
  as `{ elements, appState }`.
- **Atomic writes** (write temp file + rename) — consistent with the MCP server's
  atomic-write requirement; `writeFileSync`-style in-place writes can fail silently
  under sandbox.
- The `noteUUID` is `NoteTab.id.uuidString` (stable per note).

## WKWebView board + JS↔Swift bridge

New `ExcalidrawBoardView` — an `NSViewRepresentable` wrapping `WKWebView`.

- **Keying:** rendered with `.id(tabId)` so each note gets its own webview
  instance bound to the correct note; reopening the board rebuilds cleanly.
- **Load:** the page signals "ready" via the message bridge; Swift then reads the
  note's `<uuid>.excalidraw.json` (empty scene if absent) and injects it as the
  initial scene through `evaluateJavaScript`.
- **Save:** Excalidraw's `onChange` → debounced (~800 ms) in `bridge.js` →
  `webkit.messageHandlers.floatnote.postMessage(scene)` → Swift writes the scene
  atomically to disk.
- **Theme:** the app passes its current theme to the page so the canvas matches
  light/dark (Midnight → dark; Paper/Sepia → light).
- **Safety saves:** also flush the current scene when the board is toggled off and
  when the active tab changes.

### Bridge message contract

- JS → Swift, handler name `floatnote`:
  - `{ type: "ready" }` — page loaded, request initial scene.
  - `{ type: "save", elements, appState }` — debounced scene save.
- Swift → JS, via `evaluateJavaScript`:
  - `window.floatnoteLoadScene({ elements, appState })` — inject scene.
  - `window.floatnoteSetTheme("dark" | "light")` — apply theme.

## Toolbar button — three states

Placed in the trailing toolbar group (next to the terminal toggle), reusing the
existing active/passive convention (`.secondary` vs `.accentColor`, plus the
rounded background fill used by the terminal/pin buttons for the "on" state).

| State | Appearance | Meaning | Tooltip |
|---|---|---|---|
| Passive — no diagram | gray outline icon | note has no board yet | "Add a diagram" |
| Has content — not open | accent-colored icon, no background | a board exists for this note | "Open diagram" |
| Open — board showing | accent icon + rounded background highlight | currently viewing the board | "Back to note" |

- Icon: SF Symbol `pencil.and.outline` (final symbol tweakable).
- **"Has content" detection:** `vm.boardHasContent: [UUID: Bool]`, seeded at launch
  by scanning `~/.floatnote-excalidraw/` (file present AND non-empty `elements`
  array), and updated whenever the bridge saves a scene. No webview needs to mount
  to color the button.

## Full-view toggle behavior

- New `vm.isBoardVisible: Bool` (global view flag; not persisted, defaults off).
- When on, the editor region renders `ExcalidrawBoardView(tabId:)` for the active
  tab instead of `RichTextEditor`. `FormatToolbar` stays mounted.
- The board toggle button calls `vm.toggleBoard()`.
- **Switching notes resets `isBoardVisible` to false** (return to note view) — the
  most predictable behavior; avoids dropping the user onto an empty board.

## Build pipeline changes

- `Package.swift`: add `resources: [.copy("Resources/excalidraw")]` to the target;
  access bundled files via `Bundle.module`.
- **`build.sh`:** must additionally copy the SPM resource bundle
  (`FloatNote_FloatNote.bundle`) from `.build/release/` into
  `/Applications/FloatNote.app/Contents/Resources/`. Today `build.sh` copies only
  the executable, so without this the resources would be missing at runtime.
- Vendoring step (`vendor-excalidraw.sh` or inline): copy the prebuilt Excalidraw /
  React assets into `Resources/excalidraw/`. Run once and on Excalidraw upgrades.
- Bump `APP_VERSION` in `App.swift`.

## Components & responsibilities

- `ExcalidrawBoardView` (NSViewRepresentable) — owns the `WKWebView`, configures
  the message handler, loads `index.html`, injects scene + theme. One per note.
- `ExcalidrawStore` (small helper) — path helpers, read/write scene JSON
  (atomic), delete board, and "has content" check for a note id.
- `EditorViewModel` additions — `isBoardVisible`, `toggleBoard()`,
  `boardHasContent: [UUID: Bool]`, seeding scan at launch, reset on tab switch,
  hook into hard-delete / empty-trash to remove board files.
- `FormatToolbar` addition — the three-state board button.
- `Resources/excalidraw/` — `index.html`, `bridge.js`, vendored Excalidraw/React
  assets + fonts.

## Main risk

Running Excalidraw **fully offline** (fonts/assets resolved via
`EXCALIDRAW_ASSET_PATH`) is the one piece with real unknowns. De-risk first with a
minimal standalone `index.html` loaded in the `WKWebView` and confirm the canvas
renders, fonts load, and `onChange` fires — before wiring the rest.

## Out of scope

- MCP read/write of boards.
- Exporting boards to image/PDF or to excalidraw.com.
- Embedding board thumbnails inline in the note.
- Multiple boards per note.
- Syncing boards across machines.
