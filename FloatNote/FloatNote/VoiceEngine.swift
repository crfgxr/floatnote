import AVFoundation
import AppKit
import CoreAudio
import Speech

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
        s = s.replacingOccurrences(of: "(?m)^\\s*[-*+•]\\s+", with: "", options: .regularExpression)
        // Markdown table rows read as a wall of punctuation.
        s = s.replacingOccurrences(of: "(?m)^\\s*\\|.*$", with: "", options: .regularExpression)
        // Absolute paths and file:line references: unspeakable, and never the point.
        s = s.replacingOccurrences(of: "(?:~|\\.)?/[\\w.@~+-]+(?:/[\\w.@~+-]+)+(?::\\d+)?",
                                   with: "the file", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\b[\\w-]+\\.(swift|js|ts|json|md|sh|py|html|css):\\d+",
                                   with: "the file", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split into sentences, keeping their terminators.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    /// What a hands-free listener actually needs from a finished turn: what
    /// happened, and what is being asked of them. Reading a whole Claude turn
    /// out loud is ~35 seconds of prose written for a screen — file paths,
    /// bullet lists and all — for two lines of actual news.
    ///
    /// So: the opening sentence, plus the ask (the last question, or a closing
    /// "next step" line), capped at `maxWords` on a sentence boundary.
    static func brief(_ text: String, maxWords: Int = 45) -> String {
        let all = sentences(cleanForSpeech(text))
        guard let first = all.first else { return "" }
        var picked = [first]
        if let question = all.dropFirst().last(where: { $0.hasSuffix("?") }) {
            picked.append(question)
        } else if all.count > 1, let last = all.last, isNextStep(last), last != first {
            picked.append(last)
        }
        // Cap on a sentence boundary — a sentence cut mid-clause is worse than
        // one sentence fewer.
        var kept: [String] = []
        var words = 0
        for sentence in picked {
            let n = sentence.split(separator: " ").count
            if !kept.isEmpty && words + n > maxWords { break }
            kept.append(sentence)
            words += n
        }
        var out = kept.joined(separator: " ")
        // A single opening sentence can still be a monster; trim it hard.
        let flat = out.split(separator: " ")
        if flat.count > maxWords + 15 {
            out = flat.prefix(maxWords).joined(separator: " ") + "…"
        }
        return out
    }

    private static func isNextStep(_ sentence: String) -> Bool {
        let n = normalizeSpeech(sentence)
        return ["next", "want me", "should i", "shall i", "let me know", "tell me",
                "do you want", "ready when"].contains { n.hasPrefix($0) || n.contains($0) }
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

// MARK: - Voice commands

/// A spoken instruction found in the live transcript.
enum VoiceCommand: Equatable {
    /// Submit what has been dictated. Payload is the message with the trigger
    /// phrase stripped off ("add a toggle send it" → "add a toggle").
    case sendIt(String)
    /// Interrupt Claude — ESC to the pane.
    case stop
    /// Throw away the dictated message, keep listening.
    case deleteMessage
    /// Run a slash command: "cmd clear" → "/clear", "cmd model sonnet" → "/model sonnet".
    case slash(String)
    /// Switch to terminal pane N (1-based), chip + note navigation.
    case focusPane(Int)
}

extension VoiceEngine {

    /// Lowercase, drop punctuation, collapse whitespace. Command matching only —
    /// the text actually sent to Claude keeps its original casing.
    static func normalizeSpeech(_ text: String) -> String {
        var s = text.lowercased()
        s = s.replacingOccurrences(of: "[^\\p{L}\\p{N}\\s]", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Append one dictated fragment to another, dropping any overlap between
    /// them.
    ///
    /// A recognition task ends on a pause and the next one starts against the
    /// SAME live audio tap, so the tail of the sentence you just finished is
    /// re-consumed and comes back as the head of the next result. Appending
    /// blind said those words twice — which is what made a pause look like it
    /// "repeated the previous sentence". Compared word-wise on normalised
    /// words, longest overlap first, so punctuation and casing don't defeat it.
    static func joinDictation(_ committed: String, _ next: String) -> String {
        let head = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else { return tail }
        guard !tail.isEmpty else { return head }
        let headWords = head.split(separator: " ").map(String.init)
        let tailWords = tail.split(separator: " ").map(String.init)
        func norm(_ words: [String]) -> [String] {
            words.map { normalizeSpeech($0) }.filter { !$0.isEmpty }
        }
        let normHead = norm(headWords), normTail = norm(tailWords)
        // 8 words is about the longest tail the recognizer replays; beyond that
        // a match is more likely a real repetition the speaker meant.
        let limit = min(8, normHead.count, normTail.count)
        var drop = 0
        var k = limit
        while k >= 1 {
            if Array(normHead.suffix(k)) == Array(normTail.prefix(k)) { drop = k; break }
            k -= 1
        }
        guard drop > 0 else { return head + " " + tail }
        // The dropped words are counted in normalised space; skip the same
        // number of RAW words, whose punctuation we want to keep discarding too.
        var skipped = 0, index = 0
        while index < tailWords.count, skipped < drop {
            if !normalizeSpeech(tailWords[index]).isEmpty { skipped += 1 }
            index += 1
        }
        let rest = tailWords[index...].joined(separator: " ")
        return rest.isEmpty ? head : head + " " + rest
    }

    // Trailing triggers are matched against the END of the transcript, so a
    // whole dictated message can carry one. Turkish aliases are included
    // because the recognizer locale is user-selectable.
    private static let sendTriggers = ["send it", "send it now", "send that", "sent it",
                                       "send message", "gonder", "gönder"]
    private static let stopTriggers = ["stop", "stop it", "stop stop", "abort", "cancel that", "dur"]
    private static let deleteTriggers = ["delete message", "delete that", "clear message",
                                         "clear that", "scratch that", "never mind", "nevermind", "sil"]
    private static let focusPrefixes = ["focus window", "focus pane", "focus terminal",
                                        "switch to window", "switch to pane"]
    private static let slashPrefixes = ["cmd", "command", "slash"]
    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9,
    ]

    /// Recognize a command in `text`. Pure — no audio, no state — so the whole
    /// table in the spec can be exercised directly.
    static func parseCommand(_ text: String) -> VoiceCommand? {
        let n = normalizeSpeech(text)
        guard !n.isEmpty else { return nil }

        // "…send it" wins over everything else: the rest is the message.
        for trigger in sendTriggers where n == trigger || n.hasSuffix(" " + trigger) {
            return .sendIt(stripTrailing(trigger, from: text))
        }
        // Bare-utterance commands. Deliberately NOT suffix matches — "don't
        // stop the build" must not interrupt Claude.
        if stopTriggers.contains(n) { return .stop }
        if deleteTriggers.contains(n) { return .deleteMessage }

        let words = n.split(separator: " ").map(String.init)
        for prefix in focusPrefixes {
            let p = prefix.split(separator: " ").map(String.init)
            guard words.count == p.count + 1, Array(words.prefix(p.count)) == p,
                  let idx = numberWords[words[p.count]] else { continue }
            return .focusPane(idx)
        }
        if let first = words.first, slashPrefixes.contains(first), words.count > 1 {
            // First word is the command, the rest are its arguments:
            // "cmd clear" → /clear, "cmd model sonnet" → /model sonnet.
            return .slash("/" + words.dropFirst().joined(separator: " "))
        }
        return nil
    }

    /// Is this whole utterance just "stop"? Used for barge-in, where a single
    /// word is enough to mean it — everything else needs two.
    static func isStopPhrase(_ text: String) -> Bool {
        stopTriggers.contains(normalizeSpeech(text))
    }

    /// How much of `heard` also appears in `spoken`, 0…1. The mic picks up the
    /// speakers (there is no echo cancellation) but the recognizer never
    /// transcribes TTS back word-perfectly, so overlap beats equality.
    static func echoOverlap(heard: String, spoken: String) -> Double {
        let heardWords = normalizeSpeech(heard).split(separator: " ").map(String.init)
        guard !heardWords.isEmpty else { return 1 }
        let spokenWords = Set(normalizeSpeech(spoken).split(separator: " ").map(String.init))
        guard !spokenWords.isEmpty else { return 0 }
        let hits = heardWords.filter { spokenWords.contains($0) }.count
        return Double(hits) / Double(heardWords.count)
    }

    /// Remove a trailing trigger phrase from the ORIGINAL text (casing and
    /// punctuation of the message survive; the trigger and any punctuation
    /// glued to it do not).
    private static func stripTrailing(_ trigger: String, from text: String) -> String {
        let words = trigger.split(separator: " ")
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "[^\\p{L}\\p{N}]+")
        let pattern = "(?i)[^\\p{L}\\p{N}]*" + words + "[^\\p{L}\\p{N}]*$"
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words the recognizer should expect: command triggers plus the nouns
    /// this project is discussed in.
    static let contextualVocabulary = [
        "send it", "stop", "delete message", "cmd", "focus window",
        "barge-in", "hands-free", "Claude", "Claude Code", "FloatNote",
        "terminal", "commit", "transcript", "pane",
    ]

    /// Strip a trailing send-trigger the parser didn't act on — a bare "send",
    /// or a "send it" that arrived after the submit was already under way.
    /// Belt-and-braces: `parseCommand` strips the trigger it matched, this
    /// catches the leftovers so they never reach Claude.
    static func stripTrailingSendTrigger(_ text: String) -> String {
        let n = normalizeSpeech(text)
        for trigger in sendTriggers + ["send", "sent"] where n == trigger || n.hasSuffix(" " + trigger) {
            return stripTrailing(trigger, from: text)
        }
        return text
    }

    /// Answer to a Claude permission prompt: the key to press. Only consulted
    /// while `HandsfreeManager.awaitingQuickResponse` — "one" in the middle of
    /// a normal sentence must never pick an option.
    static func parseQuickResponse(_ text: String) -> String? {
        let n = normalizeSpeech(text)
        guard !n.isEmpty else { return nil }
        if ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "do it", "evet"].contains(n) { return "1" }
        if n.contains("always") || n.contains("don t ask") { return "2" }
        if ["no", "nope", "no thanks", "hayir", "hayır"].contains(n) { return "3" }
        guard let last = n.split(separator: " ").last.map(String.init),
              let idx = numberWords[last], idx <= 9 else { return nil }
        return String(idx)
    }
}

// MARK: - Speech recognition

/// Continuous microphone → text for hands-free voice.
///
/// One `AVAudioEngine` tap feeds a rolling series of
/// `SFSpeechAudioBufferRecognitionRequest`s: the engine runs for the whole
/// session while recognition *tasks* are cycled (each ends by itself after a
/// pause, or is cut short once we've acted on a command), so the mic never
/// audibly re-arms between utterances and stale audio can't be re-recognized
/// into a second submit.
final class SpeechListener {
    static let shared = SpeechListener()

    /// `(transcript, isFinal)` for the current task. Main queue.
    var onTranscript: ((String, Bool) -> Void)?
    /// 0…1 mic level, ~15fps. Main queue.
    var onLevel: ((CGFloat) -> Void)?
    /// The session can't continue (no recognizer, mic gone). Main queue.
    var onUnavailable: ((String) -> Void)?

    private(set) var isRunning = false

    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var task: SFSpeechRecognitionTask?
    /// Bumped per task so callbacks from a cancelled task are dropped — without
    /// this, a task cancelled right after "send it" can still deliver its final
    /// result and submit the same sentence twice.
    private var taskGen = 0
    /// Latest partial of the CURRENT task, so a task that dies without a final
    /// result can still hand its words over.
    private var lastPartial = ""
    private var lastLevelEmit = Date.distantPast
    /// Timestamps of automatic task restarts, for the runaway-loop guard.
    private var restarts: [Date] = []

    // The audio tap runs on a realtime thread while `request` is replaced on the
    // main queue, so it is behind a lock rather than accessed bare.
    private let requestLock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    private var request: SFSpeechAudioBufferRecognitionRequest? {
        get { requestLock.lock(); defer { requestLock.unlock() }; return _request }
        set { requestLock.lock(); _request = newValue; requestLock.unlock() }
    }

    private let deviceQueue = DispatchQueue(label: "com.floatnote.handsfree.device")
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var lastInputDevice: AudioDeviceID = 0
    private var pendingDeviceRebuild: DispatchWorkItem?

    // MARK: Authorization

    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            completion(true)
        case .denied, .restricted:
            completion(false)
        default:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async { completion(status == .authorized) }
            }
        }
    }

    // MARK: Session

    /// Start listening. `localeId` is `HandsfreeManager.systemLocaleId` or a
    /// BCP-47 identifier; an unsupported locale falls back to en-US.
    @discardableResult
    func start(localeId: String) -> Bool {
        guard !isRunning else { return true }
        let locale = localeId == HandsfreeManager.systemLocaleId
            ? Locale.current : Locale(identifier: localeId)
        guard let rec = SFSpeechRecognizer(locale: locale)
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              rec.isAvailable else {
            onUnavailable?("Speech recognition unavailable")
            return false
        }
        recognizer = rec
        do {
            try startEngine()
        } catch {
            dbg("handsfree: audio engine failed — \(error)")
            onUnavailable?("Microphone unavailable")
            return false
        }
        isRunning = true
        restarts = []
        startTask()
        installDeviceListener()
        dbg("handsfree: mic on (locale=\(rec.locale.identifier), onDevice=\(rec.supportsOnDeviceRecognition))")
        return true
    }

    func stop() {
        guard isRunning || engine != nil else { return }
        isRunning = false
        taskGen += 1
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        removeDeviceListener()
        onLevel?(0)
        dbg("handsfree: mic off")
    }

    /// Drop the current recognition task and open a fresh one. Called after a
    /// command fires, so the audio already consumed can't be re-delivered.
    func restartTask() {
        guard isRunning else { return }
        startTask()
    }

    // MARK: Engine

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "FloatNote.Handsfree", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No input format"])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)
            self.emitLevel(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        lastInputDevice = Self.currentInputDevice()
    }

    private func startTask() {
        taskGen += 1
        lastPartial = ""
        let gen = taskGen
        task?.cancel()
        request?.endAudio()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Bias the recognizer toward the vocabulary this app is spoken to in —
        // without it "barge-in" comes back as "embarrassing" and the "send it"
        // trigger gets lost as a bare "send".
        req.contextualStrings = VoiceEngine.contextualVocabulary
        // Dictated messages go to Claude as prose; punctuation makes them read
        // like a sentence instead of a transcript.
        req.addsPunctuation = true
        // On-device keeps a local-only app local, and lifts the ~1 minute cap
        // server-based recognition puts on a single request.
        if recognizer?.supportsOnDeviceRecognition == true { req.requiresOnDeviceRecognition = true }
        request = req

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.taskGen == gen, self.isRunning else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.lastPartial = result.isFinal ? "" : text
                    self.onTranscript?(text, result.isFinal)
                    if result.isFinal { self.scheduleRestart() }
                    return
                }
                if error != nil {
                    // A task that dies mid-sentence (the usual "no speech
                    // detected" / timeout) never reports a final result, so its
                    // words were being thrown away. Commit what it had heard
                    // before opening the next one.
                    if !self.lastPartial.isEmpty {
                        let text = self.lastPartial
                        self.lastPartial = ""
                        self.onTranscript?(text, true)
                    }
                    self.scheduleRestart()
                }
            }
        }
    }

    /// A task ends after every pause (and on "no speech detected"), so the
    /// normal path is simply to open the next one. The rate guard is for the
    /// abnormal path — a recognizer that fails instantly, forever.
    private func scheduleRestart() {
        guard isRunning else { return }
        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < 5 }
        restarts.append(now)
        if restarts.count > 8 {
            dbg("handsfree: recognizer restarting too fast — giving up")
            stop()
            onUnavailable?("Speech recognition failed")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isRunning else { return }
            self.startTask()
        }
    }

    private func emitLevel(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastLevelEmit) > 1.0 / 15.0,
              let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        lastLevelEmit = now
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
        let rms = sqrtf(sum / Float(buffer.frameLength))
        // −50 dB (room tone) … 0 dB (clipping) mapped onto the waveform's 0…1.
        let db = 20 * log10f(max(rms, 0.000_001))
        let level = CGFloat(max(0, min(1, (db + 50) / 50)))
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    // MARK: Input device changes

    /// `AVAudioEngine` binds its input node at creation and never follows the
    /// default input device, so plugging in AirPods would leave recognition on
    /// the built-in mic. Rebuild a *fresh* engine when the device actually
    /// changes — debounced, off the main queue, and only on a real change.
    /// (Driving this off `AVAudioEngineConfigurationChange` instead caused a
    /// main-thread rebuild loop that froze the app.)
    private func installDeviceListener() {
        guard deviceListener == nil else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.inputDeviceMayHaveChanged()
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, deviceQueue, block)
    }

    private func removeDeviceListener() {
        guard let block = deviceListener else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, deviceQueue, block)
        deviceListener = nil
        pendingDeviceRebuild?.cancel()
        pendingDeviceRebuild = nil
    }

    private func inputDeviceMayHaveChanged() {
        let current = Self.currentInputDevice()
        guard current != 0, current != lastInputDevice else { return }
        lastInputDevice = current
        pendingDeviceRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { self?.rebuildEngine() }
        }
        pendingDeviceRebuild = work
        deviceQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func rebuildEngine() {
        guard isRunning else { return }
        dbg("handsfree: input device changed — rebuilding engine")
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        do {
            try startEngine()
        } catch {
            dbg("handsfree: engine rebuild failed — \(error)")
            stop()
            onUnavailable?("Microphone unavailable")
            return
        }
        startTask()
    }

    private static func currentInputDevice() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr ? device : 0
    }
}
