# Image Attachments in Notes — Design

**Date:** 2026-07-22
**Status:** Approved (user picked: paste + toolbar attach, corner drag handle resize, double-click does nothing; deliberately basic)

## Problem

Notes can't hold images. Wanted: paste a screenshot or attach an image file,
see it inline, resize it directly — nothing more (no drag-drop insert, no
captions, no editing, no Quick Look).

## Core constraint

Notes persist as HTML via Cocoa's HTML importer/exporter
(`htmlToAttributedString` / `extractHTML`), which does NOT round-trip
`NSTextAttachment` images. Base64 data-URLs inline would bloat
`~/.floatnote-tabs.json` (rewritten every save, polled every 2s) — rejected.
Switching to RTFD upends the persistence format — rejected.

## Design: file store + plain-text markers

- **ImageStore** — owns `~/.floatnote-images/`; `savePNG(NSImage) -> id`
  (any input normalized to PNG, `<UUID>.png`, temp+rename), `load(id)`,
  `delete(id)`, `url(id)`. Same one-dir-of-files pattern as recordings/boards.
- **ImageAttachment: NSTextAttachment** — carries `imageId` + `displayWidth`;
  bounds = displayWidth × (displayWidth/aspect). Initial width =
  min(natural point width, editor text width).
- **Marker round-trip** — the persisted HTML never contains the attachment:
  - Save: `extractHTML` exports a mutable copy where every ImageAttachment
    char is replaced by the plain text `⟦img:<uuid>:<width>⟧` (U+27E6/27E7
    brackets; plain text survives the Cocoa exporter byte-for-byte).
  - Load: a pass at the end of `htmlToAttributedString` (single choke point —
    launch, tab switch, reload, external merge all flow through it) regex-swaps
    markers back into ImageAttachments. Missing file → dimmed literal
    "missing image" text.
  - Sidebar title derivation strips markers/attachment chars; `☐` badge
    counting is untouched (markers contain neither glyph).
- **Paste** — `BlockCaretTextView.paste` override: image-file URLs on the
  pasteboard (Finder copy) first, else raw image data (screenshots, browser
  copies) → ImageStore → insert via `insertText(_:replacementRange:)` at the
  caret (native undo). Non-image pasteboards fall through to `super.paste`.
  Unreadable image → beep, no-op.
- **Toolbar attach** — `photo` SF-symbol button in `FormatToolbar` →
  `NSOpenPanel` (image content types) → same insert path.
- **Resize** — click an image → select its attachment char (native selection
  highlight) + overlay a bottom-right accent handle (caretView-style subview).
  Dragging the handle scales width live (aspect locked, min 60pt, max editor
  text width) by mutating attachment bounds + invalidating layout; mouse-up
  persists `displayWidth`, registers undo (restore old width), and triggers
  the save pipeline via `didChangeText()`. Selection change / text change /
  image deselect hides the handle. Double-click: nothing special.
- **Lifecycle** — permanent note delete + empty trash scan the note's HTML for
  markers and delete the referenced files (mirrors the Excalidraw cascade);
  trashing keeps them. Inline image deletion leaves the file (undo needs it);
  orphans tolerated by design.

## Out of scope

Drag-drop insert, captions, crop/rotate, Quick Look, MCP image exposure,
orphan GC sweep.

## Verification (manual)

Paste a screenshot → renders inline at fitting width; resize via handle →
width survives quit/relaunch; attach via toolbar; copy image in Finder →
paste works; note with images round-trips through app restart and tab
switches; permanent delete removes the PNGs; badges/titles unaffected;
plain-text paste unaffected.
