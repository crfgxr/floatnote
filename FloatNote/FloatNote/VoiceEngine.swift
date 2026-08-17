import AVFoundation
import AppKit

/// Text-to-speech for hands-free voice.
///
/// Speech is rendered to a file with `/usr/bin/say -o` and then played through
/// `AVAudioPlayer`, rather than spoken directly by `AVSpeechSynthesizer`. The
/// upstream project (claude-code-handsfree) moved to this two-step approach
/// because direct synthesis stutters under CPU load — exactly the condition a
/// Claude Code turn ends in. It also keeps FloatNote's recording stack alone.
///
/// Phase 2 of `docs/superpowers/specs/2026-08-06-handsfree-voice-design.md`.
/// Recording/recognition lands here in phase 3.
final class VoiceEngine: NSObject, AVAudioPlayerDelegate {
    static let shared = VoiceEngine()

    private var audioPlayer: AVAudioPlayer?
    private var sayProcess: Process?
    private var speechCompletion: (() -> Void)?
    /// Bumped on every `speak`/`stopSpeaking` so a render that finishes after we
    /// moved on can't start playing over the top of a newer one.
    private var generation = 0
    private let ttsFileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("floatnote-tts.aiff")

    /// When playback actually began — not when rendering started. Barge-in
    /// detection (phase 5) keys off this, because the state flips to `.speaking`
    /// while `say` is still writing the file.
    private(set) var speechStartedAt: Date?

    /// Render `text` with `voiceId`, then play it. `completion` runs on the main
    /// queue when playback finishes, is superseded, or fails — never dropped, or
    /// the hands-free loop would wedge in `.speaking` forever.
    func speak(_ text: String, voiceId: String, completion: @escaping () -> Void) {
        stopSpeaking()

        let cleaned = Self.cleanForSpeech(text)
        guard !cleaned.isEmpty else {
            DispatchQueue.main.async { completion() }
            return
        }

        generation += 1
        let gen = generation
        speechCompletion = completion
        let voiceName = Self.resolveVoiceName(voiceId)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            var args: [String] = []
            if let voiceName { args += ["-v", voiceName] }
            args += ["-o", self.ttsFileURL.path, "-f", "-"]
            process.arguments = args

            let pipe = Pipe()
            process.standardInput = pipe
            self.sayProcess = process

            do {
                try process.run()
                pipe.fileHandleForWriting.write(cleaned.data(using: .utf8) ?? Data())
                pipe.fileHandleForWriting.closeFile()
                process.waitUntilExit()
            } catch {
                dbg("tts: render failed: \(error)")
                DispatchQueue.main.async {
                    guard self.generation == gen else { return }
                    self.finish()
                }
                return
            }

            DispatchQueue.main.async {
                // A newer utterance (or a stop) happened while we were rendering.
                guard self.generation == gen else { return }
                self.play()
            }
        }
        dbg("tts: rendering \(cleaned.count)ch, voice=\(voiceName ?? "default")")
    }

    private func play() {
        do {
            let player = try AVAudioPlayer(contentsOf: ttsFileURL)
            player.delegate = self
            audioPlayer = player
            player.play()
            speechStartedAt = Date()
            dbg("tts: playing \(String(format: "%.1f", player.duration))s")
        } catch {
            dbg("tts: playback failed: \(error)")
            finish()
        }
    }

    /// Cancel any in-flight render and playback. Does NOT call the completion —
    /// the caller is the one moving on.
    func stopSpeaking() {
        generation += 1
        if let process = sayProcess, process.isRunning { process.terminate() }
        sayProcess = nil
        audioPlayer?.stop()
        audioPlayer = nil
        speechStartedAt = nil
        speechCompletion = nil
    }

    /// True while an utterance is rendering or playing.
    var isSpeaking: Bool { audioPlayer?.isPlaying ?? false }

    private func finish() {
        audioPlayer = nil
        sayProcess = nil
        speechStartedAt = nil
        let completion = speechCompletion
        speechCompletion = nil
        completion?()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in self?.finish() }
    }

    // MARK: - Voice resolution

    /// Voices offered in the settings menu: English, and good enough to listen
    /// to for a whole workday (enhanced, premium, or Siri).
    static func selectableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter {
                $0.language.hasPrefix("en") &&
                ($0.quality == .enhanced || $0.quality == .premium || $0.identifier.contains("siri"))
            }
            .sorted {
                $0.quality.rawValue != $1.quality.rawValue
                    ? $0.quality.rawValue > $1.quality.rawValue
                    : $0.name < $1.name
            }
    }

    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        if voice.identifier.contains("siri") { return "Siri" }
        return voice.quality == .premium ? "Premium" : "Enhanced"
    }

    /// `say -v` takes a voice *name*, so map the stored identifier to one.
    /// `HandsfreeManager.systemVoiceId` means "whatever System Settings ›
    /// Spoken Content is set to", which `say` already does when given no `-v`.
    private static func resolveVoiceName(_ voiceId: String) -> String? {
        guard voiceId != HandsfreeManager.systemVoiceId else { return nil }
        if let voice = AVSpeechSynthesisVoice(identifier: voiceId) { return voice.name }
        return voiceId.components(separatedBy: ".").last.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Text preparation

    /// Strip the markdown Claude writes for a screen into something worth
    /// hearing: code blocks are announced, not read; inline code, headings,
    /// emphasis and list bullets are dropped; URLs collapse to "link".
    static func cleanForSpeech(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " code block omitted ",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "`[^`]+`", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^#{1,6}\\s+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[*_]{1,3}", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "https?://\\S+", with: "link", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^\\s*[-*+]\\s+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First + last sentence, for `.summary` mode. Short text is returned whole.
    static func summarize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentences = trimmed.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard sentences.count > 2, let first = sentences.first, let last = sentences.last else {
            return trimmed
        }
        return first + ". " + last + "."
    }
}
