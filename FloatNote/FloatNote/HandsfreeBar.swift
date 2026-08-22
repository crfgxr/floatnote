import SwiftUI
import AVFoundation
import Speech

/// Slim voice bar docked under the terminal tab bar. Shows what hands-free is
/// doing — what it heard, what it's about to send — and carries its controls.
/// Hidden entirely while hands-free is off, so the terminal panel looks exactly
/// as it did before the feature existed.
struct HandsfreeBar: View {
    @ObservedObject var handsfree = HandsfreeManager.shared
    @EnvironmentObject var vm: EditorViewModel
    @State private var hovered: String?
    @State private var hintIndex = 0

    /// Rotated under the waveform while the mic is open and nothing has been
    /// said yet — the command vocabulary is invisible otherwise.
    private static let hints = [
        "Say “send it” to submit",
        "Say “stop” to interrupt Claude",
        "Say “cmd clear” to run /clear",
        "Say “delete message” to start over",
        "Say “focus window 2” to switch panes",
    ]
    private let hintTick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            HandsfreeWaveform(state: handsfree.state, level: handsfree.audioLevel)
                .frame(width: 64, height: 16)

            centerText
                .frame(maxWidth: .infinity, alignment: .leading)

            if !handsfree.liveTranscript.isEmpty {
                iconButton("arrow.counterclockwise", id: "reset", tint: .secondary,
                           help: "Clear what was heard") {
                    handsfree.clearTranscript()
                }
            }

            iconButton(handsfree.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       id: "mute",
                       tint: handsfree.isMuted ? Tokens.SUI.handsfreeListening : .secondary,
                       help: handsfree.isMuted ? "Unmute (mic + voice)" : "Mute (mic + voice)") {
                handsfree.toggleMute()
            }

            primaryButton

            iconButton("gearshape.fill", id: "gear", tint: .secondary, help: "Voice settings") {
                showSettingsMenu()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(vm.theme.chromeBackground)
        .onReceive(hintTick) { _ in hintIndex = (hintIndex + 1) % Self.hints.count }
    }

