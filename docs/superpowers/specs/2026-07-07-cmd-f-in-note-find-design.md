# Cmd+F In-Note Find (Native Find Bar)

**Date:** 2026-07-07
**Status:** Approved

## Goal

Pressing Cmd+F opens a find bar to search text inside the currently open note.

## Approach

Use AppKit's built-in `NSTextFinder` find bar on the editor's `BlockCaretTextView` / `NSScrollView` pair. No custom UI.

## Behavior

- Cmd+F opens the standard macOS find bar at the top of the note editor.
- Incremental search: matches highlight as you type, with a match count.
- Enter / Cmd+G → next match; Shift+Cmd+G → previous; Esc dismisses the bar and returns focus to the note.
- Fires whenever a note is showing, including when focus is in the sidebar.
- Does **not** fire when the first responder is inside a terminal pane — the terminal keeps its own keys (same scoping guard as Cmd+N).
- No-op while the Excalidraw board view is open (no text to search).

## Implementation

1. **Enable the finder** in `RichTextEditor.makeNSView` (`App.swift`):
   - `textView.usesFindBar = true`
   - `textView.isIncrementalSearchingEnabled = true`
2. **Capture Cmd+F** in the existing local `NSEvent` key monitor in `AppDelegate` (the one that already scopes Cmd+N / Cmd+W):
   - If `TerminalSessions.shared.id(containing: firstResponder)` matches, pass the event through unchanged.
   - If the board view is visible for the active note, pass the event through.
   - Otherwise: make the editor text view first responder, send it `performTextFinderAction(_:)` with the `.showFindInterface` action tag, and swallow the event. The monitor reaches the text view via `vm.editorCoordinator`.
3. Bump `APP_VERSION`; rebuild with `./build.sh`.

## Edge Cases

- **Note switch while the bar is open:** `NSTextFinder` is per-text-view and the text view is reused across notes. Replacing the text storage content should invalidate stale highlights automatically; verify during implementation, and if stale highlights persist, dismiss the bar on note switch (`performTextFinderAction` with `.hideFindInterface`).

## Testing (manual)

- Cmd+F from the editor and from the sidebar opens the bar.
- Typing highlights matches and shows a count; Cmd+G / Shift+Cmd+G cycle; Esc closes.
- Cmd+F with focus inside a terminal does nothing to the note.
- Board view open → Cmd+F does nothing.
- Switching notes with the bar open leaves no stale highlights.
