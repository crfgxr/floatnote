# Transcript Pane — Design

Date: 2026-08-22

Render the conversation that is already running in a FloatNote terminal a second time — as typeset
prose, from Claude Code's own session JSONL — in a pane stacked above the terminal inside the
existing terminal panel. The terminal keeps the TUI and the keyboard; the transcript pane keeps the
reading.

## Why

Claude Code draws its interface by counting columns. Boxes, tables, diff gutters, spinners and the
input frame are all built out of cells on a fixed monospaced grid, and every one of them assumes
`advance(ch) == advance(' ')`. That is the whole reason the terminal can't be made to look like
Claude Desktop:

- **A proportional face breaks the grid.** The moment `i` is narrower than `m`, every box-drawing
  run, every right-aligned column, every progress bar mis-registers. This is not a SwiftTerm
  limitation we could patch out in `vendor/swiftterm-*.patch` — it is what a terminal *is*.
- **Line height is a cell height.** `extraLineSpacing` (our own vendored knob) can push rows apart,
  but 1.6× leading on a cell grid stretches the boxes too; you get airy ASCII art, not typeset prose.
- **There is no inline formatting layer.** Bold is SGR 1, a code span is a color change. Rounded code
  chips, hanging indents, a real blockquote rule, a serif body with lining figures — none of these
  exist as terminal concepts. CLAUDE.md already records this conclusion from the palette work: *"A
  terminal can't copy Claude Desktop's typography… Only the paint and the code font transfer."*

So stop trying. The conversation is already on disk in a structured form. Read it, and typeset it
properly beside the thing that produced it. The terminal remains the only place you type — the
transcript is read-only by construction, which removes an entire class of sync problems.

---

## Data source

### Location

```
~/.claude/projects/<munged-cwd>/<sessionId>.jsonl        ← the conversation
~/.claude/projects/<munged-cwd>/<sessionId>/subagents/**/agent-<id>.jsonl
~/.claude/projects/<munged-cwd>/<sessionId>/tool-results/<hash>.txt
```

`<munged-cwd>` is already computed by `TerminalSession.mungedClaudeProjectDirName(for:)`
(`Terminal.swift:343-348`) — pure, static, and already parameterized for use outside the shell path.
The filename stem is *always* exactly the `sessionId` carried inside every record (verified for all
16 files in this project's store).

### Finding the live file for a pane — the hard part

`TerminalTab.path` does **not** identify a conversation. Several panes legitimately share one cwd
(that is why `TerminalTab.noteId` exists), and `addTerminal()` deliberately sets `freshClaude`, which
starts a *new* `.jsonl` in the same store directory. This project's store already holds 16 of them.
"Newest mtime in the munged dir" flips between panes as each takes a turn, and it also loses to
SDK-driven runs — 10 of those 16 files are `entrypoint: "sdk-py"` (security-review, code-review),
written into the same directory, interleaved with the live CLI session.

Resolution ladder, best first:

| # | Source | Reliability | When it applies |
| --- | --- | --- | --- |
| 1 | `TerminalTab.claudeSessionId` / `claudeTranscriptPath`, learned from the hook | **Authoritative** — Claude Code itself said so | From that pane's first `Stop`/`Notification` event onward |
| 2 | `~/.claude.json` → `.projects["<real cwd>"].lastSessionId` | Correct for the cwd, ambiguous across panes | Cold start, before any hook event |
| 3 | Newest-mtime `*.jsonl` in the munged dir **whose records carry `entrypoint == "cli"`** | Guess | Last resort |
| 4 | Last matching `project` entry in `~/.claude/history.jsonl` | Guess | If (3) finds nothing |

Steps 2–4 are shown as **provisional** (a dimmed "best guess" chip in the pane header with a
"choose session…" affordance). Do not present them as authoritative — with two panes on one cwd,
step 2 is wrong roughly half the time.

Step 1 requires a two-field change to `docs/floatnote-claude-hook.sh`. Claude Code's hook payload
already carries the disambiguator on **every** event (verified in the 2.1.239 binary: the shared
base schema is `{session_id, transcript_path, cwd, prompt_id, permission_mode, agent_id, agent_type,
effort}`); our script throws both away before Swift sees them:

```python
"session_id": data.get("session_id", ""),
"transcript_path": data.get("transcript_path", ""),
```

`checkClaudeEvents()` (App.swift:1001-1041) then stamps them onto the resolved `TerminalTab`. Per
CLAUDE.md the repo copy is only the source of truth — reinstall to `~/.claude/hooks/floatnote-notify.sh`.
Old installs simply omit the fields, and the pane degrades to the provisional ladder; that is the
same graceful-degradation shape `last_assistant_message` already has.

> **Do not** add a second reader of the event spool. `checkClaudeEvents` is destructive and one-shot
> (`defer { removeItem }`, App.swift:1005-1007). The transcript binding must be written from *inside*
> that consumer.

`~/.claude.json`'s sibling `lastSessionModified` is **stale by months** (measured 2026-05-03 against
a file being written at 2026-08-22). Never use it for liveness.

### What is rendered, what is skipped

There are 20 distinct top-level `type` values across all projects on this Mac. Twelve of them are
mutable session-state snapshots with no `uuid`, `timestamp`, `cwd` or `message` at all, re-appended
dozens of times per session with an unchanging value (one file holds 56 `ai-title` records, all the
identical string). **Filter first, then do anything else.**