    /// The live transcript takes over the middle of the bar as soon as there is
    /// one: while dictating, what was heard matters more than the state name.
    @ViewBuilder
    private var centerText: some View {
        if !handsfree.liveTranscript.isEmpty {
            // Hugs its content: one spoken line is one line tall, and it grows
            // to at most three. A ScrollView here reserved its full height even
            // while empty, which left a slab of dead space under the bar.
            // Head truncation keeps the newest words in view; the whole
            // utterance is still buffered and still gets sent.
            Text(handsfree.liveTranscript)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(3)
                .truncationMode(.head)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if handsfree.state == .listening && !handsfree.awaitingQuickResponse {
            Text(Self.hints[hintIndex])
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .id(hintIndex)
                .transition(.opacity)
        } else {
            Text(handsfree.statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(statusColor)
                .lineLimit(1)
        }
    }

    private var primaryButton: some View {
        Button(action: { handsfree.primaryAction() }) {
            Text(primaryLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(primaryTint)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(primaryTint.opacity(hovered == "primary" ? 0.26 : 0.16))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? "primary" : nil }
        .help(primaryHelp)
    }

    private var primaryLabel: String {
        switch handsfree.state {
        case .idle:       return "Speak Now"
        case .listening:  return handsfree.liveTranscript.isEmpty ? "Listening" : "Send It"
        case .speaking:   return "Stop"
        case .processing: return "Stop Claude"
        }
    }

    private var primaryHelp: String {
        switch handsfree.state {
        case .idle:       return "Open the microphone"
        case .listening:  return handsfree.liveTranscript.isEmpty
                                 ? "Waiting for you to speak" : "Send this to Claude"
        case .speaking:   return "Stop reading the response"
        case .processing: return "Interrupt Claude (ESC)"
        }
    }

    private var primaryTint: Color {
        switch handsfree.state {
        case .speaking:   return .accentColor
        case .listening:  return handsfree.liveTranscript.isEmpty
                                 ? Tokens.SUI.handsfreeListening : Tokens.SUI.boardHasContent
        case .processing: return Tokens.SUI.overrideTint
        case .idle:       return .secondary
        }
    }

    private var statusColor: Color {
        switch handsfree.state {
        case .speaking:   return .accentColor
        case .listening:  return Tokens.SUI.handsfreeListening
        case .processing: return Tokens.SUI.overrideTint
        case .idle:       return .secondary
        }
    }

    private func iconButton(_ symbol: String, id: String, tint: Color, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundColor(tint)
                .frame(width: 20, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hovered == id ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? id : nil }
        .help(help)
    }

    /// Response mode, voice, recognition language and loop behavior, as an
    /// NSMenu popped at the mouse. A menu keeps the bar itself to a single row —
    /// these are set-once settings and don't deserve permanent chrome.
    private func showSettingsMenu() {
        let menu = NSMenu()
        let target = HandsfreeMenuTarget.shared

        for mode in ResponseMode.allCases {
            let item = NSMenuItem(title: mode.title,
                                  action: #selector(HandsfreeMenuTarget.selectMode(_:)),
                                  keyEquivalent: "")
            item.target = target
            item.representedObject = mode.rawValue
            item.state = handsfree.responseMode == mode ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let voiceItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu()
        let systemItem = NSMenuItem(title: "System Default",
                                    action: #selector(HandsfreeMenuTarget.selectVoice(_:)),
                                    keyEquivalent: "")
        systemItem.target = target
        systemItem.representedObject = HandsfreeManager.systemVoiceId
        systemItem.state = handsfree.voiceId == HandsfreeManager.systemVoiceId ? .on : .off
        voiceMenu.addItem(systemItem)
        voiceMenu.addItem(.separator())
        for voice in VoiceEngine.selectableVoices() {
            let item = NSMenuItem(title: "\(voice.name) (\(VoiceEngine.qualityLabel(voice)))",
                                  action: #selector(HandsfreeMenuTarget.selectVoice(_:)),
                                  keyEquivalent: "")
            item.target = target
            item.representedObject = voice.identifier
            item.state = handsfree.voiceId == voice.identifier ? .on : .off
            voiceMenu.addItem(item)
        }
        voiceItem.submenu = voiceMenu
        menu.addItem(voiceItem)

        // Recognition language — separate from the TTS voice, and only the
        // locales this Mac actually has a recognizer for.
        let langItem = NSMenuItem(title: "Recognize", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for (title, id) in HandsfreeBar.recognitionLocales() {
            let item = NSMenuItem(title: title,
                                  action: #selector(HandsfreeMenuTarget.selectLocale(_:)),
                                  keyEquivalent: "")
            item.target = target
            item.representedObject = id
            item.state = handsfree.localeId == id ? .on : .off
            langMenu.addItem(item)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        menu.addItem(.separator())

        let barge = NSMenuItem(title: "Interrupt When I Speak",
                               action: #selector(HandsfreeMenuTarget.toggleBargeIn),
                               keyEquivalent: "")
        barge.target = target
        barge.state = handsfree.bargeInEnabled ? .on : .off
        menu.addItem(barge)

        let auto = NSMenuItem(title: "Auto-Send After 3s Silence",
                              action: #selector(HandsfreeMenuTarget.toggleAutoSend),
                              keyEquivalent: "")
        auto.target = target
        auto.state = handsfree.autoSendEnabled ? .on : .off
        menu.addItem(auto)

        let commandsItem = NSMenuItem(title: "Voice Commands", action: nil, keyEquivalent: "")
        let commandsMenu = NSMenu()
        for line in [
            "“send it” — submit what you said",
            "“stop” — interrupt Claude (ESC)",
            "“delete message” — start the sentence over",
            "“cmd clear” — run a slash command",
            "“focus window 2” — switch terminal pane",
            "“yes” / “no” / “two” — answer a prompt",
        ] {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            commandsMenu.addItem(item)
        }
        commandsItem.submenu = commandsMenu
        menu.addItem(commandsItem)

        menu.addItem(.separator())
        let test = NSMenuItem(title: "Test Voice",
                              action: #selector(HandsfreeMenuTarget.testTTS), keyEquivalent: "")
        test.target = target
        menu.addItem(test)
        let settings = NSMenuItem(title: "System Voice Settings…",
                                  action: #selector(HandsfreeMenuTarget.openSpokenContent),
                                  keyEquivalent: "")
        settings.target = target
        menu.addItem(settings)

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// System default plus the installed recognition locales, English and the
    /// Mac's own language first — the full list is ~60 entries of noise.
    static func recognitionLocales() -> [(String, String)] {
        var out: [(String, String)] = [("System Default", HandsfreeManager.systemLocaleId)]
        let supported = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        let preferred = ["en-US", "en-GB", Locale.current.identifier.replacingOccurrences(of: "_", with: "-")]
        var seen = Set<String>()
        for id in preferred where supported.contains(id) && seen.insert(id).inserted {
            out.append((Locale.current.localizedString(forIdentifier: id) ?? id, id))
        }
        return out
    }
}

/// `NSMenuItem` needs an ObjC target; SwiftUI views can't be one.
@MainActor
final class HandsfreeMenuTarget: NSObject {
    static let shared = HandsfreeMenuTarget()

    @objc func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ResponseMode(rawValue: raw) else { return }
        HandsfreeManager.shared.setResponseMode(mode)
    }

    @objc func selectVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        HandsfreeManager.shared.setVoice(id)
    }

    @objc func selectLocale(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        HandsfreeManager.shared.setLocale(id)
    }

    @objc func toggleBargeIn() {
        HandsfreeManager.shared.setBargeIn(!HandsfreeManager.shared.bargeInEnabled)
    }

    @objc func toggleAutoSend() {
        HandsfreeManager.shared.setAutoSend(!HandsfreeManager.shared.autoSendEnabled)
    }

    @objc func testTTS() { HandsfreeManager.shared.testTTS() }

    @objc func openSpokenContent() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")!)
    }
}

/// Compact equalizer. Animated only while the mic or playback is live — a
/// static bar row when idle costs nothing, and this sits in a panel that's
/// always on screen.
struct HandsfreeWaveform: View {
    let state: HandsfreeState
    let level: CGFloat

    private static let barCount = 20
    @State private var phase: CGFloat = 0
    private let tick = Timer.publish(every: 1.0 / 15.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let barWidth = max(1, (geo.size.width - spacing * CGFloat(Self.barCount - 1))
                               / CGFloat(Self.barCount))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<Self.barCount, id: \.self) { i in
                    Capsule()
                        .fill(tint)
                        .frame(width: barWidth, height: height(for: i, in: geo.size.height))
                }
            }
            .frame(height: geo.size.height, alignment: .center)
        }
        .onReceive(tick) { _ in
            guard isActive else { return }
            phase += 0.35
        }
    }

    private var isActive: Bool { state == .speaking || state == .listening }

    private var tint: Color {
        switch state {
        case .speaking:   return .accentColor
        case .listening:  return Tokens.SUI.handsfreeListening
        case .processing: return Tokens.SUI.overrideTint
        case .idle:       return .secondary.opacity(0.35)
        }
    }

    private func height(for index: Int, in maxHeight: CGFloat) -> CGFloat {
        guard isActive else { return 2 }
        // Offset sine per bar so the row ripples rather than pulsing as one block.
        let wave = (sin(phase + CGFloat(index) * 0.6) + 1) / 2
        return max(2, maxHeight * (0.2 + 0.8 * wave * max(level, 0.15)))
    }
}
