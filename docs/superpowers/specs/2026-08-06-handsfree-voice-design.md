# Hands-Free Voice for Claude Code — Design

Date: 2026-08-06

Ports [claude-code-handsfree](https://github.com/crfgxr/claude-code-handsfree) into FloatNote as
a native feature: Claude Code reads its responses aloud, then listens for a spoken reply, and
"send it" submits — a hands-free loop against FloatNote's own embedded terminal.

## Why native beats the standalone app

The standalone app already has a `FloatNoteTarget`, but it drives FloatNote from the outside and
pays for it. Every one of those costs disappears when the feature lives in the app:

| Standalone | Native |
| --- | --- |
| HTTP server on port 27182, `curl` from the hook | The existing `~/.floatnote-claude-events/` spool + hook script, one extra JSON field |
| `CGEvent` keystrokes — needs **Accessibility**, needs FloatNote frontmost, lands wherever focus happens to be | `TerminalSessions.shared.existing(id)?.view.send(txt:)` — exact pane, no permission, no focus dependency |
| `TerminalRouter` guesses the target from `lastFrontmostApp` | The hook already carries `cwd`; resolve it to a `TerminalTab` |
| "focus window N" drives iTerm2 split panes | Maps onto FloatNote's own terminal chips |

What actually needs porting is the voice layer: TTS, speech recognition, barge-in, and the
command parser. The transport and targeting layers dissolve.

## Data flow

```
Claude Code [Stop / Notification hook]
    → ~/.claude/hooks/floatnote-notify.sh          (+ last_assistant_message)
    → ~/.floatnote-claude-events/<id>.json         (temp+rename spool, unchanged)
    → DispatchSource vnode watcher on the spool dir (new — removes the 2s lag)
    → vm.checkClaudeEvents() resolves cwd → TerminalTab
    → HandsfreeManager.handleTurnEnd(message:tab:)
    → VoiceEngine.speak() → auto-listen → SFSpeechRecognizer
    → "send it" → TerminalSessions.shared.existing(paneId)?.view.send(txt: text + "\n")
```

The existing 2s `AppDelegate` timer stays as a safety net; the watcher only makes delivery feel
immediate. Notification events (permission prompts) enter the same manager in quick-response mode.

## Components

Three new files, following the existing split (`Terminal.swift`, `Excalidraw.swift`,
`Images.swift`) rather than growing `App.swift`.

### `Handsfree.swift` — `HandsfreeManager`

`ObservableObject` owning the state machine and policy. The standalone `AppState` equivalent,
minus everything routing-related.

- `state: HandsfreeState` — `.idle` / `.speaking` / `.listening` / `.processing`
- `isMuted`, `liveTranscript`, `statusText`, `audioLevel`, `awaitingQuickResponse`
- `responseMode: ResponseMode` — `.full` / `.summary` / `.notify`, persisted `fn.handsfreeResponseMode`
- `voiceId: String` — persisted `fn.handsfreeVoiceId`
- `handleTurnEnd(message:tab:)`, `handlePermissionPrompt(message:tab:)`
- `submit(_:)`, `sendEscape()`, `focusPane(_:)` — all resolve the pane at call time
- Mic arbitration (below)

Holds a weak reference to `EditorViewModel` for pane lookup and navigation.

### `VoiceEngine.swift`

A near-direct port of `VoiceManager`. Its two hard-won fixes carry over **verbatim**, because both
were bugs found the expensive way:

1. **Input-device changes.** `AVAudioEngine` binds its input node at creation and never follows
   the default input device, so plugging in AirPods leaves it on the built-in mic. A CoreAudio
   `kAudioHardwarePropertyDefaultInputDevice` listener rebuilds a *fresh* engine — debounced 0.5s,
   on a private serial queue, and only when the device ID actually changed. Driving this off
   `AVAudioEngineConfigurationChange` instead caused a main-thread rebuild loop that froze the app.
2. **Barge-in grace period.** The state flips to `.speaking` while `say` is still rendering to
   file. Detecting "speech" then kills the response before a word plays. Barge-in is therefore
   gated on playback having actually started (`speechStartedAt`) plus 0.4s, which also covers
   speaker bleed into the mic (there is no echo cancellation).

TTS renders through `/usr/bin/say -o <file>` and plays via `AVAudioPlayer` rather than
`AVSpeechSynthesizer` — the original did this to stay smooth under CPU load, and it also keeps the
existing recording stack untouched.

Two pure functions are extracted so they can be exercised without audio:

- `cleanForSpeech(_:) -> String` — strips code fences, inline code, headings, emphasis, URLs, list
  markers
- `parseCommand(_:) -> VoiceCommand?` — `.sendIt` / `.stop` / `.deleteMessage` /
  `.slash(String)` / `.focusPane(Int)` / `.quickResponse(String)`

### `HandsfreeBar.swift`

The voice bar and a compact waveform view.

## Hook change

One field added to `docs/floatnote-claude-hook.sh`:

```python
"last_assistant_message": data.get("last_assistant_message", ""),
```

plus the `stop_hook_active` early-exit the handsfree hook had and FloatNote's currently lacks
(without it a Stop hook can re-enter). Reinstall to `~/.claude/hooks/floatnote-notify.sh` — the
repo copy is only the source of truth.

Spool files written by an older hook simply lack the field; they decode to an empty message and
fall back to notify-only speech, so a stale installed hook degrades instead of breaking.

## UI

### Toolbar button

A `mic` button in `FormatToolbar`, immediately after `terminalButton`, sharing its route gate:
disabled and dimmed when the active note has no route, tooltip "Link a folder to use the
terminal". Gray when off, accent when a session is live.

### Voice bar

Docked directly under the terminal tab bar, spanning the panel width, ~34pt tall:

```
┌────────────────────────────────────────────────────────┐
│ ▁▃▅▇▅▃▁   add a dark mode toggle      ↺  🔇  [Say "Send It"]  ⚙ │
└────────────────────────────────────────────────────────┘
```

- **Waveform** — 20 bars, 15fps while speaking or listening, static when idle (the original made
  the same CPU trade).
- **Middle** — live transcript trimmed to the last 5 words, else the state text.
- **Right** — reset (visible only while listening), mute, primary capsule button, gear.

Primary button label by state: `Speak Now` / `Say "Send It"` / `Stop` / `Sending`.

Colors follow FloatNote rather than the standalone app's purple palette: **listening = red**
(matching the app's existing record semantics), **speaking = accent**, **idle = secondary**, on
`theme.chromeBackground`. New constants live in `DesignTokens.swift` beside `boardHasContent`.

### Settings menu

The gear opens an `NSMenu`:

- **Response Mode** — Full Response / Summary (first + last sentence) / Notify Only. Notify Only
  speaks a fixed short phrase ("Listening") rather than any of the response, matching the
  original's behavior; the pane-label prefix still applies.
- **Voice** — System Default, then English voices filtered to enhanced, premium, or Siri, sorted
  by quality (same filter as the original)
- **Test TTS**
- **Voice Settings…** — opens System Settings › Spoken Content

## Voice commands

| Say | Effect |
| --- | --- |
| "send it" | Submit the transcript: `send(txt: text + "\n")` to the active pane |
| "stop" | `send(txt: "\u{1b}")` — interrupts Claude |
| "delete message" | Clear the transcript, keep listening |
| "cmd X" / "command X" | Replace the transcript with `/X`; submits immediately if followed by "send it" |
| "focus window N" | `vm.selectTerminal(terminalTabs[N-1].id)` — switches chip *and* navigates to that pane's note |
| numbers, yes/no/always | Only while `awaitingQuickResponse`: answers a permission prompt |

The trailing trigger is stripped before submitting.

## Targeting

The voice session drives **`vm.activeTerminalId`**, resolved at submit time, so navigating
mid-sentence lands the text where you ended up. This matches how terminal focus and note routing
already behave.

When Claude finishes in a pane that is *not* active, the message is spoken prefixed with the pane
label — `"floatnote: tests are passing"` — so several concurrent agents stay distinguishable. The
label is already resolved by the existing notification path.

A hook event whose `cwd` matches no open pane produces no speech; today's banner behavior is
unchanged.

## Mic arbitration

The microphone is exclusive, and three subsystems want it:

- **Meeting recording** (`RecordingManager`) wins. Hands-free refuses to start while
  `vm.isRecording`, with a status message saying why; starting a recording stops an active
  hands-free session.
- **Editor dictation** (`NSTextInputContext startDictation:`) is a separate mechanism that would
  fight the recognizer. Starting hands-free clears `vm.wantsDictation`.
- **Hands-free** holds the mic only between start and stop of a session.

## Permissions

The mic grant already exists (recording). **Speech Recognition is new**: add
`NSSpeechRecognitionUsageDescription` to the app's `Info.plist` and call
`SFSpeechRecognizer.requestAuthorization` on first hands-free use, not at launch. The stable
"FloatNote Dev" signing identity keeps the grant across rebuilds.

No Accessibility permission is required — the whole `CGEventPost`-silently-no-ops failure mode
the standalone app documents does not exist here.

## Error handling

| Condition | Behavior |
| --- | --- |
| Speech recognizer unavailable | Status "Speech unavailable", return to `.idle`, no crash |
| Speech authorization denied | Status explains, mic button stays off |
| Recording in progress | Hands-free start refused with a status message |
| Pane closed mid-session | Submit is dropped, session returns to `.idle` |
| `say` render fails | Completion fires anyway so the loop never wedges |
| Empty transcript on submit | Nothing sent, listening restarts |

## Build order

Each phase is independently usable and verifiable.

1. **Hook + plumbing** — extra field, `stop_hook_active` guard, spool watcher, cwd→pane
   resolution, `dbg()` logging. Verifiable with no audio.
2. **TTS out** — speak turn-end messages, response modes, voice picker, pane prefix, gear menu.
3. **Voice in** — recognizer, live transcript, "send it" → pane.
4. **Commands** — stop, delete message, cmd X, focus window N, quick responses.
5. **Barge-in, auto-listen loop, mic arbitration.**
6. **Polish** — waveform, sound feedback, hint rotation.

## Testing

Manual, matching the rest of the app, with `dbg()` to `~/.floatnote-debug.log` at every boundary:
hook received, pane resolved, TTS start/end, transcript final, text sent.

1. Hook fires → spool file appears → correct pane resolved (phase 1, no audio).
2. Turn ends in the active pane → response spoken in the selected mode and voice.
3. Turn ends in a background pane → spoken with the label prefix.
4. "send it" → text lands in the right pane and submits.
5. Each voice command produces its documented effect.
6. Barge-in during TTS switches to listening; no false trigger in the first 0.4s of playback.
7. Hands-free refuses to start while recording; recording stops an active session.
8. Switch input device (AirPods) mid-session → recognition continues on the new mic.
9. Two panes running Claude → both announced, correctly labelled.
