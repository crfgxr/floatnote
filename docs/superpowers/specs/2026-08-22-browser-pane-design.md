# Browser Pane — Design

Date: 2026-08-22

A tabbed browser inside FloatNote, to the right of the terminal panel, that **Claude Code can read and
drive** from the terminal it is already running in. Claude Code Desktop shipped this as its Browser
pane (⌘⇧B, week 28); this is the same capability for FloatNote, built on `WKWebView` and reachable
over MCP.

The point is not "a browser in my notes app". The point is that the agent in the terminal pane can
open the page it is talking about, read it, click through it, and screenshot it — without a second
app, without Accessibility permission, and without leaving the window the conversation lives in.

---

## Layout

```
sidebar │ editor │ terminal panel │ browser panel
```

- A fourth column, right of `TerminalPanel`, with its own `BrowserResizeHandle` and width
  (`fn.browserWidth`, default 520).
- Visibility `fn.browserVisible` (`vm.isBrowserVisible`), toggled by a toolbar **globe** button, the
  **View ▸ Browser** menu item, and **⌘⇧B** (app-wide, in the existing `AppDelegate` key monitor).
- `availablePanelWidth()` must subtract the browser panel's width so the terminal panel can never be
  rendered wider than the window; the browser panel gets the same treatment against the terminal's.
- Hiding unmounts the view only. Pages live in `BrowserSessions`, exactly as shells live in
  `TerminalSessions` — hiding ≠ killing, and there is no teardown in `dismantleNSView`.

## Model and lifecycle

`Browser.swift` owns everything Swift-side.

```swift
struct BrowserTab: Identifiable, Codable, Equatable {   // persisted in fn.browserTabs
    let id: UUID
    var url: String        // last committed URL
    var title: String      // last known title, "" until the page reports one
}

final class BrowserSessions: ObservableObject {          // singleton, like TerminalSessions
    static let shared: BrowserSessions
    @Published private(set) var tabs: [BrowserTab]
    @Published var activeTabId: UUID?
    func webView(for id: UUID) -> WKWebView              // lazily created, cached, never dropped on hide
    func open(_ url: String, newTab: Bool) -> UUID
    func close(_ id: UUID)
    func navigate(_ id: UUID, to url: String)
    func back(_ id: UUID) / forward / reload / stop
}
```

- **Clean profile by default**: `WKWebsiteDataStore.nonPersistent()`, matching Claude Desktop's
  "separate from your personal browser" rule. `fn.browserPersistSession = true` switches to
  `.default()` so logins survive a relaunch. Changing it recreates the web views.
- Tabs (url + title, not history) persist so a relaunch restores the pages; the empty state opens one
  tab on `about:blank`.
- `WKNavigationDelegate` keeps `url`/`title`/`isLoading` on the tab; `estimatedProgress` drives a
  hairline progress bar. New-window/target=_blank requests open a new tab rather than being dropped.
