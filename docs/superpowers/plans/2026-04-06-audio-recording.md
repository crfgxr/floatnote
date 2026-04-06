# Audio Recording Feature — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a mixed audio recorder (mic + system audio) to FloatNote that creates a timestamped tab per recording with a minimal playback UI.

**Architecture:** `RecordingManager` captures system audio via `SCStream` (ScreenCaptureKit) and mic audio via `AVAudioRecorder`, writes both to separate temp M4A files, then merges them with `AVMutableComposition` into the final M4A. `EditorViewModel` orchestrates tab creation, recording state, and quit handling. `EditorView` conditionally renders `RecordingInProgressView` or `RecordingPlayerView` for recording tabs.

**Tech Stack:** SwiftUI, AppKit, AVFoundation, ScreenCaptureKit, AVAudioRecorder, AVAssetWriter, AVMutableComposition, AVPlayer

---

## Files Modified

| File | Change |
|------|--------|
| `FloatNote/FloatNote/App.swift` | All new code (imports, model, manager, views, toolbar, delegate) |
| `FloatNote/Info.plist` | Update `NSMicrophoneUsageDescription` |

---

## Task 1: Add imports and extend tab model

**Files:**
- Modify: `FloatNote/FloatNote/App.swift:1-2` (add imports)
- Modify: `FloatNote/FloatNote/App.swift:79-106` (TabData, NoteTab)

- [ ] **Step 1: Add imports** at the top of App.swift after `import AppKit`:

```swift
import AVFoundation
import ScreenCaptureKit
```

- [ ] **Step 2: Extend `TabData`** — add `recordingPath: String?` (line 79):

```swift
struct TabData: Codable {
    var id: String
    var title: String
    var noteGuid: String?
    var html: String
    var recordingPath: String?
}
```

- [ ] **Step 3: Extend `NoteTab`** — add `recordingPath`, update `toData()` and `from()` (lines 86–106):

```swift
class NoteTab: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    var html: String = ""
    var lastSavedHTML: String = ""
    var recordingPath: String? = nil

    init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
    }

    func toData() -> TabData {
        TabData(id: id.uuidString, title: title, html: html, recordingPath: recordingPath)
    }

    static func from(_ data: TabData) -> NoteTab {
        let tab = NoteTab(id: UUID(uuidString: data.id) ?? UUID(), title: data.title)
        tab.html = data.html
        tab.recordingPath = data.recordingPath
        return tab
    }
}
```

- [ ] **Step 4: Build to confirm no errors**
```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote/FloatNote && swift build 2>&1 | head -20
```
Expected: no errors.

- [ ] **Step 5: Commit**
```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote && git add FloatNote/FloatNote/App.swift && git commit -m "feat: extend NoteTab with recordingPath for audio recording tabs"
```

---

## Task 2: Add RecordingManager

**Files:**
- Modify: `FloatNote/FloatNote/App.swift` — insert after the closing `}` of `EditorViewModel` (after line 341)

- [ ] **Step 1: Add `RecordingManager`** and its SCStreamOutput extension after line 341:

