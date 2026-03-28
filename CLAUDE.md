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

## Versioning
- Version constant `APP_VERSION` is at the top of `App.swift` — bump it on each update
- Displayed in the status bar (bottom right)

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
- **Smart Home**: Cmd+Left jumps to after list prefix first, then to column 0 on second press
- **Smart Select**: Cmd+Shift+Left extends selection to after prefix, mirroring smart home
- **Smart Backspace**: Backspace at/inside a list prefix removes the entire prefix; Cmd+Backspace deletes to prefix boundary first, then removes prefix on second press
- **Move lines**: Option+Up/Down swaps lines, preserving caret position
- **Dictation auto-restart**: When mic is enabled, dictation auto-restarts after system timeout or when app regains focus
