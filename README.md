# FloatNote

A native macOS floating rich text editor. Fully local — no cloud sync.

## Features

- **Rich text editing** — Bold, italic, underline, headings (H1/H2/H3), links, dividers
- **Checklist** — Clickable checkboxes with strikethrough for checked items, auto-continuation on Enter
- **Bullet lists** — With auto-continuation on Enter
- **Tabs** — Multiple note tabs, each saved independently
- **Offline-first** — Data stored locally at `~/.floatnote-local.html` and `~/.floatnote-tabs.json`
- **Dictation** — System dictation with auto-restart on timeout or app refocus
- **Audio recording** — Record system audio + microphone per tab, stored as .m4a
- **Transcription** — Deepgram-powered transcription (English, Turkish) with AI summary
- **Pin window** — Keep the editor floating above other windows
- **Dark theme** — Dark background with light text, block caret
- **MCP server** — Exposes notes to Claude via Model Context Protocol

## Build

After any code change:
```
./build.sh
```
This rebuilds the release binary and updates `/Applications/FloatNote.app`.

## Architecture

- `FloatNote/FloatNote/App.swift` — SwiftUI app, views, ViewModel, rich text editor
- `mcp-server.js` — MCP server exposing FloatNote notes to Claude