```swift
// MARK: - Recording Manager

class RecordingManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var permissionDenied = false

    private let writeQueue = DispatchQueue(label: "com.floatnote.audiowrite", qos: .userInteractive)
    private var scStream: SCStream?
    private var sysWriter: AVAssetWriter?
    private var sysAudioInput: AVAssetWriterInput?
    private var sysWriterStarted = false
    private var micRecorder: AVAudioRecorder?
    private var systemTempURL: URL?
    private var micTempURL: URL?

    static let recordingsDir = NSHomeDirectory() + "/.floatnote-recordings"

    // MARK: Permissions

    func checkAndRequestPermissions() async -> Bool {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .denied || micStatus == .restricted {
            DispatchQueue.main.async { self.permissionDenied = true }
            return false
        }
        if micStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                DispatchQueue.main.async { self.permissionDenied = true }
                return false
            }
        }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            DispatchQueue.main.async { self.permissionDenied = true }
            return false
        }
        DispatchQueue.main.async { self.permissionDenied = false }
        return true
    }

    // MARK: Start

    func start() async {
        try? FileManager.default.createDirectory(atPath: Self.recordingsDir, withIntermediateDirectories: true)
        let uuid = UUID().uuidString
        systemTempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fn_sys_\(uuid).m4a")
        micTempURL    = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fn_mic_\(uuid).m4a")
        await startSystemCapture()
        startMicCapture()
        DispatchQueue.main.async { self.isRecording = true }
    }

    private func startSystemCapture() async {
        guard let sysURL = systemTempURL,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let display = content.displays.first else { return }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 44100
        config.channelCount = 2
        config.excludesCurrentProcessAudio = false

        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]
        guard let writer = try? AVAssetWriter(outputURL: sysURL, fileType: .m4a) else { return }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
        sysWriter = writer
        sysAudioInput = input
        sysWriterStarted = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try? stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writeQueue)
        try? await stream.startCapture()
        scStream = stream
    }

    private func startMicCapture() {
        guard let micURL = micTempURL else { return }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000
        ]
        micRecorder = try? AVAudioRecorder(url: micURL, settings: settings)
        micRecorder?.record()
    }

    // MARK: Stop

    func stop() async -> URL? {
        DispatchQueue.main.async { self.isRecording = false }

        micRecorder?.stop()
        micRecorder = nil

        try? await scStream?.stopCapture()
        scStream = nil

        writeQueue.sync { }  // drain any in-flight appends

        sysAudioInput?.markAsFinished()
        await sysWriter?.finishWriting()
        sysWriter = nil
        sysAudioInput = nil

        let outputURL = makeOutputURL()
        guard let sysURL = systemTempURL, let micURL = micTempURL else { return nil }
        let merged = await mergeAudio(systemURL: sysURL, micURL: micURL, to: outputURL)

        try? FileManager.default.removeItem(at: sysURL)
        try? FileManager.default.removeItem(at: micURL)
        systemTempURL = nil
        micTempURL = nil

        return merged ? outputURL : nil
    }

    // MARK: Merge

    private func mergeAudio(systemURL: URL, micURL: URL, to outputURL: URL) async -> Bool {
        let composition = AVMutableComposition()

        let sysAsset = AVAsset(url: systemURL)
        if let sysTrack = try? await sysAsset.loadTracks(withMediaType: .audio).first,
           let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
           let dur = try? await sysAsset.load(.duration) {
            try? compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: sysTrack, at: .zero)
        }

        let micAsset = AVAsset(url: micURL)
        if let micTrack = try? await micAsset.loadTracks(withMediaType: .audio).first,
           let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
           let dur = try? await micAsset.load(.duration) {
            try? compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: micTrack, at: .zero)
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { return false }
        export.outputURL = outputURL
        export.outputFileType = .m4a
        await export.export()
        return export.status == .completed
    }

    // MARK: Filename

    private func makeOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM-HH.mm"
        let base = formatter.string(from: Date())
        let dir = URL(fileURLWithPath: Self.recordingsDir)
        var url = dir.appendingPathComponent("\(base).m4a")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(n).m4a")
            n += 1
        }
        return url
    }
}

extension RecordingManager: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let input = sysAudioInput, input.isReadyForMoreMediaData,
              let writer = sysWriter else { return }
        if !sysWriterStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sysWriterStarted = true
        }
        input.append(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.isRecording = false }
    }
}
```

- [ ] **Step 2: Build to confirm no errors**
```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote/FloatNote && swift build 2>&1 | head -30
```
Expected: no errors.

- [ ] **Step 3: Commit**
```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote && git add FloatNote/FloatNote/App.swift && git commit -m "feat: add RecordingManager with SCStream, AVAudioRecorder, and AVMutableComposition merge"
```

---

## Task 3: Wire ViewModel and AppDelegate

**Files:**
- Modify: `FloatNote/FloatNote/App.swift:111–341` (EditorViewModel)
- Modify: `FloatNote/FloatNote/App.swift:41–54` (AppDelegate)

- [ ] **Step 1: Add recording properties to `EditorViewModel`** — insert after `var draggingTabId: UUID?` (line 122):

```swift
@Published var isRecording = false
@Published var recordPermissionDenied = false
@Published var recordingTabId: UUID?
@Published var recordingStartTime: Date?
@Published var currentRecordingPath: String?

let recordingManager = RecordingManager()
```

- [ ] **Step 2: Add `startRecording()` and `stopRecording()`** — insert after `togglePin()` (after line 303):

```swift
func startRecording() async {
    let ok = await recordingManager.checkAndRequestPermissions()
    if !ok { recordPermissionDenied = true; return }
    recordPermissionDenied = false

    if let current = activeTab { current.html = currentHTML }

    let formatter = DateFormatter()
    formatter.dateFormat = "dd.MM - HH:mm"
    let tab = NoteTab(title: formatter.string(from: Date()))
    tabs.append(tab)
    recordingTabId = tab.id
    activeTabId = tab.id
    currentHTML = ""
    currentRecordingPath = nil
    isRecording = true
    recordingStartTime = Date()
    saveTabsLocal()

    await recordingManager.start()
}

func stopRecording() async {
    guard let url = await recordingManager.stop() else {
        isRecording = false
        return
    }
    isRecording = false
    recordingStartTime = nil
    currentRecordingPath = url.path

    if let tabId = recordingTabId, let tab = tabs.first(where: { $0.id == tabId }) {
        tab.recordingPath = url.path
    }
    recordingTabId = nil
    saveTabsLocal()
}
```

