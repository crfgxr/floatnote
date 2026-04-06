# Audio Recording Feature — Design Spec
Date: 2026-04-06

## Overview

Add a general-purpose audio recorder to FloatNote that captures mixed mic input and system audio output, saves as `.m4a`, and presents each recording in its own auto-created tab with a minimal playback UI.

---

## Architecture

A new `RecordingManager` class is added to `App.swift` alongside the existing `ViewModel`.

**RecordingManager responsibilities:**
- Owns `AVAudioEngine` for mic input capture
- Owns `SCStream` (ScreenCaptureKit) for system audio output capture
- Mixes both streams via `AVAssetWriter` into a single `.m4a` file
- Exposes `isRecording: Bool` (drives toolbar button state)
- Exposes `start() -> String` (returns tab title, begins capture)
- Exposes `stop() -> URL` (finalizes file, returns saved file URL)

**ViewModel responsibilities:**
- Calls `RecordingManager.start()` on record button press → creates new tab
- Calls `RecordingManager.stop()` on stop button press → updates tab to player UI
- On app quit mid-recording → calls `stop()` in `applicationWillTerminate`

---

## Storage

- Recordings folder: `~/.floatnote-recordings/` (created on first recording)
- Filename format: `dd.mm-hh.mm.m4a`
- Collision handling: append `-2`, `-3`, etc. silently
- Tab state in `~/.floatnote-tabs.json` stores the recording file path so the player reloads correctly after app restart

---

## Recording Flow

1. User presses **Record** button in toolbar
2. Permissions are checked (mic + screen recording)
3. If permissions granted:
   - New tab created, titled `dd.mm - hh:mm`
   - Tab shows "Recording in progress..."
   - Toolbar record button changes to **Stop**
   - `RecordingManager.start()` begins capturing mixed audio
4. User presses **Stop**:
   - `RecordingManager.stop()` finalizes and saves `.m4a`
   - Tab switches to player UI
5. App quit mid-recording:
   - `applicationWillTerminate` calls `stop()` to auto-save
   - Tab persists in `~/.floatnote-tabs.json` with file path

---

## Player UI

Displayed inside the recording tab after recording stops (or on relaunch if tab persists).

```
[▶] [■]  ──●──────────────  00:42 / 01:30   [Open Folder]
```

- **Play/Pause** button
- **Stop** button (returns to beginning)
- **Scrubber** with elapsed / total time display
- **Open Folder** link — opens `~/.floatnote-recordings/` in Finder
- Minimal styling consistent with FloatNote's plain toolbar aesthetic

---

## Permissions

- `NSMicrophoneUsageDescription` added to `Info.plist`
- ScreenCaptureKit requires Screen Recording permission (no entitlement needed, macOS prompts automatically)
- If either permission is denied:
  - Record button renders as **disabled** (grayed out)
  - Clicking the disabled button opens **System Settings** to the relevant permission page
- On first record attempt, macOS shows permission prompts automatically

---

## Info.plist Changes

```xml
<key>NSMicrophoneUsageDescription</key>
<string>FloatNote needs microphone access to record audio notes.</string>
```

---

## Out of Scope

- Audio format options (always M4A)
- Manual file naming (tab title is always the timestamp)
- Cloud sync of recordings
- Multiple simultaneous recordings (record button disabled while recording is active)
