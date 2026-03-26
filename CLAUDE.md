# FloatNote macOS App

## Build & Deploy
After ANY code change, run `./build.sh` to rebuild and update the app in `/Applications/FloatNote.app`.

Do NOT just run `swift build` — the app bundle in /Applications must be updated too.

## Project Layout
- `FloatNote/FloatNote/App.swift` - SwiftUI app, views, ViewModel, editor
- `FloatNote/FloatNote/EvernoteAPI.swift` - Evernote Thrift binary protocol client
- `FloatNote/Package.swift` - SPM manifest (macOS 14+)
- `.auth.json` - Auth tokens (auto-refreshed by the app)
- `build.sh` - Build + deploy script

## Key Details
- Auth token path hardcoded in App.swift: `/Users/cagdas/CodTemp/myevernote-macos-app/.auth.json`
- App auto-refreshes expired tokens via refresh_token grant
- Single-note editor syncing to Evernote notebook `bf100d62-31b3-ac11-298c-6a90ae689031`
- Local backup at `~/.evernote-editor-local.html`

## Editor Features
- **Toolbar**: Minimal plain-style buttons with hover highlights, flexible layout (all buttons visible at any width)
- **Undo/Redo**: All programmatic edits (checkbox toggle, bullet/checklist continuation, indent/outdent, format toolbar, slash commands) are undoable via snapshot-based undo registration
- **Tab/Shift-Tab**: Indent (4 spaces) / outdent selected lines or list items
- **List insert**: Pressing bullet/checklist at the beginning of an existing list line inserts a new line above and pushes the current line down