- [ ] **Step 3: Update `switchTab`** — after `activeTabId = id` (around line 194), add:

```swift
currentRecordingPath = newTab.recordingPath
```

- [ ] **Step 4: Update `addTab`** — after `currentHTML = ""` (around line 224), add:

```swift
currentRecordingPath = nil
```

- [ ] **Step 5: Update `AppDelegate.applicationShouldTerminate`** — replace the existing implementation (lines 49–53):

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let vm else { return .terminateNow }
    if vm.isRecording {
        Task {
            await vm.stopRecording()
            vm.saveLocalSync()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateCancel
    }
    vm.saveLocalSync()
    return .terminateNow
}
```

- [ ] **Step 6: Build**
```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote/FloatNote && swift build 2>&1 | head -30
```
Expected: no errors.

- [ ] **Step 7: Commit**
```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote && git add FloatNote/FloatNote/App.swift && git commit -m "feat: wire startRecording/stopRecording into ViewModel, handle quit mid-recording"
```

---

## Task 4: Add Record/Stop button to FormatToolbar

**Files:**
- Modify: `FloatNote/FloatNote/App.swift` — FormatToolbar body (around line 759)

- [ ] **Step 1: Add record/stop button** — after the closing `}` of the pin/mic `Group` block (after the mic button, around line 759), insert:

```swift
thinDivider()

Button(action: {
    if vm.recordPermissionDenied {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    } else if vm.isRecording {
        Task { await vm.stopRecording() }
    } else {
        Task { await vm.startRecording() }
    }
}) {
    Image(systemName: vm.isRecording ? "stop.circle.fill" : "record.circle")
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, minHeight: 22)
        .foregroundColor(
            vm.recordPermissionDenied ? .secondary.opacity(0.4) :
            vm.isRecording ? .red : .secondary
        )
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(hoveredButton == "rec" ? Color.primary.opacity(0.08) : Color.clear)
        )
}
.buttonStyle(.plain)
.onHover { hoveredButton = $0 ? "rec" : nil }
.opacity(vm.recordPermissionDenied ? 0.5 : 1.0)
.help(
    vm.recordPermissionDenied ? "Permission required — click to open Settings" :
    vm.isRecording ? "Stop Recording" : "Start Recording"
)
```

- [ ] **Step 2: Build**
```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote/FloatNote && swift build 2>&1 | head -20
```

- [ ] **Step 3: Commit**
```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote && git add FloatNote/FloatNote/App.swift && git commit -m "feat: add record/stop button to FormatToolbar"
```

---

## Task 5: Add RecordingInProgressView

**Files:**
- Modify: `FloatNote/FloatNote/App.swift` — add after `FormatToolbar` closing brace (around line 857)

- [ ] **Step 1: Add `RecordingInProgressView`**:

```swift
// MARK: - Recording In Progress View

struct RecordingInProgressView: View {
    let startTime: Date

