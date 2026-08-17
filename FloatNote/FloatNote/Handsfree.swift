import AppKit
import Combine
import SwiftUI

/// Where a hands-free session is in the speak → listen → submit loop.
/// Phase 2 only ever reaches `.speaking`; `.listening` / `.processing` arrive
/// with the recognizer in phase 3.
enum HandsfreeState {
    case idle
    case speaking
    case listening
    case processing
}

/// How much of Claude's turn gets read aloud.
enum ResponseMode: String, CaseIterable {
    case full
    case summary
    case notify

    var title: String {
        switch self {
        case .full:    return "Full Response"
        case .summary: return "Summary (First + Last Sentence)"
        case .notify:  return "Notify Only"
        }
    }
}

/// Owns hands-free policy and state: what gets spoken, in which voice, and
/// (from phase 3) what the microphone is doing. The transport is FloatNote's
/// existing Claude hook spool — see `EditorViewModel.checkClaudeEvents()`.
///
/// Spec: `docs/superpowers/specs/2026-08-06-handsfree-voice-design.md`.
@MainActor
final class HandsfreeManager: ObservableObject {
    static let shared = HandsfreeManager()

    /// Sentinel voice id meaning "follow System Settings › Spoken Content".
    static let systemVoiceId = "system"

    /// Master switch, toggled by the toolbar mic button. Off = the hook still
    /// posts its banner, nothing is spoken.
    @Published private(set) var isEnabled = false
    @Published private(set) var state: HandsfreeState = .idle
    @Published var isMuted = false
    @Published private(set) var statusText = "Ready"
    /// 0…1, drives the waveform. Simulated while speaking; real mic level in phase 3.
    @Published var audioLevel: CGFloat = 0

    @Published private(set) var responseMode: ResponseMode = {
        UserDefaults.standard.string(forKey: "fn.handsfreeResponseMode")
            .flatMap(ResponseMode.init(rawValue:)) ?? .full
    }()

    @Published private(set) var voiceId: String = {
        UserDefaults.standard.string(forKey: "fn.handsfreeVoiceId") ?? systemVoiceId
    }()

    /// Set once at launch; used to resolve panes and (phase 3+) send text.
    weak var vm: EditorViewModel?

    private var levelTimer: Timer?

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
            statusText = "Ready"
            dbg("handsfree: enabled")
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

    // MARK: - Speaking

    /// A Claude turn ended in `tab`. Speaks it per the current response mode,
    /// prefixed with the pane label when the pane isn't the one on screen, so
    /// several concurrent agents stay distinguishable.
    func handleTurnEnd(message: String, tab: TerminalTab) {
        guard isEnabled, !isMuted else { return }
        let body: String
        switch responseMode {
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

    func speak(_ text: String) {
        state = .speaking
        statusText = "Speaking…"
        startLevelSimulation()
        VoiceEngine.shared.speak(text, voiceId: voiceId) { [weak self] in
            Task { @MainActor in self?.finishedSpeaking() }
        }
    }

    private func finishedSpeaking() {
        stopLevelSimulation()
        guard state == .speaking else { return }
        // Phase 3 starts listening here, closing the loop.
        state = .idle
        statusText = "Ready"
    }

    /// Stop talking and drop back to idle, without disabling hands-free.
    func stopSpeaking() {
        VoiceEngine.shared.stopSpeaking()
        stopLevelSimulation()
        state = .idle
        statusText = "Ready"
    }

    private func stopEverything() {
        VoiceEngine.shared.stopSpeaking()
        stopLevelSimulation()
        state = .idle
        statusText = "Ready"
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted { stopSpeaking() }
        statusText = isMuted ? "Muted" : "Ready"
    }

    func testTTS() {
        setEnabled(true)
        guard isEnabled else { return }
        isMuted = false
        speak("Hands-free voice is working. I'll read Claude's responses aloud when a turn ends.")
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

    // MARK: - Waveform level

    /// While speaking there is no mic signal to visualise (playback is going to
    /// the speakers), so the bars are animated from a timer instead.
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
