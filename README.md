# MyEvernote

A native macOS rich text editor that syncs to Evernote.

Built with SwiftUI + NSTextView, communicating with Evernote's Thrift binary protocol directly — no official SDK needed.

## Features

- **Rich text editing** — Bold, italic, underline, headings (H1/H2/H3), code, links, dividers
- **Checklist** — Clickable checkboxes with strikethrough for checked items, auto-continuation on Enter
- **Bullet lists** — With auto-continuation on Enter
- **Auto-sync** — Debounced sync to Evernote (2s after edits), with local backup on every keystroke
- **Offline-first** — Local HTML backup at `~/.evernote-editor-local.html`, works without internet
- **Auto token refresh** — JWT access tokens refresh automatically when expired
- **Pin window** — Keep the editor floating above other windows
- **Dark theme** — Dark background with light text, block caret

## Setup

1. Install dependencies for the login helper:
   ```
   npm install
   ```

2. Authenticate with Evernote:
   ```
   node login.js
   ```
   This opens a browser window to capture your auth token into `.auth.json`.

3. Build and run:
   ```
   ./build.sh
   ```

## Build

After any code change:
```
./build.sh
```
This rebuilds the release binary and updates `/Applications/MyEvernote.app`.

## Architecture

- `MyEvernote/MyEvernote/App.swift` — SwiftUI app, views, ViewModel, rich text editor
- `MyEvernote/MyEvernote/EvernoteAPI.swift` — Evernote Thrift binary protocol client
- `login.js` — Playwright-based browser login to capture auth tokens
- `cli.js` — Node.js CLI for Evernote operations
- `evernote-api.js` — Node.js Evernote API client