    var body: some View {
        TimelineView(.periodic(from: startTime, by: 1.0)) { context in
            let elapsed = context.date.timeIntervalSince(startTime)
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Recording in progress")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text(timeString(elapsed))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
    }

    private func timeString(_ s: TimeInterval) -> String {
        let t = Int(max(0, s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
```

- [ ] **Step 2: Build**
```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote/FloatNote && swift build 2>&1 | head -20
```

- [ ] **Step 3: Commit**
```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote && git add FloatNote/FloatNote/App.swift && git commit -m "feat: add RecordingInProgressView with live elapsed timer"
```

---

## Task 6: Add RecordingPlayerView

**Files:**
- Modify: `FloatNote/FloatNote/App.swift` — add after `RecordingInProgressView`

- [ ] **Step 1: Add `RecordingPlayerView`**:

```swift
// MARK: - Recording Player View

struct RecordingPlayerView: View {
    let fileURL: URL
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var timeObserver: Any?
    @State private var fileExists = false

    var body: some View {
        VStack {
            Spacer()
            if !fileExists {
                Text("Recording file not found")
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 12) {
                    Button { togglePlay() } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)

                    Button { stopPlay() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)

                    Slider(value: Binding(get: { currentTime }, set: { seek(to: $0) }),
                           in: 0...max(duration, 1))

                    Text("\(timeString(currentTime)) / \(timeString(duration))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(minWidth: 80, alignment: .trailing)

                    Button("Open Folder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: RecordingManager.recordingsDir))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 20)
            }
            Spacer()
        }
        .onAppear { setupPlayer() }
        .onDisappear { cleanup() }
    }

    private func setupPlayer() {
        fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        guard fileExists else { return }
        let item = AVPlayerItem(url: fileURL)
        let p = AVPlayer(playerItem: item)
        player = p
        Task {
            if let dur = try? await item.asset.load(.duration), dur.isNumeric {
                duration = max(dur.seconds, 1)
            }
        }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { t in
            currentTime = t.seconds
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            isPlaying = false
            currentTime = 0
            p.seek(to: .zero)
        }
    }

    private func cleanup() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        player?.pause()
        player = nil
    }

    private func togglePlay() {
        guard let p = player else { return }
        isPlaying ? p.pause() : p.play()
        isPlaying.toggle()
    }

    private func stopPlay() {
        player?.pause()
        player?.seek(to: .zero)
        isPlaying = false
        currentTime = 0
    }

    private func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
    }

    private func timeString(_ s: Double) -> String {
        guard s.isFinite && s >= 0 else { return "0:00" }
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
```

- [ ] **Step 2: Build**
```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote/FloatNote && swift build 2>&1 | head -20
```

- [ ] **Step 3: Commit**
```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote && git add FloatNote/FloatNote/App.swift && git commit -m "feat: add RecordingPlayerView with play/pause, stop, scrubber, open folder"
```

---

## Task 7: Update EditorView to show recording views

**Files:**
- Modify: `FloatNote/FloatNote/App.swift:354-355` (EditorView body)

- [ ] **Step 1: Replace `RichTextEditor()` in `EditorView.body`** — current lines 354–355:

```swift
RichTextEditor()
    .environmentObject(vm)
```

Replace with:

```swift
if vm.isRecording && vm.activeTabId == vm.recordingTabId {
    RecordingInProgressView(startTime: vm.recordingStartTime ?? Date())
} else if let path = vm.currentRecordingPath {
    RecordingPlayerView(fileURL: URL(fileURLWithPath: path))
} else {
    RichTextEditor()
        .environmentObject(vm)
}
```

- [ ] **Step 2: Build**
```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote/FloatNote && swift build 2>&1 | head -20
```

- [ ] **Step 3: Commit**
```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote && git add FloatNote/FloatNote/App.swift && git commit -m "feat: EditorView conditionally renders recording views"
```

---

## Task 8: Update Info.plist and bump version

**Files:**
- Modify: `FloatNote/Info.plist`
- Modify: `FloatNote/FloatNote/App.swift:16`

- [ ] **Step 1: Update `NSMicrophoneUsageDescription`** in `FloatNote/Info.plist` (line 26):

```xml
<key>NSMicrophoneUsageDescription</key>
<string>FloatNote needs microphone access for dictation and audio recording.</string>
```

- [ ] **Step 2: Bump `APP_VERSION`** in App.swift line 16:

```swift
let APP_VERSION = "v1.6.0"
```

- [ ] **Step 3: Commit**
```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote && git add FloatNote/Info.plist FloatNote/FloatNote/App.swift && git commit -m "chore: update mic usage description and bump to v1.6.0"
```

---

## Task 9: Build, deploy, and manual test

- [ ] **Step 1: Build and deploy**
```bash
cd /Users/cagdas.agirtas/CodTemp/floatnote && ./build.sh
```
Expected: Build succeeds, FloatNote.app opens.

- [ ] **Step 2: Test permission prompt** — Click the record button (circle icon in toolbar):
  - macOS prompts for Microphone permission → Allow
  - macOS prompts for Screen Recording permission → System Settings → enable FloatNote → restart app

- [ ] **Step 3: Test record start**
  - Click record → new tab appears titled e.g. `06.04 - 14:32`
  - Tab body shows red dot + "Recording in progress" + live timer
  - Toolbar button is now red stop icon

- [ ] **Step 4: Test stop**
  - Click stop → recording finalizes (1–3s for merge)
  - Tab switches to player: `▶ ■ ───●─── 0:04 / 0:04  Open Folder`

- [ ] **Step 5: Test playback**
  - Click ▶ → audio plays (mic + system audio mixed)
  - Scrubber moves as audio plays
  - Timer shows elapsed / total
  - ■ resets to beginning

- [ ] **Step 6: Test Open Folder**
  - Click "Open Folder" → Finder opens `~/.floatnote-recordings/`
  - M4A file present with correct timestamp name

- [ ] **Step 7: Test quit mid-recording**
  - Start a recording, then Cmd+Q
  - App pauses to finalize recording before quitting
  - Relaunch → recording tab is restored with player UI and file intact

- [ ] **Step 8: Test permission denied**
  - System Settings → Privacy → Microphone → disable FloatNote → relaunch
  - Record button is dimmed/greyed
  - Clicking opens System Settings to Microphone privacy page

- [ ] **Step 9: Test tab switch during recording**
  - Start recording → switch to another tab → switch back to recording tab
  - Recording tab still shows "Recording in progress" with continued timer