| Record | Disposition | Why |
| --- | --- | --- |
| `assistant` / `text` block | **Render** — markdown → prose | The whole point |
| `assistant` / `thinking` block | **Skip** | There is nothing to render: 6 211 of 6 211 thinking blocks on this machine are `"thinking": ""` with only an opaque `signature` |
| `assistant` / `tool_use` block | **Collapsed one-liner** (`Read · Terminal.swift`), off by default | Structure, not prose |
| `user` with `origin.kind == "human"` / `promptSource` | **Render** — user bubble | A person spoke |
| `user` with `toolUseResult` + `sourceToolAssistantUUID` | **Skip** (or fold into the tool one-liner) | 814 of 1 061 `user` records in this project are tool results |
| `user` with `isMeta: true` | **Skip** | System injections like `[Image: source: …/image-cache/…/1.png]` — 79 of them |
| `user` with `isCompactSummary: true` | **Render as a summary card**, not as speech | It is machine-written continuation text |
| `system` / `compact_boundary` | **Render as a section rule** | "Conversation compacted — 978 360 tokens dropped" |
| `system` / other subtypes (`turn_duration`, `stop_hook_summary`, `local_command`, `away_summary`, `bridge_status`) | **Skip** in v1 | `local_command` is a candidate for a slash-command chip later |
| `attachment` (16 subtypes) | **Skip** | Context injections, not conversation |
| `last-prompt`, `ai-title`, `mode`, `permission-mode`, `atis-latch`, `file-history-*`, `queue-operation`, `bridge-session`, `agent-setting`, `frame-link`, `agent-name`, … | **Skip** | No uuid, no timestamp, no message; pure state churn |
| Anything in `<sessionId>/subagents/**` | **Skip in v1** (phase 5) | `isSidechain: true` appears *only* there — 1 862 lines, never in the main file |

Two structural rules that a naive reader gets wrong:

1. **Assistant records carry exactly one content block — never an array.** One API turn is exploded
   into up to 6 consecutive `assistant` lines. Rendering each as its own turn produces a shredded
   transcript. Regroup by `requestId` (fall back to `message.id`). Measured distribution: 298 turns ×
   1 record, 303 × 2, 187 × 3, 20 × 4, 10 × 5, 1 × 6.
2. **`message.usage` and `stop_reason` are duplicated verbatim on every block record of a turn.**
   Take them from exactly one record per group or token counts come out 4× too high.

### Ordering — file order, and only file order

- **Never sort by `timestamp`.** Timestamps are non-monotonic: 30–42 inversions per file, including a
  17-second backward jump, and at every compact boundary the summary's timestamp *precedes* the
  boundary written before it.
- **Never walk `parentUuid` backward from the tail.** `/compact` writes `parentUuid: null` on its
  boundary record (8 times in one 33 k-line file), severing the chain; the bridge is the non-standard
  `logicalParentUuid`.
- **File order is a valid topological order.** `parentUuid` never points forward (0 forward references
  across 24 183 uuids). Sequential reading has neither problem.
- The uuid graph forks (150/952 uuids have 2+ children). Almost all forks are `attachment/hook_success`
  sharing a `tool_use` parent with the real `tool_result` — but genuine conversational forks occur (a
  measured human double-submit 13 s apart). A single-chain reconstruction silently drops a branch.
  Sequential reading renders both, which is the honest answer.

### Tailing

Files are **strictly append-only**, which is what makes offset tailing safe rather than merely
convenient: a live file's byte prefix was bit-identical as it grew from 103 888 → 333 454 B (md5 of
the first 50 000 B constant throughout), the inode stayed stable, no uuid was ever written twice, and
every line of every file parsed as complete JSON.

```
TranscriptTail (private serial queue)
  ├─ open(path, O_EVTONLY) → DispatchSource vnode, mask [.write, .extend, .delete, .rename, .link]
  ├─ hold `offset: UInt64` = bytes consumed
  ├─ on event: seek(toOffset: offset) → readToEnd() → split on \n
  │     · buffer everything after the LAST \n as a partial line, never parse it
  │     · offset += consumed complete bytes
  ├─ if size < offset  → file was replaced/truncated: reset offset = 0, full re-ingest
  ├─ on .delete/.rename → close fd, re-open BY PATH (Claude Code has explicit transcript-path
  │     recovery/latching: `tengu_transcript_writer_recovered`, `abandonedPaths`)
  └─ safety net: a size+mtime check on the existing 2s AppDelegate timer, exactly as
        startClaudeEventWatcher pairs with that timer today
```

The partial-line buffer is not an edge case: the largest single line in this project's live transcript
is 839 669 bytes against a 7 527-byte average (and 4.72 MB elsewhere on this Mac). Any read triggered
mid-append lands inside a line.

The existing app watcher precedent (App.swift:1047-1066) watches a *directory* and delivers on
`.main`. Neither carries over: this one binds to a file fd and must deliver on a background queue.

> **Cadence conflict, stated explicitly.** The layout investigation observed the file not growing
> across ~10 tool calls inside a turn ("writes land in bursts at turn boundaries"); the JSONL
> investigation measured a live file tripling in size *during* a turn. Both are real observations of
> different files at different moments. **The design must not depend on either** — the watcher fires
> when bytes land, and the pane updates in whatever jumps it gets. Do not build a "streaming" UI
> promise on top of it.

---

## Rendering

### Chosen: a non-editable `NSTextView` fed a hand-built `NSAttributedString`

Every number in the typography section below — `minimumLineHeight`, `baselineOffset`,
`usesFontLeading` — is an AppKit measurement taken on a real `NSLayoutManager`. The app is already
TextKit 1 by hand-assembly (explicit `NSTextContainer` + `NSLayoutManager` + custom `NSTextStorage`,
App.swift:7072-7081), selection and Cmd+C come for free and correct, and theming is a direct read of
`vm.theme` / the terminal palette rather than an injected CSS variable set.