- The web view is configured with `allowsBackForwardNavigationGestures = true`,
  `customUserAgent = nil` (Safari's own UA), and developer extras enabled
  (`isInspectable = true` on macOS 13.3+, so Web Inspector works while debugging).

## Chrome

Two rows above the page, painted in the terminal palette (`TerminalSessions.currentPalette()`), so
the two panels read as one surface:

1. **Tab bar** — one chip per tab (title, or host when the title is empty), ✕ per chip, `+` at the
   end, active chip painted in the palette's foreground/background pair.
2. **Toolbar** — back, forward, reload/stop, a URL field, and open-in-default-browser. The field
   navigates on Enter: a string that parses as a host or has a scheme becomes a URL (`https://`
   prepended when missing), anything else becomes a DuckDuckGo query.

No bookmarks, no history UI, no downloads in v1.

## Claude access — the RPC

`mcp-server.js` runs in a separate node process, so the same file-spool pattern the rest of the app
uses carries the calls. Directory `~/.floatnote-browser-rpc/`:

```
<uuid>.req.json   written by the MCP server, temp+rename
<uuid>.res.json   written by FloatNote,     temp+rename, then the request is deleted
```

Request: `{ "id": "<uuid>", "action": "...", "params": { ... }, "ts": <epoch seconds> }`
Response: `{ "id": "<uuid>", "ok": true, "result": { ... } }` or `{ "id", "ok": false, "error": "..." }`

FloatNote consumes requests from a `DispatchSource` vnode watcher on the directory **and** the
existing 2-second `AppDelegate` timer as the safety net (a watcher misses events if the directory is
recreated) — the External File Sync convention. Requests older than 60s are answered with an error
and deleted, so a crashed call can never be replayed later. Every action logs one
`browser: <action> …` line to `~/.floatnote-debug.log`.

### Actions

| action | params | result |
| --- | --- | --- |
| `tabs` | — | `{tabs: [{id, url, title, active}]}` |
| `open` | `url`, `newTab` (default true) | `{id, url}` |
| `activate` | `id` | `{id}` |
| `close` | `id` | `{closed: id}` |
| `navigate` | `id?`, `url` | `{id, url}` |
| `back` / `forward` / `reload` | `id?` | `{url}` |
| `read` | `id?`, `format` (`text`\|`html`), `maxChars` (default 60000) | `{url, title, format, content, truncated}` |
| `click` | `id?`, `selector?`, `text?` | `{hit: true, matched: "<tag> <text>"}` |
| `type` | `id?`, `selector`, `text`, `submit` (default false) | `{typed: n}` |
| `eval` | `id?`, `js` | `{value}` (JSON-encoded, 20k cap) |
| `screenshot` | `id?`, `fullPage` (default false) | `{path}` — PNG under `~/.floatnote-browser-shots/` |
| `wait` | `id?`, `selector?`, `ms?` (default 1000, max 15000) | `{found: bool, waitedMs}` |

`id` defaults to the active tab. Navigation actions resolve once the page fires
`didFinish` (or after a 15s ceiling), so `open` followed by `read` needs no sleep on the caller side.

`click`, `type` and `wait(selector:)` are implemented as injected JS: `querySelector` when a
`selector` is given, else a case-insensitive visible-text match over
`a, button, [role=button], input[type=submit], summary, [onclick]`. A miss is `ok: false` with the
selector echoed, never a silent success.

### MCP tools

One tool per action group, thin wrappers over the RPC with a 20s default timeout (35s for
`screenshot` and `wait`):

`browser_tabs`, `browser_open`, `browser_read`, `browser_click`, `browser_type`, `browser_eval`,
`browser_screenshot`, `browser_navigate` (back/forward/reload/goto), `browser_close`.

`browser_screenshot` returns the PNG as an image content block (the pattern `read_note` already uses
for inline images), so Claude sees the page rather than a path.

A call that gets no response inside the timeout returns
"FloatNote isn't running, or its browser panel has never been opened" — the honest diagnosis, since
the app is what executes these.

### Write actions and safety

Claude Code in the terminal already has shell access to this machine, so a JS eval in a sandboxed
web view adds no privilege. Two guards, both cheap:

- `fn.browserAllowClaudeWrites` (default **true**): when off, `click`/`type`/`eval` are refused with
  `write actions are disabled in FloatNote's browser settings`, while `read`/`screenshot`/navigation
  keep working.
- Every request is logged before it runs, so what the agent did to a page is recoverable after the
  fact.

Unlike Claude Desktop there is no per-domain approval card and no classifier: this is a personal,
local, single-user app, and a modal per site would make the feature unusable in a terminal-driven
loop. The clean-profile default is what keeps it away from logged-in sessions.

## Build order

1. `Browser.swift`: sessions, web view, delegates, tab bar, toolbar, panel. Panel visible via a
   toolbar button; no RPC yet.
2. App shell: `vm.isBrowserVisible` / `browserWidth`, placement, resize handle, ⌘⇧B, View menu.
3. RPC executor in `Browser.swift` + watcher registration in `AppDelegate`.
4. MCP tools in `mcp-server.js`.
5. CLAUDE.md section.

## Testing

Manual, from the terminal pane that ships it (the loop this feature exists for):

1. `browser_open` a documentation URL → the pane shows it, a tab chip appears.
2. `browser_read` → the page's text comes back, truncated with a marker at `maxChars`.
3. `browser_screenshot` → the image comes back inline and matches what is on screen.
4. `browser_click` by text, then `browser_read` → the new page's content, proving the click landed.
5. `browser_type` into a search field with `submit: true` → results page.
6. Hide the panel, `browser_read` again → still answered (pages live in `BrowserSessions`).
7. Quit and relaunch → tabs restored, `browser_tabs` lists them.
8. `fn.browserAllowClaudeWrites = false` → `click` refused, `read` still fine.
9. Two panes on one project, both running Claude → both drive the same browser (it is app-global, not
   per pane); the log shows which action came from which request id.
