# Sidebar Job-Running Indicator

**Date:** 2026-07-16
**Status:** Approved
**Companion to:** `2026-07-16-sidebar-recording-indicator-design.md` (red recording dot)

## Goal

When a job is running on a note — an in-app job (Transcribe / Summarize) or an
external one (an MCP-driven agent / cron job working on the note) — its sidebar
row shows a live busy indicator, in the same visual language as the recording
indicator but distinguishable from it.

## Data model

`TabData` / `NoteTab` gain two optional fields (old tabs.json files decode
unchanged):

- `jobStatus: String?` — human-readable label ("Transcribing…", "Summarizing…",
  or whatever an MCP caller passes, e.g. "Claude working…"). `nil` = idle.
- `jobStatusAt: Double?` (epoch seconds) — when the status was last set.
  Drives the stale-flag TTL.

Both round-trip through `toData()` / `from(_:)` and persist in
`~/.floatnote-tabs.json`.

## In-app jobs

`transcribeRecording()` and `summarizeRecording()` set the **origin** tab's
`jobStatus` ("Transcribing…" / "Summarizing…") after their guards pass and
clear it on every exit path (via `defer`). Set/clear both reassign
`tabs = tabs` (re-fire `@Published`) and call `saveTabsLocal()` so the on-disk
copy never holds a flag the in-memory state has already cleared (otherwise the
external-change merge could resurrect it).

## External jobs (MCP)

New MCP tool in `mcp-server.js`:

- `set_note_status(identifier, status?)` — same identifier matching as
  `read_note` (id, exact title, substring). With `status`: sets `jobStatus` +
  `jobStatusAt = now` on the tab and writes tabs.json (atomic temp+rename).
  Without `status` (or empty string): clears both fields.
- Tool description documents the 30-minute TTL and tells long-running jobs to
  re-set the status periodically to keep it alive.

The app sees the change via the existing 2-second external-sync poll:
`reloadTabsFromDisk`'s merge syncs `jobStatus` / `jobStatusAt` from the disk
copy (active and non-active tabs alike), next to the existing `folderId` /
`localPath` sync.

## Stale-flag safety (TTL sweep)

`NoteTab.isJobActive` = `jobStatus != nil` and `jobStatusAt` no older than
30 minutes (missing timestamp = treated as fresh-now when set in-app; the MCP
tool always writes one). The AppDelegate 2-second timer additionally calls
`vm.sweepExpiredJobStatuses()`: clears any expired `jobStatus`, re-fires
`tabs = tabs`, and saves — covering crashed agents and flags left over from
before app launch.

## Visual

- `RecordingPulseDot` generalizes to `PulseDot(color:)`; recording keeps red.
- While `isJobActive` (and not recording): pulsing **accent-blue** dot at the
  row's leading edge + accent-tinted title.
- Hovering the row shows the status text via `.help(jobStatus)`.
- Precedence in the row: recording (red) > job (accent) > finished-recording 🎤.

## Out of scope

No progress percentage, no per-folder rollup, no queueing of multiple
concurrent statuses per note (last writer wins).