**Rejected — SwiftUI `Text` / `AttributedString(markdown:)`.** Not viable as the primary renderer.
`Text("**bold**")` parses markdown only for string *literals*; Claude's turn text is a runtime
`String`, so the asterisks render verbatim. Even with an explicit `AttributedString(markdown:)`,
`Text` ignores `PresentationIntent` — headings, lists, blockquotes and fenced code come back as runs
carrying a block intent that `Text` will not lay out, so you end up walking intent runs and emitting
one View per block: *more* code than the AppKit path, with less control. Foundation's parser is
CommonMark-only (no tables, no strikethrough, no task lists) and `.textSelection(.enabled)` does not
span views, so a reader could not drag-select a turn that contains a heading plus a code block.

**Rejected — `WKWebView`.** Highest fidelity by a wide margin (real `<pre>`, real `<blockquote>`, real
`<table>`, serif body in one declaration) and there is strong in-repo precedent (`ExcalidrawBoardView`
already does message handlers, `loadFileURL` from `Bundle.module`, `drawsBackground = false`). It
loses on integration cost, and the costs are all real: you still need a markdown parser — in JS it
means a second `vendor-*.sh` bundler pipeline, in Swift it means writing the same parser and then
serializing to HTML instead of to attributes; `AppTheme`'s colors are static `NSColor`s chosen per
theme, *not* dynamic system colors, so `prefers-color-scheme` is useless and all five themes would
have to be pushed in as CSS custom properties; and every new bundled asset needs both a `.copy(...)`
in `Package.swift` and build.sh's `.build/release/*.bundle` step or the pane loads blank.

Revisit WKWebView only if GFM tables with real column layout become a hard requirement.

### What must not be reused

| Do not touch | Why |
| --- | --- |
| `RichTextEditor` (App.swift:7063) | `makeNSView` unconditionally claims four singleton slots — `vm.captureScrollState`, `vm.restoreScrollState`, `vm.onContentLoaded`, `vm.editorCoordinator`. A second instance hijacks all four and the note editor stops loading, saving and scrolling |
| `BlockCaretTextView` (App.swift:5802) | `isEditable = false` does **not** disable its `mouseUp` checkbox toggling, drag-to-reorder, custom `copy`/`paste`, undo chain, or the block caret |
| `htmlToAttributedString` (App.swift:2350) | Hardcoded CSS, a frozen 24/19/16/14 size ladder that ignores `Tokens`, and a color-flattening heuristic that overwrites every non-blue foreground. It would erase code-block tinting and blockquote muting on sight |
| `vm.onContentLoaded` / `applyListIndentToAllLines` | They mutate the live editor storage |
| The editor's centering/inset closure | Setting `textContainerInset` re-posts `frameDidChangeNotification` into the same closure; without the `coord.isUpdatingInset` guard it spins and hangs the app |

**Reuse unmodified:** `Tokens.Typography.editorFont(...)`, `Tokens.Spacing`,
`NSMutableParagraphStyle.readableBody()` / `.tightListItem(headIndent:)`,
`Tokens.Typography.checkboxAttributes(checked:)` + `styleCheckboxGlyph` (the `NSGlyphInfo`
substitution that makes ☐ and ☑ share rounded corners), `TerminalSessions.currentFont()` for code,
and `TerminalPalette` for the ground.

New file: **`Transcript.swift`** — `TranscriptStore` (tail + ingest + model), `MarkdownRenderer`
(markdown → `NSAttributedString`), `TranscriptView` (`NSViewRepresentable`), following the existing
`Terminal.swift` / `Excalidraw.swift` / `Images.swift` split rather than growing `App.swift`.

### Markdown subset

A hand-written two-pass renderer: a line-oriented block scanner, then an inline pass per block. About
250 lines. Foundation's parser is not used at all — it cannot do tables, strikethrough or task lists,
and we need our own block layer regardless.

**Supported**

| Construct | Rendering |
| --- | --- |
| `#` – `###` headings | SF Pro ladder below; `####`+ clamps to H3 |
| Paragraphs | Body face, `paragraphSpacing` |
| Fenced code ` ``` ` (+ language) | SF Mono block, background + border, horizontal scroll, hover copy button |
| `-` / `*` / `+` and `1.` lists | `• ` / `1. ` + tab, `headIndent` 18pt, one nesting level (level 2 → +18pt) |
| `- [ ]` / `- [x]` | ☐ / ☑ via the existing `NSGlyphInfo` substitution — read-only, no click target |
| `>` blockquote | 3pt bar, 16pt inset, muted ink; one level |
| `---` / `***` | Thematic rule at the divider color |
| GFM tables | **v1: monospaced preformatted block** (SF Mono 13, horizontal scroll). Honest and unambiguous; `NSTextTable` in phase 4 |
| `**bold**`, `*em*`, `` `code` ``, `~~strike~~`, `[t](url)`, bare `http(s)://` | Inline attributes |

**Not supported** (deliberately): raw HTML passthrough, reference links, footnotes, setext headings,
4-space indented code blocks (too many false positives from wrapped prose — Claude fences), nested
blockquotes past one level, images. Inline images render as a dimmed `[image]` chip; base64
`source.data` is dropped at ingest and never reaches the render model.

---

## Typography

Verified by resolving every candidate with `NSFont`, measuring metrics, and rendering specimens on
the actual #FAF9F5 / #262624 grounds.

