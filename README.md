# FloatNote

A native macOS floating rich text editor. Fully local — no cloud sync.

## Features

- **Rich text editing** — Bold, italic, underline, headings (H1/H2/H3), links, dividers; empty notes type as Body (titles live in the sidebar)
- **Checklists & bullets** — Clickable checkboxes with strikethrough, auto-continuation on Enter, drag-to-reorder, smart Home/Backspace
- **Sidebar with folders** — Nestable folders, drag-and-drop, virtual Trash with restore, red unchecked-item badges per note
- **Project folders + terminal** — Link a folder to a local directory and its notes get an integrated terminal panel (SwiftTerm) rooted there; keyboard focus follows the terminal, and Claude Code auto-resumes per project
- **Excalidraw boards** — A fully offline whiteboard per note, toggled from the toolbar
- **Opens where you left off** — Cold start restores the last-open note
- **Themes & fonts** — Multiple editor themes (incl. Solarized), font family + body size pickers
- **Dictation** — System dictation with auto-restart on timeout or app refocus
- **Audio recording** — Record system audio + microphone per note, stored as .m4a, with in-app playback
- **Transcription & AI summary** — Deepgram-powered transcription (English, Turkish), OpenRouter-powered meeting summaries
- **Pin window** — Compact floating note pinned above other windows
- **MCP server** — Exposes notes, folders, and boards to Claude via Model Context Protocol
- **Offline-first** — Data stored locally: `~/.floatnote-local.html`, `~/.floatnote-tabs.json`, `~/.floatnote-folders.json`, `~/.floatnote-recordings/`, `~/.floatnote-excalidraw/`

## Build

After any code change:
```
./build.sh
```
This rebuilds the release binary, signs it with the "FloatNote Dev" identity (create once with `docs/dev-signing-cert.sh`), and updates `/Applications/FloatNote.app`.

## Architecture

- `FloatNote/FloatNote/App.swift` — SwiftUI app, views, ViewModel, rich text editor
- `FloatNote/FloatNote/Terminal.swift` — Terminal sessions (SwiftTerm) and Claude auto-resume
- `FloatNote/FloatNote/Excalidraw.swift` — Excalidraw board storage + WKWebView bridge
- `FloatNote/FloatNote/DesignTokens.swift` — Themes, typography, spacing tokens
- `mcp-server.js` — MCP server exposing FloatNote notes to Claude
- `vendor/excalidraw/` — esbuild bundling of Excalidraw for offline use (`./vendor-excalidraw.sh`)
