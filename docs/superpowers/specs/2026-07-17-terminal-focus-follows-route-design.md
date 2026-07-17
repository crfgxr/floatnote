# Terminal Focus Follows Route — Design

**Date:** 2026-07-17
**Status:** Approved for implementation

## Problem

When a note's terminal panel opens (auto-routed on note switch, launch, chip tap,
toolbar toggle), keyboard focus stays in the note editor. The user starts typing
a shell command and it lands in the note. Expected: when a terminal is presented
for a note, typing goes to the terminal — unless the user explicitly clicks into
the note.

## Principle

Focus moves to the terminal only at **discrete presentation events** — never
continuously. Clicking into the editor therefore keeps focus there until the
next navigation/presentation event. No polling, no focus-stealing while typing.

## Events that focus the terminal

1. **Note switch** (`switchTab`) landing on a routed note → panel opens/switches → focus terminal.
2. **Launch** (`load`) when the initial note is routed.
3. **Chip tap** (`selectTerminal`) — including chips that map to no folder (HOME, override paths).
4. **New terminal tab** — `+` button and Cmd+N (`addTerminal`).
5. **Toolbar show/toggle** (`showTerminal`).
6. **Linking a route for the active note** (`linkFolder`, `setNoteFolderOverride`) — via their `applyTerminalRouteForActiveNote()` call.
7. **Unpin restore** (both the route re-apply and the `showTerminal` fallback).

## Carve-outs (editor keeps/gets focus)

- **New note** (`addTab`): the user is about to type the title. The route still
  applies (panel may open), but focus goes to the editor —
  `applyTerminalRouteForActiveNote(focusTerminal: false)` + `focusEditor()`.
- **Unrouted navigation** (hide branch of `applyTerminalRouteForActiveNote`):
  if focus was inside a terminal that's now hiding, move it to the editor so
  typing isn't stranded on a hidden view. If focus was elsewhere (sidebar,
  find bar), leave it alone.

## Implementation

All in `EditorViewModel` (`@MainActor`), plus one deletion in `AppDelegate`:

- `focusActiveTerminal()` / private `focusTerminal(_ id:attempt:)` — makes the
  session's `LocalProcessTerminalView` first responder. The panel/view may still
  be mounting when called (SwiftUI needs a tick after `isTerminalVisible` flips),
  so it retries every 60 ms, up to 8 attempts, bailing if the tab was closed or
  a different terminal became active meanwhile.
- `focusEditor()` — `makeFirstResponder(editorCoordinator?.textView)`.
- `applyTerminalRouteForActiveNote(focusTerminal: Bool = true)` — route branch
  calls `focusActiveTerminal()` when the flag is set; hide branch captures
  "was focus in a terminal?" (`TerminalSessions.shared.id(containing:)`) before
  hiding and calls `focusEditor()` only then.
- `showTerminal`, `selectTerminal`, `addTerminal` — append `focusActiveTerminal()`.
- `AppDelegate` Cmd+N handler — drop its now-redundant local `focusTerminal`
  helper; `vm.addTerminal()` handles focus itself.

## Not in scope

- No change to `switchToRoute` dedup, hide ≠ kill semantics, or the no-ping-pong
  reverse-routing guarantee (double-focusing the same view is a no-op).
- No persistent "user prefers editor" state: an explicit click into the note
  holds focus only until the next presentation event, matching the request
  ("unless user selects note window").

## Addendum: caret hides while the editor is unfocused (v1.49.1)

The editor's block caret is a custom always-on `NSView` subview of
`BlockCaretTextView` (the system insertion point is suppressed), so it stayed
visible while the terminal owned the keyboard — reading as "typing goes here"
when it didn't. Fix: `becomeFirstResponder`/`resignFirstResponder` overrides
maintain an `isEditorFocused` flag, and `updateCaretPosition()` — the single
choke point every caret move goes through — hides the caret when there's a
selection (existing rule) or the view isn't first responder. Clicking into the
note or any programmatic `focusEditor()` restores it. Window-level key status
(app in background) is out of scope.

## Verification

Manual (AppKit first-responder behavior; no unit-test seam): switch to a routed
note → type → characters land in the shell; click into the note → typing lands
in the note; switch away to an unrouted note and back → terminal focused again;
new note in a project folder → typing lands in the note title; Cmd+N / `+` /
chip tap / toolbar toggle → terminal focused.
