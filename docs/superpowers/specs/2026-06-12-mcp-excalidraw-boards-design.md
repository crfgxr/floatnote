# MCP Access to Per-Note Excalidraw Boards — Design

Date: 2026-06-12
Status: approved

## Goal

Let LLMs (via the FloatNote MCP server) draw diagrams onto a note's attached
Excalidraw whiteboard instead of dumping ASCII art into note text, and make the
app reflect those drawings live.

## Background

- Every note has a board at `~/.floatnote-excalidraw/<noteUUID>.excalidraw.json`
  (scene JSON: `{elements, appState, files}`), managed by `ExcalidrawStore`.
- The board webview runs Excalidraw's `restore()` on every scene load
  (`vendor/excalidraw/main.jsx`), which normalizes elements and fills missing
  defaults — MCP-written elements need to be structurally correct but not
  exhaustive.
- CLAUDE.md previously declared boards UI-only and prescribed the External File
  Sync pattern if MCP editing is ever added. This design adds it.

## MCP Server (mcp-server.js → 1.4.0)

### `draw_on_board(identifier, mode, shapes[])`

- Resolves the note by UUID or title (same fuzzy match as `read_note`).
- `shapes[]` — simplified primitives the server converts to valid Excalidraw
  elements:
  - `type`: `rectangle | ellipse | diamond | text | arrow | line`
  - `x, y, width, height` (text needs only x/y; arrow/line need start/end)
  - `label`: text rendered inside a shape (bound text) or on an arrow
  - `text`: content for standalone `text` elements
  - `id`: optional friendly id so arrows can reference shapes
  - `start` / `end` (arrow/line): a shape id (string) or `{x, y}` point.
    Bound arrows get real `startBinding`/`endBinding` plus reciprocal
    `boundElements` entries, and their endpoints are clipped to the shapes'
    edges — so connectors stay attached when shapes are dragged in the app.
  - optional `strokeColor`, `backgroundColor`, `fontSize`
- `mode: "replace"` — board content is replaced (appState/files preserved).
  `mode: "add"` — new elements are appended; if their bounding box intersects
  the existing content's bounding box, all new elements are shifted below the
  existing content (+80px margin) so nothing is drawn over user content.
- Writes atomically (temp + rename, same as the tabs/folders writers).

### `read_board(identifier)`

Compact text summary of the board: each element's type, id, label/text, and
rounded geometry, plus the overall bounding box. Used by LLMs to edit
intelligently or pick free space before `mode: "add"`.

### Discoverability

- `draw_on_board` description states every note has an attached whiteboard and
  that diagram/flowchart/sketch requests should use it — never ASCII art in
  note text.
- `list_notes` marks notes that have board content (`[has diagram]`).
- `read_note` appends a board notice when the note's board is non-empty.

## App (FloatNote → v1.31.0)

External File Sync pattern, applied to the board directory:

- `ExcalidrawStore.scanModDates() -> [UUID: Date]` (+ `modDate(for:)`).
- VM keeps `lastBoardModDates`, seeded at launch in `startBoardTracking()`.
- The existing `.floatnoteBoardSaved` observer also captures the post-save
  mod-date, so the app's own writes are not treated as foreign edits.
- New `checkExternalBoardChanges()` — registered in the AppDelegate 2s timer —
  diffs mod-dates. For each foreign change:
  - update `boardContentIds` (toolbar indicator),
  - if the changed board belongs to the active note: open the board view
    (`isBoardVisible = true`); if it is already open, post
    `.floatnoteBoardExternallyChanged` (object = note UUID) which the board
    coordinator observes to re-run `loadScene()`.

## Accepted Edge Cases

- Concurrent human + MCP edits to the same board: last write wins; a reload may
  drop up to ~0.8s of debounced, unsaved strokes. Rare by construction.
- `add` mode auto-shift is bounding-box based; it does not pack around
  irregular layouts.

## Out of Scope

- Deleting boards via MCP (use `draw_on_board` with `mode: "replace"` and an
  empty `shapes` array to clear).
- Freedraw, images, frames, and other advanced Excalidraw element types.
