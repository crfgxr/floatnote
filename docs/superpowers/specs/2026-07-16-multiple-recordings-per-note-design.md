# Multiple Recordings per Note

**Date:** 2026-07-16
**Status:** Approved

## Goal

A note can hold any number of audio recordings. Today `NoteTab.recordingPath`
is a single string: recording again on the same note overwrites the pointer
and orphans the previous `.m4a` in `~/.floatnote-recordings/`. Users must be
able to keep, play, transcribe, summarize, and delete each recording
individually.

## Data model

- `NoteTab.recordingPaths: [String]` (`@Published`) replaces the single
  `recordingPath` property.
- `TabData` gains `recordingPaths: [String]?` and **keeps** the legacy
  `recordingPath: String?`:
  - decode: `recordingPaths ?? (recordingPath.map { [$0] } ?? [])` — every
    existing note migrates automatically, no one-shot migration code.
  - encode: write both — the full array, plus `recordingPath` = newest entry —
    so the MCP server (which keys off `recordingPath` in `list_notes`) and any
    stale reader keep working. The server round-trips unknown fields, so
    `mcp-server.js` needs no change.
- Finishing a recording **appends** `url.path` to the origin tab's array.
- All single-path consumers updated:
  - sidebar 🎤 marker and any `recordingPath != nil` checks →
    `!recordingPaths.isEmpty`
  - external-change merge (`reloadTabsFromDisk`) syncs the array
  - `permanentlyDeleteTab`, `permanentlyDeleteFolder`, `emptyTrash` delete
    **all** files in the array
  - `currentRecordingPath` (transcribe fallback for a just-recorded, unsaved
    path) stays as-is, pointing at the newest recording.

## UI — stacked rows (user-chosen)

Above the editor, the single `RecordingPlayerView` block becomes a vertical
list: one slim row per recording of the active note, each with:

- ▶︎/⏸ play/pause + seek slider + time display
- timestamp label derived from the filename (`16.07-11.26.m4a` → `16.07 11:26`)
- **Transcript · Summary** buttons (per-row AI actions)
- ✕ delete with a confirmation alert ("Delete this recording?"); on confirm the
  `.m4a` is removed from disk, the entry leaves the array, and tabs save.

Starting playback on one row pauses any other playing row (one audio at a
time — coordinated through the view-model).

## Transcribe / Summary per row

`transcribeRecording(path:)` / `summarizeRecording(path:)` take the target
path explicitly (each row passes its own). Origin-tab capture stays so results
land on the note the button was pressed on. While either runs, all rows' AI
buttons disable via the existing `isTranscribing` / `isSummarizing` globals,
and the note shows the blue job indicator (existing `setJobStatus` wiring).

## Out of scope

- No renaming of recordings, no reordering (list is chronological by
  append order).
- No per-recording MCP tools.
- Recording capture flow itself is unchanged.
