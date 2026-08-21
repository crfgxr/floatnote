import AppKit
import Combine
import SwiftUI

/// Where a hands-free session is in the speak → listen → submit loop.
///
/// The microphone is *not* implied by the state: it stays live through
/// `.listening`, `.speaking` (barge-in) and `.processing` (so "stop" can
/// interrupt Claude mid-run), and is only released in `.idle`.
enum HandsfreeState {
    /// Enabled, but the mic is released — muted, paused after a long silence,
    /// or yielded to meeting recording.
    case idle
    /// Reading Claude's turn aloud.
    case speaking
    /// Mic live, dictating a reply.
    case listening
    /// Reply submitted; Claude is working. Mic stays live for "stop".
    case processing
}

/// How much of Claude's turn gets read aloud.
enum ResponseMode: String, CaseIterable {
    /// Opening sentence + the ask, capped. The default: a whole Claude turn is
    /// prose written for a screen, and reading it out takes ~35 seconds to
    /// deliver about two lines of news.
    case brief
    case full
    case summary
    case notify

    var title: String {
        switch self {
        case .brief:   return "Brief — Result + Question"
        case .full:    return "Full Response"
        case .summary: return "Summary (First + Last Sentence)"
        case .notify:  return "Notify Only"
        }
    }
}

/// Owns hands-free policy and state: what gets spoken, in which voice, what the
/// microphone hears, and where the resulting text is sent. The transport in is
/// FloatNote's existing Claude hook spool (`EditorViewModel.checkClaudeEvents()`);
/// the transport out is `TerminalSessions` — the exact pane, no synthetic
/// keystrokes and no Accessibility permission.
///
/// Spec: `docs/superpowers/specs/2026-08-06-handsfree-voice-design.md`.
@MainActor
final class HandsfreeManager: ObservableObject {
    static let shared = HandsfreeManager()

    /// Sentinel voice id meaning "follow System Settings › Spoken Content".
    nonisolated static let systemVoiceId = "system"
    /// Sentinel locale id meaning "recognize in the Mac's current language".
    nonisolated static let systemLocaleId = "system"

    /// Master switch, toggled by the toolbar mic button. Off = the hook still
    /// posts its banner, nothing is spoken and the mic is never opened.
    @Published private(set) var isEnabled = false
    @Published private(set) var state: HandsfreeState = .idle
    @Published private(set) var isMuted = false
    @Published private(set) var statusText = "Ready"
    /// 0…1, drives the waveform: real mic level while listening, simulated
    /// while speaking (playback goes to the speakers, not the mic).
    @Published var audioLevel: CGFloat = 0
    /// What the recognizer has heard so far in this utterance.
    @Published private(set) var liveTranscript = ""
    /// A Claude permission prompt is on screen: "yes" / "no" / a number answers it.
    @Published private(set) var awaitingQuickResponse = false
    /// True while the recognizer holds the microphone.
    @Published private(set) var micActive = false

    @Published private(set) var responseMode: ResponseMode = {
        UserDefaults.standard.string(forKey: "fn.handsfreeResponseMode")
            .flatMap(ResponseMode.init(rawValue:)) ?? .brief
    }()

    @Published private(set) var voiceId: String = {
        UserDefaults.standard.string(forKey: "fn.handsfreeVoiceId") ?? systemVoiceId
    }()

    @Published private(set) var localeId: String = {
        UserDefaults.standard.string(forKey: "fn.handsfreeLocale") ?? systemLocaleId
    }()

    /// Talking over Claude's own speech interrupts it. On by default.
    @Published private(set) var bargeInEnabled: Bool = {
        UserDefaults.standard.object(forKey: "fn.handsfreeBargeIn") as? Bool ?? true
    }()

    /// Submit automatically after `autoSendDelay` of silence, instead of waiting
    /// for "send it". Off by default — a pause mid-thought would otherwise send
    /// half a sentence.
    @Published private(set) var autoSendEnabled: Bool = {
        UserDefaults.standard.object(forKey: "fn.handsfreeAutoSend") as? Bool ?? false
    }()

    /// Set once at launch; used to resolve panes, send text and navigate.
    weak var vm: EditorViewModel?

