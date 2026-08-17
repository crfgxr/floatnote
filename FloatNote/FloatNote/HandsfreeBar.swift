import SwiftUI
import AVFoundation

/// Slim voice bar docked under the terminal tab bar. Shows what hands-free is
/// doing and carries its controls. Hidden entirely while hands-free is off, so
/// the terminal panel looks exactly as it did before the feature existed.
///
/// Phase 2 renders the speaking half: waveform, status, mute, settings. The
/// live transcript, reset button and primary "Say 'Send It'" capsule arrive
/// with the recognizer in phase 3.
struct HandsfreeBar: View {
    @ObservedObject var handsfree = HandsfreeManager.shared
    @EnvironmentObject var vm: EditorViewModel
    @State private var hovered: String?

    var body: some View {
        HStack(spacing: 8) {
            HandsfreeWaveform(state: handsfree.state, level: handsfree.audioLevel)
                .frame(width: 76, height: 16)

            Text(handsfree.statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(statusColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            iconButton(handsfree.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       id: "mute",
                       tint: handsfree.isMuted ? Tokens.SUI.handsfreeListening : .secondary,
                       help: handsfree.isMuted ? "Unmute" : "Mute") {
                handsfree.toggleMute()
            }

            iconButton("gearshape.fill", id: "gear", tint: .secondary, help: "Voice settings") {
                showSettingsMenu()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(vm.theme.chromeBackground)
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

    /// Response mode + voice picker, as an NSMenu popped at the mouse. A menu
    /// keeps the bar itself to a single row — the settings are set-once and
    /// don't deserve permanent chrome.
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

    @objc func testTTS() { HandsfreeManager.shared.testTTS() }

    @objc func openSpokenContent() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")!)
    }
}

/// Compact equalizer. Animated only while speaking or listening — a static bar
/// row when idle costs nothing, and this sits in a panel that's always on screen.
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