**Body face: `Charter-Roman`.** Closest match to Claude Desktop's Tiempos Text in colour and texture —
x/em 0.486, x/cap **0.715** (the highest of any sturdy candidate), lowercase alphabet 204.0pt (the
most economical measured), even ink coverage 12.20, **lining figures**, and font leading 0. Its low
stroke contrast is exactly what keeps it solid at 15–16pt on both the cream and the near-black ground;
Times New Roman visibly goes spindly on the dark one.

Fallback chain: `Charter-Roman` → New York via `NSFont.systemFont(...).fontDescriptor.withDesign(.serif)`
→ `PTSerif-Regular`.

Rejected body faces, and why: **Georgia** and **Athelas** default to old-style (non-lining) figures —
dates, versions and `1.6` render below cap height and read visibly wrong against Claude Desktop, which
Tiempos does not. **New York** is unreachable by name (`NSFont(name: "New York")` and
`NSFont(name: "NewYork-Regular")` both return nil; asking for `.NewYork-Regular` silently hands you
Times New Roman *and logs a CoreText warning*), and its optical-size axis behaviour was only confirmed
on macOS 26.6.1 — this app targets macOS 14, so it stays a fallback, not the primary. **Tiempos Text,
Copernicus, Lyon Text, Source Serif, Literata, Noto Serif** are simply not installed and have no
fallback.

### Scale

| Element | Face | Size | Line height | Spacing | Notes |
| --- | --- | --- | --- | --- | --- |
| Body | Charter-Roman | 16 | **26** (min = max) | `paragraphSpacing` 12 | `baselineOffset +3.0`; 1.625 ratio; 38pt baseline-to-baseline across a break |
| H1 | SF Pro Bold | 24 | 30 | before 28 / after 10 | `kern -0.2` |
| H2 | SF Pro Semibold | 19 | 25 | before 24 / after 8 | |
| H3 | SF Pro Semibold | 16 | 22 | before 18 / after 6 | |
| List item | Charter-Roman | 16 | 26 | 6 between, 12 before/after list | `headIndent` 18, `firstLineHeadIndent` 0, tab stop 18. Marker + **tab**, not an em-space (bullet + em-space measures 25.44pt — too wide) |
| Blockquote | Charter-Roman | 15 | 24 | 12 before/after | 3pt bar, 16pt left inset, muted ink, `baselineOffset +2.0` |
| Inline code | SF Mono Regular | **14.5** | inherits 26 | — | x-height matches Charter 16 to within **0.106pt**, so it sits in the serif line without shifting it. Chip: 4pt h / 1pt v padding, r4, `baselineOffset +3.5` |
| Code block | SF Mono Medium | **13** | 19 | — | Deliberately matched to `TerminalSessions.defaultFontSize` (13 medium) rather than optically matched to the body, so code reads identically in both surfaces. 14pt h / 12pt v padding, r8, 1pt border, horizontal scroll |
| Meta line (role / time) | SF Pro Semibold | 11 | 14 | 10 below label | `kern +0.5`, uppercased. **Sans, not serif** — serifs go muddy at 11pt under grayscale-only AA |
| User bubble text | Charter-Roman | 15 | 24 | — | `baselineOffset +2.0`; one step down from Claude's |

**Measure:** 480pt maximum (66 characters at Charter 16, avg char 7.20pt), 320pt minimum, centred with
24pt horizontal padding. 400pt gives 55 chars, 520pt gives 71, 560pt gives 77. Cap at 480 so a wide
pane grows its gutters, not its measure.

### The four lines that make the scale behave

```swift
ps.minimumLineHeight = 26
ps.maximumLineHeight = 26
layoutManager.usesFontLeading = false      // ← without this, checkboxes break the grid
attrs[.baselineOffset] = 3.0               // ← without this, text sits on the floor of its box
```

Three traps, all confirmed by measurement:

1. **`lineHeightMultiple` does not multiply the point size** — it multiplies the *font's natural line
   height*. Charter at 16pt has a 20pt natural line height, so `1.625` yields **32.5pt**, 25% too tall.
   Use `min = max = 26`.
2. **`maximumLineHeight` is not an absolute clamp** — AppKit adds font leading on top of it.
   `AppleSymbols` (leading 1.34pt) serves U+2610 ☐ and U+2611 ☑, *this app's own checkbox glyphs*, so
   any line containing a checkbox renders 27.34pt and the paragraph goes visibly ragged. Charter,
   Georgia, PT Serif and New York all have leading 0, which is why plain text hides the bug until a
   checkbox appears. `usesFontLeading = false` clamps every measured case — ballot, emoji, CJK, mixed —
   to exactly 26.00.
3. **With min = max, all extra leading is added *above* the baseline.** Charter 16 in a 26pt box puts
   the baseline at 22.00 — 6.32pt above the ascender, 0.16pt below the descender. Descenders nearly
   collide with the next line's caps and the block looks bottom-heavy. `baselineOffset = +3.0`
   (`(26 − 20) / 2`) re-centres it. **Negative `baselineOffset` values do not move the text at all.**

Do **not** use `lineSpacing` for body leading: it inserts space between lines only, so the last line of
every paragraph stays at natural height (measured 26, 26, 20) and paragraph spacing goes inconsistent.

Emoji inflate an unstyled line from 20pt to 26pt (`AppleColorEmoji` ascent 20.00 / descent −6.25);
combined with `lineHeightMultiple` that produced a 42.2pt line next to 32.5pt neighbours. min = max
plus `usesFontLeading = false` is the only combination that held every mixed script at 26.00.