    /// Seconds of silence before `autoSendEnabled` submits.
    private let autoSendDelay: TimeInterval = 3.0
    /// Seconds of total silence before the mic is released (it re-opens when
    /// Claude next speaks, or from the bar's Speak Now button).
    private let idleTimeout: TimeInterval = 120
    /// Playback must have been audible this long before speech counts as
    /// barge-in — the state flips to `.speaking` while `say` is still
    /// rendering, and the mic also picks up the speakers (no echo cancellation).
    private let bargeInGrace: TimeInterval = 0.6

    private var levelTimer: Timer?
    private var tickTimer: Timer?
    /// Transcript from tasks that already finalized within this utterance.
    private var committedTranscript = ""
    private var lastTranscriptChange = Date()
    /// The text currently being read aloud, for the barge-in echo filter.
    private var currentSpokenText = ""
    private var quickResponseDeadline: Date?
    /// The pane whose Claude asked for permission. A quick response goes THERE,
    /// not to whatever pane happens to be on screen when you answer — the
    /// prompt can come from a background agent, and "no" landing in the wrong
    /// terminal is worse than not answering at all.
    private var quickResponsePaneId: UUID?
    private var listenerWired = false

    private init() {}

    // MARK: - Enablement

    func toggle() { setEnabled(!isEnabled) }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        // The mic is exclusive and meeting recording owns it outright.
        if on, vm?.isRecording == true {
            statusText = "Stop recording first"
            dbg("handsfree: refused to start — recording in progress")
            return
        }
        isEnabled = on
        if on {
            isMuted = false
            // Editor dictation is a different mechanism (NSTextInputContext)
            // that would fight the recognizer for the mic.
            vm?.wantsDictation = false
            // The voice bar lives inside the terminal panel — with the panel
            // hidden the feature would be on with nothing to show for it.
            if vm?.isTerminalVisible == false { vm?.applyTerminalRouteForActiveNote() }
            statusText = "Starting…"
            dbg("handsfree: enabled")
            startTick()
            authorizeThenListen()
        } else {
            stopEverything()
            dbg("handsfree: disabled")
        }
    }

    /// Called when meeting recording starts — recording wins the microphone.
    func yieldToRecording() {
        guard isEnabled else { return }
        setEnabled(false)
        statusText = "Paused for recording"
    }

    private func authorizeThenListen() {
        SpeechListener.requestAuthorization { [weak self] ok in
            Task { @MainActor in
                guard let self, self.isEnabled else { return }
                guard ok else {
                    self.state = .idle
                    self.statusText = "Speech permission denied"
                    dbg("handsfree: speech authorization denied")
                    return
                }
                self.startMic()
            }
        }
    }

    // MARK: - Microphone

    private func wireListener() {
        guard !listenerWired else { return }
        listenerWired = true
        let listener = SpeechListener.shared
        listener.onTranscript = { [weak self] text, isFinal in
            Task { @MainActor in self?.handleTranscript(text, isFinal: isFinal) }
        }
        listener.onLevel = { [weak self] level in
            Task { @MainActor in
                guard let self, self.state != .speaking else { return }
                self.audioLevel = level
            }
        }
        listener.onUnavailable = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.micActive = false
                self.state = .idle
                self.statusText = message
                dbg("handsfree: \(message)")
            }
        }
    }

    /// Open the mic and start listening for a reply.
    func startMic() {
        guard isEnabled, !isMuted else { return }
        guard vm?.isRecording != true else {
            statusText = "Stop recording first"
            return
        }
        wireListener()
        resetTranscript()
        guard SpeechListener.shared.start(localeId: localeId) else { return }
        micActive = true
        if state != .speaking && state != .processing { state = .listening }
        lastTranscriptChange = Date()
        refreshStatus()
    }

    /// Release the mic but stay enabled.
    func pauseMic(reason: String? = nil) {
        SpeechListener.shared.stop()
        micActive = false
        audioLevel = 0
        resetTranscript()
        state = .idle
        statusText = reason ?? "Mic paused"
    }

    // MARK: - Speaking

    /// A Claude turn ended in `tab`. Speaks it per the current response mode,
    /// prefixed with the pane label when the pane isn't the one on screen, so
    /// several concurrent agents stay distinguishable.
    func handleTurnEnd(message: String, tab: TerminalTab) {
        guard isEnabled else { return }
        awaitingQuickResponse = false
        guard !isMuted else {
            // Muted still closes the loop — go back to listening for a reply.
            if micActive { state = .listening; refreshStatus() }
            return
        }
        let body: String
        switch responseMode {
        case .brief:   body = VoiceEngine.brief(message)
        case .full:    body = message
        case .summary: body = VoiceEngine.summarize(message)
        case .notify:  body = "Listening"
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let isActivePane = tab.id == vm?.activeTerminalId
        let text = isActivePane ? body : "\(tab.label): \(body)"
        dbg("handsfree: speak [\(responseMode.rawValue)] pane=\(tab.label) active=\(isActivePane)")
        speak(text)
    }

    /// Claude is asking for permission. Read the prompt, then take "yes" / "no"
    /// / a number as the answer for the next minute.
    func handlePermissionPrompt(message: String, tab: TerminalTab) {
        guard isEnabled, !isMuted else { return }
        let isActivePane = tab.id == vm?.activeTerminalId
        let prompt = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Claude needs your input." : message
        awaitingQuickResponse = true
        quickResponseDeadline = Date().addingTimeInterval(60)
        quickResponsePaneId = tab.id
        dbg("handsfree: permission prompt pane=\(tab.label)")
        speak((isActivePane ? "" : "\(tab.label): ") + prompt + " Say yes, no, or a number.")
    }

    func speak(_ text: String) {
        state = .speaking
        currentSpokenText = text
        statusText = "Speaking…"
        startLevelSimulation()
        VoiceEngine.shared.speak(text, voiceId: voiceId) { [weak self] in
            Task { @MainActor in self?.finishedSpeaking() }
        }
    }

    private func finishedSpeaking() {
        stopLevelSimulation()
        guard state == .speaking else { return }
        currentSpokenText = ""
        // Whatever the mic picked up during playback is our own voice.
        resetTranscript()
        SpeechListener.shared.restartTask()
        if micActive {
            state = .listening
        } else if isEnabled && !isMuted {
            startMic()
        } else {
            state = .idle
        }
        refreshStatus()
    }

    /// ⌘. — stop the voice immediately, whatever the recognizer is doing.
    /// Returns false when there was nothing to stop, so the key can fall
    /// through to its normal meaning.
    @discardableResult
    func stopSpeakingFromKeyboard() -> Bool {
        guard state == .speaking else { return false }
        dbg("handsfree: stop speaking (keyboard)")
        stopSpeaking()
        return true
    }

    /// Stop talking and go back to listening, without disabling hands-free.
    func stopSpeaking() {
        VoiceEngine.shared.stopSpeaking()
        stopLevelSimulation()
        currentSpokenText = ""
        state = micActive ? .listening : .idle
        refreshStatus()
    }

    private func stopEverything() {
        VoiceEngine.shared.stopSpeaking()
        SpeechListener.shared.stop()
        stopLevelSimulation()
        stopTick()
        micActive = false
        awaitingQuickResponse = false
        currentSpokenText = ""
        resetTranscript()
        state = .idle
        statusText = "Ready"
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted {
            VoiceEngine.shared.stopSpeaking()
            stopLevelSimulation()
            pauseMic(reason: "Muted")
        } else if isEnabled {
            startMic()
        }
    }

    func testTTS() {
        setEnabled(true)
        guard isEnabled else { return }
        speak("Hands-free voice is working. Reply out loud, then say send it.")
    }

    // MARK: - Transcript

    private func handleTranscript(_ text: String, isFinal: Bool) {
        let combined = (committedTranscript + " " + text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal { committedTranscript = combined }

        if state == .speaking {
            guard bargeInEnabled, canBargeIn(combined) else {
                // Our own speech bleeding into the mic, or barge-in disabled.
                if isFinal { committedTranscript = "" }
                return
            }
            dbg("handsfree: barge-in — \(combined.prefix(40))")
            stopSpeaking()
            // A bare "stop" during playback means "stop talking", not
            // "interrupt Claude" — the turn is already over.
            if VoiceEngine.isStopPhrase(combined) {
                clearTranscript()
                statusText = "Stopped"
                return
            }
        }

        guard state == .listening || state == .processing else { return }
        liveTranscript = combined
        lastTranscriptChange = Date()

        if let command = VoiceEngine.parseCommand(combined) {
            perform(command)
            return
        }
        if awaitingQuickResponse, Date() < (quickResponseDeadline ?? .distantPast),
           let key = VoiceEngine.parseQuickResponse(combined) {
            sendQuickResponse(key)
            return
        }
        refreshStatus()
    }

    /// Speech during playback is only the user if playback has actually been
    /// audible for a moment AND what came back isn't the TTS itself — the mic
    /// hears the speakers and there is no echo cancellation. Half the words
    /// coming straight out of what we're saying is enough to call it echo:
    /// the recognizer never transcribes TTS back word-perfectly, so requiring
    /// an exact match would cut Claude off mid-sentence.
    private func canBargeIn(_ text: String) -> Bool {
        guard let started = VoiceEngine.shared.speechStartedAt else {
            dbg("handsfree: barge-in check — playback not started yet")
            return false
        }
        let elapsed = Date().timeIntervalSince(started)
        let words = VoiceEngine.normalizeSpeech(text).split(separator: " ").count
        let overlap = VoiceEngine.echoOverlap(heard: text, spoken: currentSpokenText)
        // A single word is enough when it shares nothing with what we're saying
        // ("stop", "wait", "enough") — the cost of a false positive is a stopped
        // sentence, the cost of a false negative is being talked over.
        let loud = words >= 2 ? overlap < 0.5 : overlap == 0
        let ok = elapsed > bargeInGrace && loud
        dbg("handsfree: barge-in check heard=\"\(text.prefix(40))\" words=\(words) "
            + "overlap=\(String(format: "%.2f", overlap)) elapsed=\(String(format: "%.1f", elapsed))s → \(ok)")
        return ok
    }

    func clearTranscript() {
        resetTranscript()
        SpeechListener.shared.restartTask()
        refreshStatus()
    }

    private func resetTranscript() {
        committedTranscript = ""
        liveTranscript = ""
        lastTranscriptChange = Date()
    }

    // MARK: - Commands

    private func perform(_ command: VoiceCommand) {
        switch command {
        case .sendIt(let message):
            submit(message)
        case .stop:
            sendEscape()
        case .deleteMessage:
            clearTranscript()
            statusText = "Cleared"
        case .slash(let cmd):
            submit(cmd)
        case .focusPane(let index):
            focusPane(index)
        }
    }

    /// Submit `text` (default: everything dictated so far) to the pane that is
    /// active *now* — navigating mid-sentence lands the text where you ended up.
    func submit(_ text: String? = nil) {
        var message = (text ?? liveTranscript).trimmingCharacters(in: .whitespacesAndNewlines)
        message = VoiceEngine.stripTrailingSendTrigger(message)
        // "cmd clear send it" arrives here as "cmd clear".
        if case .slash(let cmd)? = VoiceEngine.parseCommand(message) { message = cmd }
        guard !message.isEmpty else {
            clearTranscript()
            statusText = "Nothing to send"
            return
        }
        guard let session = activeSession() else {
            clearTranscript()
            statusText = "No terminal"
            dbg("handsfree: submit dropped — no live pane")
            return
        }
        dbg("handsfree: send \(message.count)ch → \(activePaneLabel())")
        session.view.send(txt: message)
        // Enter is a carriage return, and it goes in a separate write: Claude
        // Code's TUI reads raw input, and a CR glued to the text can be swallowed
        // as part of a paste instead of submitting it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            session.view.send(txt: "\r")
        }
        clearTranscript()
        awaitingQuickResponse = false
        state = .processing
        statusText = "Sent — Claude is working…"
    }

    /// ESC to the active pane: interrupts whatever Claude is doing.
    func sendEscape() {
        guard let session = activeSession() else { return }
        session.view.send(txt: "\u{1b}")
        dbg("handsfree: ESC → \(activePaneLabel())")
        clearTranscript()
        awaitingQuickResponse = false
        state = micActive ? .listening : .idle
        statusText = "Interrupted"
    }

    /// Answer a permission prompt by "pressing" its number key, in the pane
    /// that asked.
    private func sendQuickResponse(_ key: String) {
        let paneId = quickResponsePaneId ?? vm?.activeTerminalId
        guard let paneId, let session = TerminalSessions.shared.existing(paneId) else {
            statusText = "That terminal is gone"
            dbg("handsfree: quick response dropped — prompting pane closed")
            clearTranscript()
            awaitingQuickResponse = false
            quickResponsePaneId = nil
            return
        }
        session.view.send(txt: key)
        let label = vm?.terminalTabs.first(where: { $0.id == paneId })?.label ?? "?"
        dbg("handsfree: quick response '\(key)' → \(label)")
        clearTranscript()
        awaitingQuickResponse = false
        quickResponsePaneId = nil
        state = .processing
        statusText = "Answered \(key)"
    }

    /// "focus window 2" — switch chip *and* navigate to that pane's note.
    func focusPane(_ index: Int) {
        guard let vm, index >= 1, index <= vm.terminalTabs.count else {
            statusText = "No pane \(index)"
            clearTranscript()
            return
        }
        let tab = vm.terminalTabs[index - 1]
        vm.selectTerminal(tab.id)
        clearTranscript()
        statusText = "Pane \(index): \(tab.label)"
        dbg("handsfree: focus pane \(index) (\(tab.label))")
    }

    /// The bar's primary capsule.
    func primaryAction() {
        switch state {
        case .idle:       startMic()
        case .listening:  liveTranscript.isEmpty ? clearTranscript() : submit()
        case .speaking:   stopSpeaking()
        case .processing: sendEscape()
        }
    }

    private func activeSession() -> TerminalSession? {
        guard let id = vm?.activeTerminalId else { return nil }
        return TerminalSessions.shared.existing(id)
    }

    private func activePaneLabel() -> String {
        guard let vm, let id = vm.activeTerminalId,
              let tab = vm.terminalTabs.first(where: { $0.id == id }) else { return "?" }
        return tab.label
    }

    // MARK: - Settings

    func setResponseMode(_ mode: ResponseMode) {
        responseMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "fn.handsfreeResponseMode")
    }

    func setVoice(_ id: String) {
        voiceId = id
        UserDefaults.standard.set(id, forKey: "fn.handsfreeVoiceId")
    }

    /// Changing the recognition language restarts the recognizer on the spot.
    func setLocale(_ id: String) {
        guard id != localeId else { return }
        localeId = id
        UserDefaults.standard.set(id, forKey: "fn.handsfreeLocale")
        guard micActive else { return }
        SpeechListener.shared.stop()
        micActive = false
        startMic()
    }

    func setBargeIn(_ on: Bool) {
        bargeInEnabled = on
        UserDefaults.standard.set(on, forKey: "fn.handsfreeBargeIn")
    }

    func setAutoSend(_ on: Bool) {
        autoSendEnabled = on
        UserDefaults.standard.set(on, forKey: "fn.handsfreeAutoSend")
    }

    // MARK: - Status

    private func refreshStatus() {
        switch state {
        case .speaking:
            statusText = "Speaking…"
        case .processing:
            statusText = awaitingQuickResponse ? "Waiting for Claude…" : "Claude is working…"
        case .listening:
            if awaitingQuickResponse {
                statusText = "Answer: yes, no, or a number"
            } else {
                statusText = liveTranscript.isEmpty ? "Listening…" : "Listening — say “send it”"
            }
        case .idle:
            statusText = isMuted ? "Muted" : (isEnabled ? "Mic paused" : "Ready")
        }
    }

    // MARK: - Timers

    /// One 1Hz tick drives auto-send and the idle mic release, instead of a
    /// timer per feature that would need cancelling from six places.
    private func startTick() {
        stopTick()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in HandsfreeManager.shared.tick() }
        }
    }

    private func stopTick() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        guard isEnabled else { return }
        if let deadline = quickResponseDeadline, Date() > deadline {
            awaitingQuickResponse = false
            quickResponseDeadline = nil
            quickResponsePaneId = nil
        }
        let silence = Date().timeIntervalSince(lastTranscriptChange)
        if state == .listening, autoSendEnabled, !liveTranscript.isEmpty, silence >= autoSendDelay {
            dbg("handsfree: auto-send after \(Int(silence))s silence")
            submit()
            return
        }
        if state == .listening, micActive, liveTranscript.isEmpty, silence >= idleTimeout {
            dbg("handsfree: mic released after \(Int(silence))s of silence")
            pauseMic(reason: "Mic paused — click Speak Now")
        }
    }

    /// While speaking there is no useful mic signal to visualise (playback goes
    /// to the speakers), so the bars are animated from a timer instead.
    private func startLevelSimulation() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            Task { @MainActor in
                guard HandsfreeManager.shared.state == .speaking else { return }
                HandsfreeManager.shared.audioLevel = CGFloat.random(in: 0.3...0.95)
            }
        }
    }

    private func stopLevelSimulation() {
        levelTimer?.invalidate()
        levelTimer = nil
        audioLevel = 0
    }
}
