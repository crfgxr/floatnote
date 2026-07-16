# Sidebar Recording Indicator

**Date:** 2026-07-16
**Status:** Approved

## Goal

While an audio recording is running on a note, its sidebar row must show a live
visual indicator so the user can always see which note is recording.

## Chosen design (user-approved)

**Pulsing red dot + red-tinted title** on the recording note's sidebar row.

- `SidebarNoteItemView` gains `isRecordingHere: Bool` =
  `vm.isRecording && vm.recordingTabId == tab.id`. The view already observes
  the VM (`@EnvironmentObject`) and both properties are `@Published`, so the
  row re-renders on recording start/stop with no new plumbing.
- While `isRecordingHere`:
  - A small red dot (~7pt `Circle`, `.red`) renders at the row's leading edge,
    pulsing via a `repeatForever(autoreverses:)` opacity animation driven by a
    local `@State` toggled in `onAppear` (new `RecordingPulseDot` view).
  - The note title text is tinted `.red` (overrides the usual
    active/inactive primary/secondary colors).
- The dot **replaces** the static 🎤 marker while recording (the 🎤 keys off
  `tab.recordingPath`, which is only set when a recording *finishes*; the dot
  branch is checked first so they never render together).
- When recording stops, the dot leaves the view hierarchy, killing the
  animation, and the title color reverts automatically.

## Out of scope

No data-model, persistence, or MCP changes — pure view-layer. No indicator on
folder headers or the Trash section.

## Alternatives considered

- Dot only (too subtle in a busy sidebar per user preference)
- Animated SF Symbols waveform (busier, replaces familiar 🎤 semantics)
- Glowing row background (too prominent)