> If the text view ever runs under TextKit 2, `.layoutManager` is nil and `usesFontLeading` is
> unreachable — and `NSTextTable` (phase 4) silently collapses. `NSTextView()` on macOS 14 defaults to
> TextKit 2. **Construct the view the way `RichTextEditor` does** (explicit container + layout manager
> + storage), which pins TextKit 1.

### Font availability — `availableFontFamilies` lies

Five of sixteen probed serif faces — **New York, Iowan Old Style, Athelas, Seravek, Superclarendon** —
are absent from `NSFontManager.availableFontFamilies` yet resolve perfectly via `NSFont(name:)`. Test
availability by **resolution**, never by enumeration:

```swift
NSFont(name: "Charter-Roman", size: 16) != nil
```

This is the same bug class as the SF Mono note already in CLAUDE.md, and the app has it *today*:
`TerminalSessions.availableFontFamilies()` filters its candidates through the enumeration set and
therefore hides installed faces from the Aa menu. Worth fixing in the same pass (phase 6).

Related conflict, resolved: the typography probe found `NSFont(name: "SF Mono")` resolving on this
machine, contradicting CLAUDE.md. Xcode installed it here. **Always use
`NSFont.monospacedSystemFont(ofSize:weight:)`** — the named lookup fails on a stock Mac.

## Colour

The recommended page grounds are byte-identical to `TerminalPalette`'s existing Claude Light / Claude
Dark backgrounds in `Terminal.swift`. That is not a coincidence to be ignored — the transcript sits
directly above the terminal in the same panel, and if the two grounds disagree the split reads as two
apps glued together. **The transcript takes its light/dark decision from `TerminalAppearance`, not from
`fn.theme` directly**, and repaints on `.floatnoteTerminalPaletteChanged` (the existing
`paletteGeneration` counter pattern in `TerminalPanel`). `.classic` (black) maps to the dark palette.

| Role | Light | Dark |
| --- | --- | --- |
| Page background | `#FAF9F5` | `#262624` |
| Body text | `#1F1E1D` (15.80:1) | `#F5F4EF` (13.77:1) |
| Muted / meta | `#6D6A64` (5.12:1) | `#9F9D97` (5.59:1) |
| Rule / divider | `#E7E2D6` | `#3A3A37` |
| Inline code text / chip | `#8A3D2A` on `#EFEBDF` (6.33:1) | `#E9A183` on `#35342F` (5.87:1) |
| Code block bg / border | `#F3F0E7` / `#E4DFD2` | `#2E2E2B` / `#3C3B37` |
| Code block text | `#1F1E1D` (14.61:1) | `#F5F4EF` (12.37:1) |
| Blockquote bar | `#D8D2C2` | `#4A4944` |
| Link | `#985742` (5.28:1 page, 4.67:1 bubble) | `#E0967D` (6.37:1) |
| User bubble bg / border | `#EFEBE1` / `#E2DCCC` | `#323230` / `#3E3D39` |

Every pairing passes WCAG AA (4.5:1) on every surface it is used on — 0 failures across both themes.

**Raw coral `#D97757` is not a link colour.** It measures 2.96:1 on `#FAF9F5` and fails AA outright. It
stays what `TerminalPalette` already uses it for — the caret and non-text accents.

## User messages

**Do not bubble Claude's turns.** They run full-measure, flush left, in no container. Only the *user's*
messages get a bubble. In a 400–700pt pane, bubbling both sides costs horizontal room on exactly the
side that needs it and breaks the reading rhythm of the long-form half.

- Right-aligned, width `min(content + 32pt, 82% of column)` — never fills the measure, so the asymmetry
  stays legible at 400pt.
- 12pt corner radius, 16pt h / 10pt v padding, 1pt border.
- Text one step down (Charter 15 / 24). The user's own words are re-read far less than Claude's, and
  the smaller step gives hierarchy without a colour change.
- The `YOU` meta label sits **outside** the bubble, right-aligned, 6pt below — this keeps the bubble to
  pure content and dodges the muted-on-tinted-surface contrast problem entirely.
- Rhythm: 28pt above the bubble, 28pt below it before Claude's next meta line.
- **No tail/pointer.** At this width a chat tail reads as a messaging app and fights the serif. If a
  directional cue is wanted, drop the bottom-right radius to 4pt and leave the other three at 12.

---

## Layout

### Where it lives: inside `TerminalPanel`, stacked above the terminal

```
VStack(spacing: 0) {
    tabBar                       // + view-mode segmented control
    Divider()
    HandsfreeBar?                // existing
    Divider()
    ── mode == .transcript ──►  TranscriptView
    ── mode == .split      ──►  TranscriptView
                                TranscriptSplitHandle      (new, vertical drag)
                                SwiftTermContainer
    ── mode == .terminal   ──►  SwiftTermContainer         (today)
}
```

**Rejected: a third top-level `HStack` child.** The main window is one flat HStack — sidebar | handle |
editor | handle | panel — where the editor is the *only* child with no width constraint and no
`minWidth`. `availablePanelWidth()` hardcodes both handle widths (`windowContentWidth − (sidebar + 6) − 10`).
A third pane that does not update that function means the panel and the transcript each independently
believe they may occupy the same space, and the editor — the flex element with no floor — silently
collapses toward zero while terminal chips clip. Two right-hand panes each honouring a 200pt floor on a
900pt window leaves the editor ~470pt; on a narrow window it leaves nothing. Sidebar auto-hide at 560pt
changes `availablePanelWidth()` out from under any in-flight drag. Window `minSize` is a flat 240×180
and is never recomputed — the SwiftUI clamps are the entire defense.

Living inside the panel means **zero changes to `availablePanelWidth()`**, and the pane inherits for
free: the `min(terminalWidth, availablePanelWidth())` clamp, the resize-handle cap, the route gate, the
`isTerminalVisible && !terminalTabs.isEmpty` double guard, terminal-pane persistence, and the pin/unpin
stash. `HandsfreeBar` is the existing precedent for stacking a secondary surface here.

**Why the split is vertical, not horizontal.** Splitting the panel side-by-side would drop the terminal
below ~80 columns, and Claude Code's own box drawing, diff gutters and input frame wrap badly there —
we would break the TUI in the name of reading it better. A vertical split gives the transcript the full
panel width for its 480pt measure and leaves the terminal its columns. Transcript on top, terminal
below, because that is where Claude Code already puts its input box and where your hands already are.

### Sizing

| Knob | Value |
| --- | --- |
| Panel width | Unchanged: `min(vm.terminalWidth, vm.availablePanelWidth())` |
| Split fraction | `fn.transcriptSplitFraction`, default 0.60 (transcript), drag-adjustable |
| Transcript minimum height | 180pt |
| Terminal minimum height in split | 220pt (~10 rows + the input frame) |
| Reading column | `min(480, panelWidth − 48)`, floor 320, centred |

For a comfortable 66-character measure the panel wants ≥ 528pt. Below that the measure narrows
gracefully (400pt pane → 55 chars); below 320 + 48 the pane shows a "widen the panel" hint rather than
setting 30-character lines.

### Persistence

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `fn.transcriptMode` | String | `terminal` | `terminal` / `transcript` / `split` |
| `fn.transcriptSplitFraction` | Double | `0.60` | Transcript's share of the panel height |
| `fn.transcriptFontFamily` | String | `Charter` | Reading face. **A new key** — `fn.fontFamily` drives the note editor and its picker only offers Georgia/Times as serifs |
| `fn.transcriptFontSize` | Double | `16` | Body size; the whole scale derives from it |
| `fn.transcriptShowToolCalls` | Bool | `false` | Collapsed tool one-liners on/off |

All live in the `com.floatnote.app` domain alongside every other `fn.*` key. Note what is *not* here:
there is no `fn.transcriptVisible`. Visibility is the panel's, and `fn.transcriptMode` is a mode of a
panel that is already shown or hidden by the existing rules. That is the whole reason for putting it
inside — a separate visibility flag would need adding to `applyTerminalRouteForActiveNote`'s no-route
hide branch and to `togglePin`'s stash, and missing either produces an orphaned or lost pane.

### Entry points

- A three-way segmented control in the terminal tab bar (right of `+`), next to the **Aa** menu.
- **View ▸ Transcript** menu item cycling the same three modes.
- No key equivalent, for the same reason hands-free has none: a global chord collides with whatever
  Claude Code's TUI wants that key for.

---

## Which conversation, and what happens on a switch

**The transcript is keyed on `vm.activeTerminalId` — never on a path, never on its own route.**

```
active pane (activeTerminalId)
  → TerminalTab { path, claudeSessionId?, claudeTranscriptPath? }
  → resolution ladder → transcript file
  → TranscriptTail
```

That single binding makes every existing navigation path work with no new plumbing:

| Event | Result |
| --- | --- |
| Tap a terminal chip (`vm.selectTerminal`) | Transcript follows to that pane's conversation; the pane's note is activated as it already is |
| Switch notes (`switchTab` → `applyTerminalRouteForActiveNote` → `switchToRoute`) | Route dedups by path to the pane; `activeTerminalId` moves; transcript follows |
| Note with no route | Panel hides; transcript hides with it; the tail watcher is torn down |
| `+` / Cmd+N (`addTerminal`, `freshClaude`) | New pane, **no conversation yet** → empty state, until the first hook event stamps a session id |
| Claude notification click | Re-resolves the tab by path → `selectTerminal` → transcript follows |
| Pane closed (`✕` / `exit`) | Watcher torn down; a neighbour pane is activated and its transcript loads |
| Pin/unpin | Inherited from the panel's existing stash |

On every switch: cancel the vnode source, close the fd, drop the render model, show the new pane's
conversation from its own cold-open window. Nothing is shared between panes — two panes on one cwd are
two different conversations and must never bleed into each other.

A pane's binding is remembered across launches in `fn.terminalTabs` (the tab record gains
`claudeSessionId` / `claudeTranscriptPath`), so a restored pane shows the right conversation before any
new hook event arrives. Restore already drops panes whose directory no longer exists; a pane whose
transcript file no longer exists falls back to the provisional ladder.

---

## Interaction

**Selection and copy.** Native `NSTextView` selection, no subclass. Cmd+C copies the plain text of the
selection — the attributed run's `.string`, so a code block copies as code, not as a screenshot of one.
Selection spans block boundaries and turn boundaries, which is the single biggest thing the terminal
cannot offer today (the terminal needed `allowMouseReporting = false` and a vendored
`linesTrimmed(source:count:)` patch just to keep a selection alive during output; here it is free).

**Scroll: follow-tail vs parked.** Mirrors the terminal exactly, because the two panes sit 1px apart and
must behave the same.

- The pane follows the tail while the scroll position is within 24pt of the bottom.
- Any upward scroll parks it: new content is appended but the viewport does not move.
- A **`TranscriptScrollPill`** overlays bottom-trailing — the same capsule as `TerminalScrollPill`
  (accent fill, white 10pt medium label, 9/12pt padding, shadow, 12/10 pt insets), labelled
  `↓ N new messages` instead of `N lines below`. Click = jump to newest + resume following.
- Unlike the terminal pill, this one needs no 4Hz poll — the store already knows how many turns landed
  since the park, so it is driven by the model, not sampled.

**Code blocks.** Hover reveals a copy button in the top-right of the block; click copies the block's raw
text (no language tag, no fence). The block itself scrolls horizontally inside its own clip — at 480pt
the pane fits only ~56–60 monospace columns at SF Mono 13, so wrapping or scrolling is unavoidable and
scrolling preserves the code's own alignment. Clicking the body of a block does nothing beyond placing a
caret for selection; **do not** make it insert into the terminal — a read surface that silently types
into a live shell is a foot-gun.

**Links.** `http(s)://` opens in the default browser via `NSWorkspace.shared.open`. Bare absolute file
paths and `file.swift:12` references are rendered in the link colour but are **inert in v1** — deciding
whether they open in FloatNote, in Finder, or in the user's editor is open question 4.

**Cmd+F.** The app-wide local key monitor (App.swift:138-150) routes Cmd+F into
`vm.editorCoordinator?.textView` whenever focus is *not* inside a terminal. A new focusable transcript
view inherits that steal: pressing Cmd+F while reading would open the *note's* find bar. The monitor's
condition must gain a transcript-focus check, routing to the transcript's own `NSTextFinder`. Cmd+W is
swallowed app-wide and stays that way.

**No editing, no checkbox toggling, no drag-to-reorder.** `isEditable = false`, `isSelectable = true`,
and the view is built from a plain `NSTextView` subclass with no behaviour overrides — the exact
opposite of `BlockCaretTextView`.

---

## Performance

| Measurement | Value |
| --- | --- |
| Largest transcript on this Mac | 111.0 MB / 33 327 lines |
| This project's live session | 9.2 MB / 1 276 lines |
| Median line | 803–1 421 B |
| p99 line | 15 KB – 205 KB |
| Largest single line | 4.72 MB (inline base64 images in a `tool_result`) |
| `tail -n 200` on the 111 MB file | 0.00 s |
| Full `jq` parse of the 111 MB file | 0.64 s |

Parsing is not the bottleneck; **retention is**. Rules:

1. **Cold open reads a window, not the file.** Seek to `max(0, size − 2 MB)`, discard to the first `\n`,
   parse forward. That is ~2 000 median lines — far more than the pane will show. Earlier history loads
   on demand via a "Load earlier" affordance that walks the window backward.
2. **Cap the render model at 400 turns**, dropping from the head, mirroring the terminal's
   `defaultScrollback = 20_000` decision rather than holding the whole file.
3. **Everything off the main actor.** Read, JSON-parse, group by `requestId`, run the markdown renderer
   and build the `NSAttributedString` on a private serial queue; hop to `@MainActor` only with a bounded
   array of finished blocks. Building an `NSAttributedString` (no layout, no view) off-main is safe;
   handing it to the text storage is not. The existing watchers all run synchronously on the main actor
   (App.swift:104-113) — fine for a few hundred spool bytes, a UI hitch for a 9.6 MB JSONL.
4. **Drop base64 at ingest.** `image.source.data` and any `attachment` payload never enter the model. A
   4.72 MB line costs ~30 ms to parse and 0 bytes to keep.
5. **No directory sweeps.** The board watcher's full-directory mod-date scan every 2s does not port here:
   a project store holds 16+ `.jsonl` files and there can be N open panes, so a naive port is an N×16
   `stat` sweep on the main thread every tick. One fd, one offset, one watcher, per *active* pane only.
6. **Only the active pane tails.** Background panes hold their binding but no watcher.
7. **Incremental append, never rebuild.** New complete lines produce new blocks appended to the storage
   inside one `beginEditing`/`endEditing`; the existing document is never re-rendered.

---

## Failure modes

| Condition | Behaviour |
| --- | --- |
| **No session file yet** (fresh pane, `freshClaude`, Claude not started) | Empty state: "No conversation yet — this pane's transcript appears once Claude replies." No error, no spinner |
| **Provisional binding** (pre-hook, resolved by `lastSessionId` or newest-mtime) | Renders, with a dimmed "best guess" chip in the header + "choose session…". Replaced silently the moment a hook event stamps the real `session_id` |
| **Compaction** (`system` / `compact_boundary`) | Rendered as a labelled section rule — "Conversation compacted · 978 360 tokens dropped" — and the following `isCompactSummary: true` record as a summary card, never as a human message. Nothing is truncated on disk, so scrollback above the rule stays valid |
| **File rewritten / replaced / rotated** (`size < offset`, or `.delete`/`.rename`) | Reset offset to 0, re-open by path, full re-ingest of the cold-open window. Claude Code has explicit transcript-path recovery/latching, so this is a real path, not a theoretical one |
| **Huge single message** (4.72 MB, inline base64) | Parsed, base64 dropped at ingest, images shown as `[image]` chips. Text over 20 000 characters renders truncated with a "show full message" expander |
| **Malformed / torn line** | Only complete lines (up to the last `\n`) are ever parsed; the tail is buffered. A line that still fails `JSONSerialization` is counted, `dbg()`'d once per session, and skipped — one bad line never stops the tail |
| **Unknown `type` / new schema** | Skipped silently (the filter is an allow-list, not a deny-list). A new record type in a future Claude Code version degrades to invisible, never to garbage |
| **Session switched by `--continue` / `--resume`** | Nothing happens: `--continue` **appends to the same file**. One measured session spans 19 days and six Claude Code versions in a single file. The tail just keeps reading |
| **Session switched by a genuinely new `claude` run** | The next hook event carries a different `session_id`; the store tears down the old watcher and cold-opens the new file. A "new session started" rule is drawn where the old transcript ended |
| **SDK sessions in the same directory** (`entrypoint: "sdk-py"` — security-review, code-review) | Never adopted: the ladder binds by `session_id` from the hook, and the newest-mtime fallback filters on `entrypoint == "cli"` |
| **Subagent activity** | Invisible in v1 — `isSidechain: true` records live only in `<sessionId>/subagents/**`, never in the session file. The parent shows the `Task` tool call as a collapsed one-liner |
| **Store directory unreadable / missing** | Empty state with the resolved path shown, one `dbg()` line, no retry storm |
| **Old hook installed** (no `session_id`) | Provisional ladder forever; the pane still works. Same degradation shape as `last_assistant_message` |

Debug: `transcript: …` lines in `~/.floatnote-debug.log` at every boundary — session resolved (and by
which ladder step), watcher started/stopped, bytes consumed, records ingested/skipped by type, parse
failures, model size after append.

---

## Build order

Each phase is independently shippable and verifiable.

1. **Binding + ingest, no UI.** Add `session_id` / `transcript_path` to `docs/floatnote-claude-hook.sh`,
   reinstall, stamp them onto `TerminalTab` in `checkClaudeEvents`, persist in `fn.terminalTabs`.
   Implement the resolution ladder and `TranscriptStore`'s cold-open window + offset tail on a private
   queue. Verifiable entirely from `~/.floatnote-debug.log` with no pixels.
2. **Plain-text pane.** `TranscriptView` in `.transcript` mode, body face only, no markdown: record
   filtering, `requestId` grouping, human/tool/meta classification, turn separation, meta lines,
   selection and copy. This alone is already more readable than the terminal.
3. **Typography + colour.** The full scale, the four line-height lines, the light/dark palettes wired to
   `TerminalAppearance`, the 480pt measure, user bubbles.
4. **Markdown.** The block scanner and inline pass — headings, lists, task lists, fences, blockquotes,
   rules, tables-as-preformatted, inline emphasis and links. Code-block copy button.
5. **Split mode + scroll.** The vertical split handle, `fn.transcriptSplitFraction`, the segmented
   control, follow-tail/parked, `TranscriptScrollPill`, Cmd+F routing.
6. **Polish.** Tool-call one-liners behind `fn.transcriptShowToolCalls`, compaction rules, "Load earlier",
   font/size menu (resolution-based availability — and fix `TerminalSessions.availableFontFamilies()`
   the same way), `NSTextTable` for real GFM tables.
7. **Optional: subagents.** Recursive walk of `<sessionId>/subagents/**/agent-*.jsonl`, labelled from the
   sibling `agent-<id>.meta.json` (`agentType`, `spawnDepth`), rendered as expandable nested transcripts
   under their `Task` call.

## Testing

Manual, matching the rest of the app, with `dbg()` at every boundary.

1. Two panes on one cwd, both running Claude → each shows **its own** conversation; chip taps swap them.
2. A fresh `+` pane before Claude starts → empty state, then binds on the first turn.
3. Kill and relaunch the app → restored panes show the right conversation before any new hook event.
4. Run `/compact` → section rule appears, scrollback above it survives, tail continues.
5. Send a turn with a table, a fenced block, a task list, a blockquote and an emoji → line height is
   26.00 on **every** line, including the checkbox ones.
6. Park the scroll, let three turns land → pill reads "↓ 3 new messages"; click resumes following.
7. Open the 111 MB transcript's project → cold open is instant, no main-thread hitch.
8. Paste an image into Claude Code → the giant line is ingested, memory does not spike, `[image]` chip
   renders.
9. Flip the terminal Aa palette light↔dark → transcript ground changes with it, no restart.
10. Switch to a note with no project folder → panel and transcript hide together, watcher torn down.

---

## Open questions

1. **Split orientation.** This spec puts the transcript *above* the terminal in the same panel, on the
   grounds that a side-by-side split would drop the terminal below 80 columns and break Claude Code's
   own box drawing. You described it as "a pane beside the terminal" — is a horizontal (side-by-side)
   split what you actually want, accepting a narrower terminal, or is the vertical stack right?
2. **Tool calls: how much structure do you want to see?** The default here is invisible, with an
   optional one-line `Read · Terminal.swift` chip. The `toolUseResult` payloads are rich enough to
   render properly — `Edit` carries a full `structuredPatch`, `Bash` carries stdout/stderr, `Grep`
   carries match counts. Is a real diff/output view worth building, or is prose-only the point?
3. **Reading face.** Charter is the recommendation (best Tiempos match, lining figures, safe back to
   macOS 10.x). Do you want a face picker at all, or should this be one opinionated face with no menu?
   If a picker, should it also offer Iowan Old Style and New York?
4. **File references.** Claude's turns are full of `/Users/…/Terminal.swift:343`. Should clicking one do
   something — open the file in FloatNote's editor, reveal in Finder, send `code <path>` to the terminal
   — or stay inert?
5. **Hook change acceptance.** Step 1 of the ladder requires editing `docs/floatnote-claude-hook.sh` and
   reinstalling it to `~/.claude/hooks/floatnote-notify.sh`, which is a *global* file affecting every
   Claude Code session on this Mac (same caveat as `syncClaudeCodeTheme`). Acceptable, or should the
   pane live with the provisional ladder only?
6. **History depth.** Cold open reads the last 2 MB and offers "Load earlier". Should the pane instead
   open at the *start* of the session, or at the last compaction boundary?
7. **Subagents.** Phase 7 renders them as nested expandable transcripts. Worth it, or is the collapsed
   `Task` one-liner enough?
