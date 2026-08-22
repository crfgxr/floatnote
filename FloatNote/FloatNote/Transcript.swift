import AppKit
import SwiftUI

/// Reads the conversation Claude Code is already writing to disk and renders it
/// as typeset prose beside the terminal that produced it.
///
/// A terminal draws its UI by counting columns, so a proportional serif at 1.6
/// leading is structurally impossible there — the boxes, tables and the input
/// frame all assume `advance(ch) == advance(' ')`. The conversation, however, is
/// on disk in a structured form: `~/.claude/projects/<munged-cwd>/<sessionId>.jsonl`.
/// Read it, typeset it, leave the terminal to do what only it can.
///
/// Spec: `docs/superpowers/specs/2026-08-22-transcript-pane-design.md`.

/// "Working…" while Claude is mid-turn — the pane's answer to Claude Desktop's
/// thinking indicator. Pinned to the bottom of the measure rather than appended
/// to the document: an attributed run would have to be added and removed from
/// the text storage on every turn, and it would scroll out of sight.
struct TranscriptWorkingIndicator: View {
    let style: TranscriptStyle
    @State private var spin = false
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "asterisk")
                .font(.system(size: 10, weight: .bold))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .opacity(pulse ? 1 : 0.45)
            Text("Working…")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.5)
        }
        .foregroundColor(Color(nsColor: style.muted))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color(nsColor: style.background).opacity(0.94))
                .overlay(Capsule().stroke(Color(nsColor: style.rule), lineWidth: 1))
        )
        .onAppear {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// MARK: - Model

/// One speaker's contribution, already grouped out of the JSONL's exploded
/// per-block records.
struct TranscriptTurn: Identifiable, Equatable {
    enum Kind: Equatable {
        case claude
        case user
        /// `/compact` boundary — rendered as a labelled rule, not as speech.
        case compaction(String)
        /// The machine-written continuation text after a compaction.
        case summary
        /// A collapsed `Read · Terminal.swift` line (only when enabled).
        case toolCall(String)
        /// A new `claude` run started in this pane.
        case sessionBreak
    }

    let id: String
    let kind: Kind
    /// Markdown, as Claude wrote it. Empty for rule-like kinds.
    let text: String
    let timestamp: Date?

    static func == (a: TranscriptTurn, b: TranscriptTurn) -> Bool {
        a.id == b.id && a.text.count == b.text.count && a.kind == b.kind
    }
}

// MARK: - Ingest

/// Parses Claude Code's session JSONL into `TranscriptTurn`s.
///
/// Two structural rules a naive reader gets wrong, both measured on this Mac:
/// assistant records carry exactly ONE content block (one API turn explodes into
/// up to six consecutive lines — regroup by `requestId`), and 12 of the 20
/// top-level record types are mutable session-state churn with no message at all.
/// Filter first, then do anything else.
enum TranscriptParser {

    /// Feed complete JSONL lines; get back turns to append. `pending` carries the
    /// group being assembled across calls so a turn split across two reads isn't
    /// emitted twice.
    struct State {
        /// requestId of the assistant group currently being accumulated.
        var groupKey: String?
        var groupText: String = ""
        var groupTime: Date?
        var skipped: [String: Int] = [:]
    }

    static func parse(lines: [String], state: inout State, showToolCalls: Bool) -> [TranscriptTurn] {
        var out: [TranscriptTurn] = []

        func flushGroup() {
            guard let key = state.groupKey else { return }
            let text = state.groupText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                out.append(TranscriptTurn(id: key, kind: .claude, text: text, timestamp: state.groupTime))
            }
            state.groupKey = nil
            state.groupText = ""
            state.groupTime = nil
        }

        for line in lines {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                state.skipped["malformed", default: 0] += 1
                continue
            }
            // Sidechains live only under <sessionId>/subagents/**, but guard anyway.
            if obj["isSidechain"] as? Bool == true { state.skipped["sidechain", default: 0] += 1; continue }
            let type = obj["type"] as? String ?? ""
            let time = (obj["timestamp"] as? String).flatMap(Self.isoFormatter.date(from:))

            switch type {
            case "assistant":
                let message = obj["message"] as? [String: Any]
                let key = (obj["requestId"] as? String) ?? (message?["id"] as? String) ?? UUID().uuidString
                if state.groupKey != key { flushGroup(); state.groupKey = key; state.groupTime = time }
                for block in (message?["content"] as? [[String: Any]] ?? []) {
                    switch block["type"] as? String {
                    case "text":
                        let text = block["text"] as? String ?? ""
                        if !text.isEmpty {
                            if !state.groupText.isEmpty { state.groupText += "\n\n" }
                            state.groupText += text
                        }
                    case "tool_use":
                        // Structure, not prose. Only surfaced when asked for, and
                        // then only as one line.
                        guard showToolCalls else { break }
                        flushGroup()
                        out.append(TranscriptTurn(id: (block["id"] as? String) ?? UUID().uuidString,
                                                  kind: .toolCall(Self.toolLabel(block)),
                                                  text: "", timestamp: time))
                    default:
                        // "thinking" is always an empty string with an opaque
                        // signature — 6211 of 6211 on this machine. Nothing to render.
                        break
                    }
                }

            case "user":
                flushGroup()
                // 814 of 1061 `user` records in this project are tool results
                // wearing the user role, plus system injections marked isMeta.
                if obj["toolUseResult"] != nil || obj["sourceToolAssistantUUID"] != nil {
                    state.skipped["tool_result", default: 0] += 1; continue
                }
                if obj["isMeta"] as? Bool == true { state.skipped["meta", default: 0] += 1; continue }
                let text = Self.userText(obj)
                guard !text.isEmpty else { state.skipped["empty_user", default: 0] += 1; continue }
                // Harness injections wear the user role too: task notifications,
                // system reminders, slash-command echoes. A person did not say them.
                guard !Self.isInjection(text) else { state.skipped["injection", default: 0] += 1; continue }
                let isSummary = obj["isCompactSummary"] as? Bool == true
                out.append(TranscriptTurn(id: (obj["uuid"] as? String) ?? UUID().uuidString,
                                          kind: isSummary ? .summary : .user,
                                          text: text, timestamp: time))

            case "system":
                flushGroup()
                guard obj["subtype"] as? String == "compact_boundary" else {
                    state.skipped["system", default: 0] += 1; continue
                }
                let dropped = ((obj["compactMetadata"] as? [String: Any])?["preTokens"] as? Int)
                    ?? (obj["preTokens"] as? Int)
                let label = dropped.map { "Conversation compacted · \(Self.grouped($0)) tokens dropped" }
                    ?? "Conversation compacted"
                out.append(TranscriptTurn(id: (obj["uuid"] as? String) ?? UUID().uuidString,
                                          kind: .compaction(label), text: "", timestamp: time))

            default:
                // Allow-list, not a deny-list: a new record type in a future
                // Claude Code version degrades to invisible, never to garbage.
                state.skipped[type.isEmpty ? "untyped" : type, default: 0] += 1
            }
        }
        // The group stays open on purpose — the next read may continue it.
        if state.groupKey != nil && lines.count > 1 { }
        return out
    }

    /// Close any open assistant group (called when a read settles).
    static func finish(state: inout State) -> [TranscriptTurn] {
        guard let key = state.groupKey else { return [] }
        let text = state.groupText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.groupKey = nil; state.groupText = ""; let time = state.groupTime; state.groupTime = nil
        guard !text.isEmpty else { return [] }
        return [TranscriptTurn(id: key, kind: .claude, text: text, timestamp: time)]
    }

    /// A human message is either a plain string or an array of content blocks;
    /// base64 image payloads are dropped here and never enter the model.
    private static func userText(_ obj: [String: Any]) -> String {
        guard let message = obj["message"] as? [String: Any] else { return "" }
        if let text = message["content"] as? String { return clean(text) }
        var parts: [String] = []
        var images = 0
        for block in (message["content"] as? [[String: Any]] ?? []) {
            switch block["type"] as? String {
            case "text":
                let text = clean(block["text"] as? String ?? "")
                if !text.isEmpty { parts.append(text) }
            case "image":
                images += 1
            default:
                break
            }
        }
        // Claude Code already writes its own "[Image #3]" marker into the text,
        // so only stand in for an image when nothing else survived.
        if parts.isEmpty && images > 0 { parts.append(images == 1 ? "[image]" : "[\(images) images]") }
        return parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip the harness's own bracketed blocks out of an otherwise real message.
    private static func clean(_ text: String) -> String {
        var out = text
        for tag in ["system-reminder", "local-command-stdout", "command-message", "command-args"] {
            out = out.replacingOccurrences(
                of: "<\(tag)>[\\s\\S]*?</\(tag)>", with: "", options: .regularExpression)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whole messages that are machinery, not speech.
    private static func isInjection(_ text: String) -> Bool {
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)
        for tag in ["<task-notification", "<system-reminder", "<command-name", "<local-command",
                    "<user-prompt-submit-hook", "Caveat: The messages below"] where head.hasPrefix(tag) {
            return true
        }
        return false
    }

    private static func toolLabel(_ block: [String: Any]) -> String {
        let name = block["name"] as? String ?? "tool"
        let input = block["input"] as? [String: Any] ?? [:]
        let detail = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
            ?? (input["pattern"] as? String)
            ?? (input["command"] as? String).map { String($0.prefix(48)) }
            ?? (input["description"] as? String)
        return detail.map { "\(name) · \($0)" } ?? name
    }

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Session resolution

/// Finds the `.jsonl` a terminal pane is talking to. `TerminalTab.path` does not
/// identify a conversation: this project's store already holds 16 files, 10 of
/// them written by SDK runs (security-review, code-review) interleaved with the
/// live CLI session, and `addTerminal()` deliberately starts another.
enum TranscriptResolver {
    struct Resolution: Equatable {
        let path: String
        /// False only for the two guessing steps at the bottom of the ladder —
        /// shown as a "best guess" chip.
        let authoritative: Bool
    }

    /// `~/.claude/projects/<munged-cwd>`, where every session for a directory lives.
    static func storeDir(for cwd: String) -> String {
        NSHomeDirectory() + "/.claude/projects/"
            + TerminalSession.mungedClaudeProjectDirName(for: cwd)
    }

    /// - Parameters:
    ///   - claimed: paths another pane is already showing. A guess never lands
    ///     on one, so two panes on one project can't mirror each other.
    ///   - sticky: what this pane resolved to last time. Preferred over any
    ///     guess: a transcript that silently jumps to a different conversation
    ///     because some other session's mtime moved is worse than a stale one.
    static func resolve(for tab: TerminalTab, claimed: Set<String> = [],
                        sticky: Resolution? = nil) -> Resolution? {
        // 1. The hook told us. Claude Code named the session itself.
        if let path = tab.claudeTranscriptPath, FileManager.default.fileExists(atPath: path) {
            return Resolution(path: path, authoritative: true)
        }
        let home = NSHomeDirectory()
        let store = storeDir(for: tab.path)
        if let sid = tab.claudeSessionId {
            let path = store + "/" + sid + ".jsonl"
            if FileManager.default.fileExists(atPath: path) {
                return Resolution(path: path, authoritative: true)
            }
        }
        // 2. Whatever this pane already resolved to, as long as it still exists.
        //    Stability beats freshness — see `sticky` above.
        if let sticky, FileManager.default.fileExists(atPath: sticky.path) { return sticky }
        // 3. ~/.claude.json remembers the last session per cwd. Correct for the
        //    directory, ambiguous when two panes share it.
        if let data = FileManager.default.contents(atPath: home + "/.claude.json"),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let projects = root["projects"] as? [String: Any],
           let entry = projects[tab.path] as? [String: Any],
           let sid = entry["lastSessionId"] as? String {
            let path = store + "/" + sid + ".jsonl"
            if FileManager.default.fileExists(atPath: path), !claimed.contains(path) {
                return Resolution(path: path, authoritative: false)
            }
        }
        // 4. Newest CLI-written file in the store. SDK sessions (code-review,
        //    security-review) live in the same directory and must not be adopted.
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: store))?.filter { $0.hasSuffix(".jsonl") } ?? []
        let dated: [(String, Date)] = files.compactMap { name in
            let path = store + "/" + name
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let date = attrs[.modificationDate] as? Date else { return nil }
            return (path, date)
        }.sorted { $0.1 > $1.1 }
        for (path, _) in dated where !claimed.contains(path) && isCLISession(path) {
            return Resolution(path: path, authoritative: false)
        }
        return nil
    }

    /// The session file the pane's own `claude` is holding open, found by asking
    /// `lsof` about the shell and its descendants.
    ///
    /// This is the step that removes the guessing: `cwd` names a directory,
    /// `~/.claude.json` names the directory's *last* session, but an open file
    /// descriptor names the conversation THIS pane is running — so two panes on
    /// one project resolve to their own files, with no hook installed and no
    /// waiting for the first turn to end. Measured at 16ms; the caller still
    /// runs it off the main thread.
    static func openTranscript(shellPid: pid_t, storeDir: String) -> String? {
        guard shellPid > 0 else { return nil }
        let pids = ([shellPid] + descendants(of: shellPid)).map(String.init).joined(separator: ",")
        guard let out = run("/usr/sbin/lsof", ["-Fn", "-p", pids]) else { return nil }
        let fm = FileManager.default
        var best: (String, Date)?
        for line in out.split(separator: "\n") where line.hasPrefix("n") {
            let path = String(line.dropFirst())
            guard path.hasPrefix(storeDir), path.hasSuffix(".jsonl"),
                  let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            else { continue }
            if best == nil || date > best!.1 { best = (path, date) }
        }
        return best?.0
    }

    /// Every process under `pid`, transitively. `claude` is a child of the
    /// pane's shell, and a `!` shell-out or an MCP server adds another level.
    private static func descendants(of pid: pid_t) -> [pid_t] {
        guard let out = run("/bin/ps", ["-axo", "pid=,ppid="]) else { return [] }
        var children: [pid_t: [pid_t]] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let child = pid_t(parts[0]), let parent = pid_t(parts[1])
            else { continue }
            children[parent, default: []].append(child)
        }
        var found: [pid_t] = []
        var queue = children[pid] ?? []
        while let next = queue.popLast(), found.count < 200 {
            found.append(next)
            queue.append(contentsOf: children[next] ?? [])
        }
        return found
    }

    private static func run(_ launchPath: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Reads the head of a file to check `entrypoint`, without loading it.
    private static func isCLISession(_ path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64_000), let head = String(data: data, encoding: .utf8)
        else { return false }
        for line in head.split(separator: "\n").prefix(20) {
            guard let d = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let entry = obj["entrypoint"] as? String else { continue }
            return entry == "cli"
        }
        // No entrypoint recorded at all: assume CLI rather than show nothing.
        return true
    }
}

// MARK: - Tail

/// Watches one append-only JSONL and hands complete lines to a callback.
///
/// Offset tailing is safe here because the files are provably append-only (a live
/// file's byte prefix stayed bit-identical as it tripled in size). Everything
/// after the last `\n` is buffered and never parsed — the largest single line in
/// this project's store is 839 KB, so any read triggered mid-append lands inside
/// a line.
final class TranscriptTail {
    private let queue = DispatchQueue(label: "com.floatnote.transcript.tail")
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var offset: UInt64 = 0
    private var partial = Data()
    private let path: String
    private let onLines: ([String], Bool) -> Void

    /// Cold open reads a window, not the file: the largest transcript on this
    /// Mac is 111 MB.
    static let coldOpenWindow: UInt64 = 2 * 1024 * 1024

    /// `onLines(lines, isReset)` is called on a private queue.
    init(path: String, onLines: @escaping ([String], Bool) -> Void) {
        self.path = path
        self.onLines = onLines
        queue.async { [weak self] in self?.start() }
    }

    deinit { stop() }

    func stop() {
        queue.sync {
            source?.cancel()
            source = nil
        }
    }

    private func start() {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            dbg("transcript: cannot open \(path)")
            return
        }
        let size = (try? handle.seekToEnd()) ?? 0
        // Seek back a window and discard to the first newline, so the first line
        // parsed is a whole one.
        offset = size > Self.coldOpenWindow ? size - Self.coldOpenWindow : 0
        try? handle.seek(toOffset: offset)
        var data = (try? handle.readToEnd()) ?? Data()
        if offset > 0, let nl = data.firstIndex(of: 0x0A) {
            data = data.suffix(from: data.index(after: nl))
        }
        offset = size
        try? handle.close()
        emit(data, isReset: true)
        watch()
        dbg("transcript: tail started \(path) from \(offset) bytes")
    }

    private func watch() {
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else { dbg("transcript: cannot watch \(path)"); return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .link], queue: queue)
        src.setEventHandler { [weak self] in self?.drain(src.data) }
        src.setCancelHandler { [fd = self.fd] in if fd >= 0 { close(fd) } }
        src.resume()
        source = src
    }

    /// Also driven by the app's 2s timer, as a safety net for a watcher that
    /// missed an event (the same pairing `startClaudeEventWatcher` uses).
    func poll() { queue.async { [weak self] in self?.drain([]) } }

    private func drain(_ mask: DispatchSource.FileSystemEvent) {
        if mask.contains(.delete) || mask.contains(.rename) {
            // Claude Code has explicit transcript-path recovery; re-open by path.
            source?.cancel(); source = nil
            offset = 0; partial.removeAll()
            start()
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset {
            // Truncated or replaced: start over rather than read garbage.
            dbg("transcript: file shrank (\(size) < \(offset)) — re-ingesting")
            offset = 0; partial.removeAll()
            try? handle.seek(toOffset: 0)
            let data = (try? handle.readToEnd()) ?? Data()
            offset = size
            emit(data, isReset: true)
            return
        }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset = size
        emit(data, isReset: false)
    }

    private func emit(_ chunk: Data, isReset: Bool) {
        var data = partial + chunk
        partial.removeAll()
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            partial = data
            return
        }
        let complete = data[data.startIndex...lastNewline]
        partial = Data(data[data.index(after: lastNewline)...])
        data = Data()
        let lines = String(decoding: complete, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard !lines.isEmpty else { return }
        onLines(lines, isReset)
    }
}

// MARK: - Store

/// Owns the active pane's transcript: resolution, tailing, the render model.
///
/// Only the ACTIVE pane tails. Background panes keep their binding (it lives on
/// `TerminalTab`) but hold no file descriptor — a project store holds 16+ files
/// and there can be N panes, so anything sweeping directories per tick is a
/// main-thread tax for nothing.
@MainActor
final class TranscriptStore: ObservableObject {
    static let shared = TranscriptStore()

    @Published private(set) var turns: [TranscriptTurn] = []
    @Published private(set) var isAuthoritative = true
    @Published private(set) var resolvedPath: String?
    @Published private(set) var paneLabel: String = ""
    /// Bumped whenever `turns` changes, so the view can append rather than rebuild.
    @Published private(set) var generation = 0
    /// True while Claude looks mid-turn in the bound pane: a fresh user message
    /// landed and neither hook (Stop, or Notification = waiting on the human)
    /// has said the turn is over. The JSONL has no "turn started" record, so a
    /// recent `.user` turn IS the start signal.
    @Published private(set) var isWorking = false

    /// Mirrors the terminal's scrollback decision rather than holding the file.
    private let maxTurns = 400

    private var tail: TranscriptTail?
    private(set) var boundPaneId: UUID?
    /// The pane itself, kept so a provisional resolution can be upgraded later
    /// without waiting for a navigation to re-bind.
    private var boundTab: TerminalTab?
    /// paneId → the file that pane is showing. Two jobs: a pane never re-guesses
    /// (its transcript can't jump to another conversation when some other
    /// session's mtime moves), and no two panes are ever pointed at one file.
    private var claims: [UUID: TranscriptResolver.Resolution] = [:]
    /// Rate-limits the `lsof` retry for a pane still on a guess.
    private var lastOpenFileProbe = Date.distantPast
    /// Last time the session file grew — the spinner's dead-man switch, for a
    /// pane whose Claude has no hook installed.
    private var lastRecordAt = Date.distantPast
    /// A user message older than this was already answered; a turn quieter than
    /// this has almost certainly ended without its hook reaching us.
    private static let turnStartWindow: TimeInterval = 180
    private static let workingCap: TimeInterval = 600
    private var parseState = TranscriptParser.State()
    private var showToolCalls: Bool {
        UserDefaults.standard.bool(forKey: "fn.transcriptShowToolCalls")
    }

    private init() {}

    /// Point the store at a pane. Cheap and idempotent — the same pane twice is
    /// a no-op, so this can be called from every navigation path.
    func bind(to tab: TerminalTab?) {
        guard let tab else { unbind(); return }
        guard boundPaneId != tab.id else { return }
        rebind(to: tab)
    }

    /// Re-resolve and restart, even for the pane already bound (the hook just
    /// upgraded a provisional binding to an authoritative one).
    func rebind(to tab: TerminalTab) {
        boundPaneId = tab.id
        boundTab = tab
        paneLabel = tab.label

        let claimed = Set(claims.filter { $0.key != tab.id }.values.map(\.path))
        let sticky = claims[tab.id]
        guard let resolution = TranscriptResolver.resolve(for: tab, claimed: claimed, sticky: sticky) else {
            stopTail()
            resolvedPath = nil
            isAuthoritative = true
            dbg("transcript: no session file for pane \(tab.label)")
            probeOpenFiles(for: tab)
            return
        }
        claims[tab.id] = resolution
        start(resolution, label: tab.label, reason: resolution.authoritative ? "authoritative" : "best guess")
        // A guess is only ever provisional: ask the pane's own process which file
        // it has open and upgrade in place when it answers.
        if !resolution.authoritative { probeOpenFiles(for: tab) }
    }

    /// Point the tail at `resolution`, discarding whatever was parsed before.
    private func start(_ resolution: TranscriptResolver.Resolution, label: String, reason: String) {
        tail?.stop()
        tail = nil
        turns = []
        parseState = TranscriptParser.State()
        isWorking = false
        lastRecordAt = Date()
        generation &+= 1
        resolvedPath = resolution.path
        isAuthoritative = resolution.authoritative
        dbg("transcript: pane \(label) → \((resolution.path as NSString).lastPathComponent) (\(reason))")

        let showTools = showToolCalls
        tail = TranscriptTail(path: resolution.path) { [weak self] lines, isReset in
            // Parse off the main actor; hop back with finished turns only.
            var state = TranscriptParser.State()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isReset { self.turns = []; self.parseState = TranscriptParser.State() }
                state = self.parseState
                var new = TranscriptParser.parse(lines: lines, state: &state, showToolCalls: showTools)
                new += TranscriptParser.finish(state: &state)
                self.parseState = state
                self.append(new)
            }
        }
    }

    private func stopTail() {
        tail?.stop()
        tail = nil
        turns = []
        parseState = TranscriptParser.State()
        isWorking = false
        generation &+= 1
    }

    /// Ask `lsof` which session file this pane's `claude` is holding open, off
    /// the main thread, and adopt the answer if the pane is still bound. This is
    /// what makes the binding stable without a hook event: the fd is the truth.
    private func probeOpenFiles(for tab: TerminalTab) {
        guard let pid = TerminalSessions.shared.existing(tab.id)?.view.process.shellPid, pid > 0
        else { return }
        lastOpenFileProbe = Date()
        let store = TranscriptResolver.storeDir(for: tab.path)
        let paneId = tab.id, label = tab.label
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let path = TranscriptResolver.openTranscript(shellPid: pid, storeDir: store) else { return }
            DispatchQueue.main.async {
                guard let self, self.boundPaneId == paneId else { return }
                // Someone else's file: another pane already showing it wins, and
                // a re-probe of the same path only needs the label upgraded.
                if self.claims.contains(where: { $0.key != paneId && $0.value.path == path }) { return }
                let resolution = TranscriptResolver.Resolution(path: path, authoritative: true)
                self.claims[paneId] = resolution
                guard self.resolvedPath != path else { self.isAuthoritative = true; return }
                self.start(resolution, label: label, reason: "open fd")
            }
        }
    }

    func unbind() {
        stopTail()
        boundPaneId = nil
        boundTab = nil
        resolvedPath = nil
    }

    /// Safety net on the app's existing 2s timer, for a watcher that missed.
    func poll() {
        tail?.poll()
        if isWorking, Date().timeIntervalSince(lastRecordAt) > Self.workingCap { isWorking = false }
        // A pane whose Claude started after the bind (or hadn't started at all)
        // is still on a guess. Re-probe until the fd answers, then stop.
        if !isAuthoritative, let tab = boundTab,
           Date().timeIntervalSince(lastOpenFileProbe) > 5 {
            probeOpenFiles(for: tab)
        }
    }

    /// The hook reported this pane's turn over — `Stop`, or `Notification`
    /// (Claude is waiting on the human, which is not working either). Only the
    /// bound pane's events touch the spinner.
    func noteTurnEnded(paneId: UUID) {
        guard paneId == boundPaneId, isWorking else { return }
        isWorking = false
    }

    private func append(_ new: [TranscriptTurn]) {
        guard !new.isEmpty else { return }
        var merged = turns
        for turn in new {
            // A group can be re-emitted as it grows (more blocks land in the same
            // requestId); replace in place rather than duplicating the turn.
            if let idx = merged.lastIndex(where: { $0.id == turn.id }) {
                merged[idx] = turn
            } else {
                merged.append(turn)
            }
        }
        if merged.count > maxTurns { merged.removeFirst(merged.count - maxTurns) }
        turns = merged
        generation &+= 1
        lastRecordAt = Date()
        // A user message that just landed means Claude is off working. The
        // timestamp gate keeps the initial full-file read (whose last turn is
        // often a long-answered prompt) from lighting the spinner.
        if let started = new.last(where: { $0.kind == .user }),
           abs((started.timestamp ?? Date()).timeIntervalSinceNow) < Self.turnStartWindow {
            isWorking = true
        }
    }
}

// MARK: - Style

/// Resolved typography and colour. Every metric here was measured on a real
/// `NSLayoutManager`; see the spec's "four lines that make the scale behave".
struct TranscriptStyle {
    let body: NSFont
    let bodySmall: NSFont
    let h1: NSFont
    let h2: NSFont
    let h3: NSFont
    let inlineCode: NSFont
    let codeBlock: NSFont
    let meta: NSFont

    let lineHeight: CGFloat
    let baselineOffset: CGFloat

    let background: NSColor
    let text: NSColor
    let muted: NSColor
    let rule: NSColor
    let inlineCodeText: NSColor
    let inlineCodeChip: NSColor
    let codeBackground: NSColor
    let codeBorder: NSColor
    let blockquoteBar: NSColor
    let link: NSColor
    let bubbleBackground: NSColor
    let bubbleBorder: NSColor

    static let familyKey = "fn.transcriptFontFamily"
    static let sizeKey = "fn.transcriptFontSize"

    static var selectedFamily: String {
        UserDefaults.standard.string(forKey: familyKey) ?? "Charter"
    }
    static var selectedSize: CGFloat {
        let stored = UserDefaults.standard.double(forKey: sizeKey)
        return stored > 0 ? CGFloat(stored) : 16
    }

    /// Reading faces, best first. Availability is tested by RESOLUTION, never by
    /// enumeration: five of sixteen probed serif faces (New York, Iowan Old
    /// Style, Athelas, Seravek, Superclarendon) are absent from
    /// `availableFontFamilies` yet resolve perfectly via `NSFont(name:)`.
    static let readingFaces: [(String, String)] = [
        ("Charter", "Charter-Roman"),
        ("Iowan Old Style", "IowanOldStyle-Roman"),
        ("Palatino", "Palatino-Roman"),
        ("Georgia", "Georgia"),
    ]

    static func availableReadingFaces() -> [(String, String)] {
        readingFaces.filter { NSFont(name: $0.1, size: 16) != nil }
    }

    static func resolve(isDark: Bool) -> TranscriptStyle {
        let size = selectedSize
        let family = selectedFamily
        let postscript = readingFaces.first { $0.0 == family }?.1 ?? family
        // Charter → New York → PT Serif → the system serif design.
        let body = NSFont(name: postscript, size: size)
            ?? NSFont(name: "Charter-Roman", size: size)
            ?? NSFont(name: "PTSerif-Regular", size: size)
            ?? NSFont(descriptor: NSFont.systemFont(ofSize: size).fontDescriptor
                        .withDesign(.serif) ?? NSFont.systemFont(ofSize: size).fontDescriptor,
                      size: size)
            ?? NSFont.systemFont(ofSize: size)
        let small = NSFont(name: body.fontName, size: size - 1) ?? body
        // The scale derives from the body size, so a size change moves everything.
        let scale = size / 16
        func sf(_ points: CGFloat, _ weight: NSFont.Weight) -> NSFont {
            NSFont.systemFont(ofSize: (points * scale).rounded(), weight: weight)
        }
        return TranscriptStyle(
            body: body,
            bodySmall: small,
            h1: sf(24, .bold),
            h2: sf(19, .semibold),
            h3: sf(16, .semibold),
            // 14.5 puts SF Mono's x-height within 0.106pt of Charter 16, so an
            // inline chip sits in the serif line without shifting it.
            inlineCode: NSFont.monospacedSystemFont(ofSize: (14.5 * scale).rounded(), weight: .regular),
            // Matched to the terminal's own 13 medium, so code reads identically
            // in both surfaces of the panel.
            codeBlock: NSFont.monospacedSystemFont(ofSize: (13 * scale).rounded(), weight: .medium),
            meta: sf(11, .semibold),
            lineHeight: (size * 1.625).rounded(),
            baselineOffset: ((size * 1.625).rounded() - size * 1.25) / 2,
            background: hex(isDark ? 0x26_26_24 : 0xFA_F9_F5),
            text: hex(isDark ? 0xF5_F4_EF : 0x1F_1E_1D),
            muted: hex(isDark ? 0x9F_9D_97 : 0x6D_6A_64),
            rule: hex(isDark ? 0x3A_3A_37 : 0xE7_E2_D6),
            inlineCodeText: hex(isDark ? 0xE9_A1_83 : 0x8A_3D_2A),
            inlineCodeChip: hex(isDark ? 0x35_34_2F : 0xEF_EB_DF),
            codeBackground: hex(isDark ? 0x2E_2E_2B : 0xF3_F0_E7),
            codeBorder: hex(isDark ? 0x3C_3B_37 : 0xE4_DF_D2),
            blockquoteBar: hex(isDark ? 0x4A_49_44 : 0xD8_D2_C2),
            // NOT the coral accent: #D97757 measures 2.96:1 on #FAF9F5 and fails
            // AA outright. It stays the caret colour.
            link: hex(isDark ? 0xE0_96_7D : 0x98_57_42),
            bubbleBackground: hex(isDark ? 0x32_32_30 : 0xEF_EB_E1),
            bubbleBorder: hex(isDark ? 0x3E_3D_39 : 0xE2_DC_CC))
    }

    private static func hex(_ value: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255,
                green: CGFloat(value >> 8 & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Markdown

extension NSAttributedString.Key {
    /// Runs the layout manager paints a rounded chip behind (inline code).
    static let transcriptChip = NSAttributedString.Key("fnTranscriptChip")
    /// Paragraphs painted as a fenced code block (background + border).
    static let transcriptCodeBlock = NSAttributedString.Key("fnTranscriptCodeBlock")
    /// Paragraphs given a blockquote bar.
    static let transcriptQuote = NSAttributedString.Key("fnTranscriptQuote")
    /// A thematic break — drawn as a hairline across the measure.
    static let transcriptRule = NSAttributedString.Key("fnTranscriptRule")
    /// The user's own message, painted as a right-aligned bubble.
    static let transcriptBubble = NSAttributedString.Key("fnTranscriptBubble")
}

/// Markdown → `NSAttributedString`, in two passes: a line-oriented block scanner,
/// then an inline pass per block.
///
/// Foundation's parser is not used at all: `AttributedString(markdown:)` is
/// CommonMark-only (no tables, no strikethrough, no task lists) and `Text`
/// ignores the `PresentationIntent` it produces, so headings and code fences come
/// back as runs nothing will lay out.
enum TranscriptMarkdown {

    static func render(_ markdown: String, style: TranscriptStyle,
                       bubble: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")[...]
        var listIndex = 0

        func appendBlock(_ block: NSAttributedString) {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(block)
        }

        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code — take everything to the closing fence verbatim.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                var body: [String] = []
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    body.append(next)
                }
                appendBlock(codeBlock(body.joined(separator: "\n"), style: style))
                listIndex = 0
                continue
            }

            if trimmed.isEmpty { listIndex = 0; continue }

            // Thematic break.
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
                appendBlock(rule(style: style))
                continue
            }

            // ATX headings; #### and deeper clamp to H3.
            if let hashes = trimmed.prefix(while: { $0 == "#" }).count as Int?, hashes > 0, hashes <= 6,
               trimmed.dropFirst(hashes).first == " " {
                let text = String(trimmed.dropFirst(hashes + 1))
                appendBlock(heading(text, level: min(hashes, 3), style: style))
                listIndex = 0
                continue
            }

            // Blockquote — one level, consecutive lines merge into one block.
            if trimmed.hasPrefix(">") {
                var quoted = [String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    lines = lines.dropFirst()
                    quoted.append(String(next.trimmingCharacters(in: .whitespaces).dropFirst())
                        .trimmingCharacters(in: .whitespaces))
                }
                appendBlock(blockquote(quoted.joined(separator: " "), style: style))
                continue
            }

            // GFM table — a real `NSTextTable`, so prose cells wrap inside their
            // column instead of being chopped by a monospaced measure. The
            // delimiter row is consumed here, not rendered.
            if trimmed.hasPrefix("|"), let next = lines.first, isDelimiterRow(next) {
                lines = lines.dropFirst()
                let alignments = alignments(of: next)
                var rows = [tableCells(line)]
                while let row = lines.first, row.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    lines = lines.dropFirst()
                    rows.append(tableCells(row))
                }
                appendBlock(table(rows, alignments: alignments, style: style))
                listIndex = 0
                continue
            }

            // Lists (one nesting level), including task lists.
            if let item = listItem(line) {
                let marker: String
                if item.ordered { listIndex += 1; marker = "\(listIndex). " } else { listIndex = 0; marker = "•\t" }
                appendBlock(listLine(item, marker: marker, style: style, bubble: bubble))
                continue
            }

            // Paragraph — consecutive non-blank lines join with a space, the way
            // markdown means them, not the way they are wrapped on disk.
            var para = [line]
            while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).isEmpty,
                  listItem(next) == nil,
                  !next.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                  !next.trimmingCharacters(in: .whitespaces).hasPrefix(">"),
                  !next.trimmingCharacters(in: .whitespaces).hasPrefix("```"),
                  !next.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                lines = lines.dropFirst()
                para.append(next)
            }
            appendBlock(paragraph(para.joined(separator: " "), style: style, bubble: bubble))
            listIndex = 0
        }
        return out
    }

    // MARK: Blocks

    private struct ListItem {
        let text: String
        let ordered: Bool
        let indent: Int
        let checkbox: Bool?
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var rest: String
        var ordered = false
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
            rest = String(trimmed.dropFirst(2))
        } else if let dot = trimmed.firstIndex(of: "."),
                  trimmed[trimmed.startIndex..<dot].allSatisfy(\.isNumber),
                  trimmed.index(after: dot) < trimmed.endIndex,
                  trimmed[trimmed.index(after: dot)] == " " {
            rest = String(trimmed[trimmed.index(dot, offsetBy: 2)...])
            ordered = true
        } else {
            return nil
        }
        var checkbox: Bool? = nil
        if rest.hasPrefix("[ ] ") { checkbox = false; rest = String(rest.dropFirst(4)) }
        else if rest.lowercased().hasPrefix("[x] ") { checkbox = true; rest = String(rest.dropFirst(4)) }
        return ListItem(text: rest, ordered: ordered, indent: indent, checkbox: checkbox)
    }

    private static func paragraph(_ text: String, style: TranscriptStyle,
                                  bubble: Bool) -> NSAttributedString {
        let attributed = inline(text, style: style, font: bubble ? style.bodySmall : style.body)
        let ps = bodyParagraph(style)
        attributed.addAttributes([.paragraphStyle: ps], range: NSRange(location: 0, length: attributed.length))
        return attributed
    }

    private static func heading(_ text: String, level: Int,
                                style: TranscriptStyle) -> NSAttributedString {
        let font = level == 1 ? style.h1 : (level == 2 ? style.h2 : style.h3)
        let attributed = inline(text, style: style, font: font)
        let ps = NSMutableParagraphStyle()
        let height = font.pointSize * 1.25
        ps.minimumLineHeight = height
        ps.maximumLineHeight = height
        ps.paragraphSpacingBefore = level == 1 ? 28 : (level == 2 ? 24 : 18)
        ps.paragraphSpacing = level == 1 ? 10 : (level == 2 ? 8 : 6)
        attributed.addAttributes([.paragraphStyle: ps, .foregroundColor: style.text],
                                 range: NSRange(location: 0, length: attributed.length))
        return attributed
    }

    private static func listLine(_ item: ListItem, marker: String, style: TranscriptStyle,
                                 bubble: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = bubble ? style.bodySmall : style.body
        if let checked = item.checkbox {
            // Reuse the app's own glyph substitution so ☐ and ☑ share corners.
            let glyph = NSMutableAttributedString(string: checked ? "☑\t" : "☐\t")
            glyph.addAttributes([.font: font, .foregroundColor: style.text],
                                range: NSRange(location: 0, length: glyph.length))
            out.append(glyph)
        } else {
            out.append(NSAttributedString(string: marker, attributes: [
                .font: font, .foregroundColor: style.muted,
                .baselineOffset: style.baselineOffset,
            ]))
        }
        out.append(inline(item.text, style: style, font: font))
        let ps = bodyParagraph(style)
        let indent: CGFloat = item.indent >= 2 ? 36 : 18
        ps.headIndent = indent
        ps.firstLineHeadIndent = indent - 18
        ps.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        ps.paragraphSpacing = 6
        out.addAttributes([.paragraphStyle: ps], range: NSRange(location: 0, length: out.length))
        return out
    }

    private static func blockquote(_ text: String, style: TranscriptStyle) -> NSAttributedString {
        let attributed = inline(text, style: style, font: style.bodySmall)
        let ps = bodyParagraph(style)
        ps.headIndent = 16
        ps.firstLineHeadIndent = 16
        ps.paragraphSpacingBefore = 12
        ps.paragraphSpacing = 12
        attributed.addAttributes([
            .paragraphStyle: ps,
            .foregroundColor: style.muted,
            .transcriptQuote: true,
        ], range: NSRange(location: 0, length: attributed.length))
        return attributed
    }

    private static func codeBlock(_ code: String, style: TranscriptStyle) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        let height = style.codeBlock.pointSize * 1.45
        ps.minimumLineHeight = height
        ps.maximumLineHeight = height
        ps.headIndent = 14
        ps.firstLineHeadIndent = 14
        ps.tailIndent = -14
        ps.paragraphSpacingBefore = 10
        ps.paragraphSpacing = 10
        ps.lineBreakMode = .byCharWrapping
        return NSAttributedString(string: code, attributes: [
            .font: style.codeBlock,
            .foregroundColor: style.text,
            .paragraphStyle: ps,
            .transcriptCodeBlock: true,
        ])
    }

    /// `|---|:--:|---:|` — the row that makes the one above it a header.
    private static func isDelimiterRow(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    private static func alignments(of delimiter: String) -> [NSTextAlignment] {
        tableCells(delimiter).map { cell in
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            if left && right { return .center }
            return right ? .right : .left
        }
    }

    /// Split a row on unescaped pipes, dropping the leading and trailing ones.
    private static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        let sentinel = "\u{0}"
        return trimmed.replacingOccurrences(of: "\\|", with: sentinel)
            .components(separatedBy: "|")
            .map { $0.replacingOccurrences(of: sentinel, with: "|")
                     .trimmingCharacters(in: .whitespaces) }
    }

    private static func table(_ rows: [[String]], alignments: [NSTextAlignment],
                              style: TranscriptStyle) -> NSAttributedString {
        let columns = max(alignments.count, rows.map(\.count).max() ?? 1)
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)

        let out = NSMutableAttributedString()
        for (r, row) in rows.enumerated() {
            for c in 0..<columns {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1,
                                             startingColumn: c, columnSpan: 1)
                block.setBorderColor(style.rule)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(7, type: .absoluteValueType, for: .padding)
                block.verticalAlignment = .topAlignment
                if r == 0 { block.backgroundColor = style.codeBackground }

                let font = r == 0 ? styled(style.body, bold: true, italic: false) : style.body
                let cell = inline(c < row.count ? row[c] : "", style: style, font: font)
                if r == 0 {
                    // The header is bold as a whole; inline() only bolds what the
                    // markdown itself marked.
                    cell.addAttributes([.font: font],
                                       range: NSRange(location: 0, length: cell.length))
                }
                let ps = NSMutableParagraphStyle()
                ps.minimumLineHeight = style.lineHeight
                ps.maximumLineHeight = style.lineHeight
                ps.alignment = c < alignments.count ? alignments[c] : .left
                ps.paragraphSpacing = 0
                ps.paragraphSpacingBefore = 0
                ps.textBlocks = [block]
                cell.addAttributes([.paragraphStyle: ps],
                                   range: NSRange(location: 0, length: cell.length))
                out.append(cell)
                // Every cell is its own paragraph; the terminator carries the
                // same block, or the cell doesn't close.
                out.append(NSAttributedString(string: "\n",
                                              attributes: [.font: font, .paragraphStyle: ps]))
            }
        }
        return out
    }

    private static func rule(style: TranscriptStyle) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacingBefore = 14
        ps.paragraphSpacing = 14
        return NSAttributedString(string: " ", attributes: [
            .font: style.body, .paragraphStyle: ps, .transcriptRule: true,
        ])
    }

    private static func bodyParagraph(_ style: TranscriptStyle) -> NSMutableParagraphStyle {
        let ps = NSMutableParagraphStyle()
        // min == max, and NOT lineHeightMultiple: that multiplies the FONT's
        // natural line height (Charter 16 → 20pt), so 1.625 would yield 32.5pt.
        ps.minimumLineHeight = style.lineHeight
        ps.maximumLineHeight = style.lineHeight
        ps.paragraphSpacing = 12
        return ps
    }

    // MARK: Inline

    private static func inline(_ text: String, style: TranscriptStyle,
                               font: NSFont) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        var current = ""
        var index = text.startIndex

        func flush(_ traits: (bold: Bool, italic: Bool, strike: Bool)) {
            guard !current.isEmpty else { return }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: styled(font, bold: traits.bold, italic: traits.italic),
                .foregroundColor: style.text,
                .baselineOffset: style.baselineOffset,
            ]
            if traits.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: current, attributes: attrs))
            current = ""
        }

        var bold = false, italic = false, strike = false
        while index < text.endIndex {
            let ch = text[index]
            let rest = text[index...]

            // Inline code wins over every other marker inside it.
            if ch == "`" {
                flush((bold, italic, strike))
                let after = text.index(after: index)
                if let close = text[after...].firstIndex(of: "`") {
                    out.append(NSAttributedString(string: String(text[after..<close]), attributes: [
                        .font: style.inlineCode,
                        .foregroundColor: style.inlineCodeText,
                        .transcriptChip: true,
                        .baselineOffset: style.baselineOffset,
                    ]))
                    index = text.index(after: close)
                    continue
                }
            }
            // [label](url)
            if ch == "[", let closeBracket = rest.firstIndex(of: "]"),
               text.index(after: closeBracket) < text.endIndex,
               text[text.index(after: closeBracket)] == "(",
               let closeParen = text[closeBracket...].firstIndex(of: ")") {
                flush((bold, italic, strike))
                let label = String(text[text.index(after: index)..<closeBracket])
                let url = String(text[text.index(closeBracket, offsetBy: 2)..<closeParen])
                out.append(link(label, url: url, style: style, font: font))
                index = text.index(after: closeParen)
                continue
            }
            // Bare URLs.
            if rest.hasPrefix("http://") || rest.hasPrefix("https://") {
                flush((bold, italic, strike))
                let end = rest.firstIndex { $0 == " " || $0 == ")" || $0 == "\n" } ?? text.endIndex
                let url = String(text[index..<end])
                out.append(link(url, url: url, style: style, font: font))
                index = end
                continue
            }
            if rest.hasPrefix("**") {
                flush((bold, italic, strike)); bold.toggle()
                index = text.index(index, offsetBy: 2); continue
            }
            if rest.hasPrefix("~~") {
                flush((bold, italic, strike)); strike.toggle()
                index = text.index(index, offsetBy: 2); continue
            }
            if ch == "*" || ch == "_" {
                // Only treat it as emphasis when it hugs a word, so `a_b_c`
                // identifiers and bare asterisks survive.
                let next = text.index(after: index)
                if next < text.endIndex, text[next] != " " || italic {
                    flush((bold, italic, strike)); italic.toggle()
                    index = next; continue
                }
            }
            current.append(ch)
            index = text.index(after: index)
        }
        flush((bold, italic, strike))
        return out
    }

    private static func link(_ label: String, url: String, style: TranscriptStyle,
                             font: NSFont) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .baselineOffset: style.baselineOffset,
        ]
        if let real = URL(string: url) { attrs[.link] = real }
        return NSAttributedString(string: label, attributes: attrs)
    }

    private static func styled(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        guard !traits.isEmpty else { return font }
        return NSFontManager.shared.convert(font, toHaveTrait: traits)
    }
}

// MARK: - Document

/// Turns the render model into one attributed document: meta labels, Claude's
/// prose full-measure, the user's messages in a right-aligned bubble.
enum TranscriptDocument {

    static func build(_ turns: [TranscriptTurn], style: TranscriptStyle,
                      measure: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var lastWasClaude = false
        for turn in turns {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            let isClaude: Bool
            if case .claude = turn.kind { isClaude = true } else { isClaude = false }
            defer { lastWasClaude = isClaude }
            switch turn.kind {
            case .claude:
                // Label the speaker, not every API turn — one visible reply can
                // be six records, and a label above each shreds the page.
                if !lastWasClaude {
                    out.append(meta("CLAUDE", style: style, alignment: .left))
                    out.append(NSAttributedString(string: "\n"))
                }
                out.append(TranscriptMarkdown.render(turn.text, style: style))
            case .user:
                out.append(bubble(turn.text, style: style, measure: measure))
                out.append(NSAttributedString(string: "\n"))
                out.append(meta("YOU", style: style, alignment: .right))
            case .summary:
                out.append(meta("SUMMARY OF EARLIER CONVERSATION", style: style, alignment: .left))
                out.append(NSAttributedString(string: "\n"))
                out.append(TranscriptMarkdown.render(turn.text, style: style))
            case .compaction(let label):
                out.append(divider(label, style: style))
            case .sessionBreak:
                out.append(divider("New session started", style: style))
            case .toolCall(let label):
                out.append(toolLine(label, style: style))
            }
            out.append(NSAttributedString(string: "\n"))
        }
        return out
    }

    /// Sans, not serif: serifs go muddy at 11pt under grayscale-only AA.
    private static func meta(_ label: String, style: TranscriptStyle,
                             alignment: NSTextAlignment) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.minimumLineHeight = 14
        ps.maximumLineHeight = 14
        ps.paragraphSpacingBefore = 20
        ps.paragraphSpacing = 4
        ps.alignment = alignment
        return NSAttributedString(string: label, attributes: [
            .font: style.meta,
            .foregroundColor: style.muted,
            .kern: 0.5,
            .paragraphStyle: ps,
        ])
    }

    /// Bubble geometry: the pill's padding, the gutter it keeps clear of the
    /// right margin, and the widest left gutter it may leave.
    static let bubblePadding: CGFloat = 12
    static let bubbleRightMargin: CGFloat = 8
    static let bubbleLeftGutter: CGFloat = 40

    /// One pill per message, hugging the right margin.
    ///
    /// A wrapped message used to right-align every line, and the painter draws
    /// one rect per line fragment — ragged-left lines share no edges, so a
    /// two-line message came out as two staggered, overlapping pills. So: a
    /// message that fits one line stays right-aligned (the line IS the pill); a
    /// message that wraps switches to left-aligned text across the full block
    /// width, where every line starts at the same x and the union of their rects
    /// is a single rectangle.
    private static func bubble(_ text: String, style: TranscriptStyle,
                               measure: CGFloat) -> NSAttributedString {
        let rendered = NSMutableAttributedString(
            attributedString: TranscriptMarkdown.render(text, style: style, bubble: true))
        let range = NSRange(location: 0, length: rendered.length)
        rendered.addAttribute(.transcriptBubble, value: true, range: range)

        let left = bubbleLeftGutter + bubblePadding
        let right = bubbleRightMargin + bubblePadding
        let content = max(80, measure - left - right)
        let box = rendered.boundingRect(
            with: NSSize(width: content, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin])
        let wraps = box.height > style.lineHeight * 1.5

        rendered.enumerateAttribute(.paragraphStyle, in: range) { value, sub, _ in
            let ps = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            ps.alignment = wraps ? .left : .right
            // Shift, don't overwrite: a list item inside the bubble keeps its
            // own hanging indent and tab stop, just moved into the block.
            ps.firstLineHeadIndent += left
            ps.headIndent += left
            ps.tabStops = ps.tabStops.map {
                NSTextTab(textAlignment: $0.alignment, location: $0.location + left,
                          options: $0.options)
            }
            ps.tailIndent = -right
            ps.paragraphSpacingBefore = 24
            rendered.addAttribute(.paragraphStyle, value: ps, range: sub)
        }
        return rendered
    }

    private static func divider(_ label: String, style: TranscriptStyle) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        ps.minimumLineHeight = 16
        ps.maximumLineHeight = 16
        ps.paragraphSpacingBefore = 24
        ps.paragraphSpacing = 20
        return NSAttributedString(string: label.uppercased(), attributes: [
            .font: style.meta,
            .foregroundColor: style.muted,
            .kern: 0.5,
            .paragraphStyle: ps,
            .transcriptRule: true,
        ])
    }

    private static func toolLine(_ label: String, style: TranscriptStyle) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.minimumLineHeight = 18
        ps.maximumLineHeight = 18
        ps.paragraphSpacingBefore = 6
        ps.paragraphSpacing = 6
        ps.headIndent = 14
        ps.firstLineHeadIndent = 14
        return NSAttributedString(string: "▸ " + label, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: style.muted,
            .paragraphStyle: ps,
        ])
    }
}

// MARK: - Painting

/// Draws what attributes alone cannot: rounded inline-code chips, code-block
/// panels with a border, the blockquote bar, the user bubble and rules.
final class TranscriptLayoutManager: NSLayoutManager {
    var style: TranscriptStyle?

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let style, let storage = textStorage, let container = textContainers.first else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        func paint(_ key: NSAttributedString.Key,
                   _ body: @escaping (NSRect, NSRange) -> Void) {
            storage.enumerateAttribute(key, in: charRange) { value, range, _ in
                guard value != nil else { return }
                let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                self.enumerateLineFragments(forGlyphRange: glyphRange) { _, used, _, lineGlyphs, _ in
                    let intersection = NSIntersectionRange(lineGlyphs, glyphRange)
                    guard intersection.length > 0 else { return }
                    var rect = self.boundingRect(forGlyphRange: intersection, in: container)
                    rect.origin.x += origin.x
                    rect.origin.y += origin.y
                    _ = used
                    body(rect, intersection)
                }
            }
        }

        // Code blocks: one panel per line fragment, joined visually because the
        // fragments are contiguous.
        paint(.transcriptCodeBlock) { rect, _ in
            let panel = NSRect(x: 0, y: rect.minY - 2,
                               width: container.size.width, height: rect.height + 4)
                .insetBy(dx: 4, dy: 0)
            style.codeBackground.setFill()
            panel.fill()
            style.codeBorder.setStroke()
            let border = NSBezierPath(rect: panel)
            border.lineWidth = 1
            border.stroke()
        }
        // Inline code chips.
        paint(.transcriptChip) { rect, _ in
            let chip = rect.insetBy(dx: -3, dy: -1)
            style.inlineCodeChip.setFill()
            NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        }
        // Blockquote bar.
        paint(.transcriptQuote) { rect, _ in
            let bar = NSRect(x: 2, y: rect.minY, width: 3, height: rect.height)
            style.blockquoteBar.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
        // User bubble: ONE pill per message. The run is expanded to its full
        // extent first — a bubble straddling the drawn glyph range would
        // otherwise be painted as two half-pills.
        var scan = charRange.location
        let whole = NSRange(location: 0, length: storage.length)
        while scan < NSMaxRange(charRange), scan < storage.length {
            var run = NSRange(location: 0, length: 0)
            let value = storage.attribute(.transcriptBubble, at: scan,
                                          longestEffectiveRange: &run, in: whole)
            defer { scan = max(NSMaxRange(run), scan + 1) }
            guard value != nil, run.length > 0 else { continue }
            let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            var union = NSRect.null
            enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
                let intersection = NSIntersectionRange(lineGlyphs, glyphs)
                guard intersection.length > 0 else { return }
                var rect = self.boundingRect(forGlyphRange: intersection, in: container)
                guard rect.width > 1 else { return }
                rect.origin.x += origin.x
                rect.origin.y += origin.y
                union = union.isNull ? rect : union.union(rect)
            }
            guard !union.isNull else { continue }
            let bubble = union.insetBy(dx: -TranscriptDocument.bubblePadding, dy: -6)
            style.bubbleBackground.setFill()
            let path = NSBezierPath(roundedRect: bubble, xRadius: 12, yRadius: 12)
            path.fill()
            style.bubbleBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        // Thematic rules and compaction dividers get a hairline through them.
        paint(.transcriptRule) { rect, _ in
            style.rule.setFill()
            let y = rect.midY.rounded()
            NSRect(x: 0, y: y, width: container.size.width, height: 1).fill()
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// Read-only by construction: no checkbox toggling, no drag-to-reorder, no
/// custom copy, no block caret. The exact opposite of `BlockCaretTextView`.
final class TranscriptTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - View

/// The transcript surface. TextKit 1 by hand-assembly (explicit container +
/// layout manager + storage) — `NSTextView()` on macOS 14 defaults to TextKit 2,
/// where `usesFontLeading` is unreachable and any line carrying a ☐ renders
/// 27.34pt instead of the scale's 26.00.
struct TranscriptTextViewRepresentable: NSViewRepresentable {
    let document: NSAttributedString
    let style: TranscriptStyle
    let generation: Int
    /// Bumped when the palette or reading face changes. The document is rebuilt
    /// in the new colors, so the diff below has to notice — keying on `generation`
    /// alone left the text painted in the old theme until the next turn landed.
    let styleGeneration: Int
    /// Reading measure; the view centres it and grows its gutters, not its lines.
    let measure: CGFloat

    final class Coordinator {
        var textView: TranscriptTextView?
        var scrollView: NSScrollView?
        var lastGeneration = -1
        var lastStyleGeneration = -1
        /// The pane follows the tail only while the reader is already at it.
        var following = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = TranscriptLayoutManager()
        layout.style = style
        // Without this, AppleSymbols' 1.34pt leading (it serves ☐/☑) is added on
        // top of maximumLineHeight and every checkbox line breaks the grid.
        layout.usesFontLeading = false
        let container = NSTextContainer(size: NSSize(width: measure, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let textView = TranscriptTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = style.background
        textView.textContainerInset = NSSize(width: 0, height: 20)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: style.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = style.background
        scroll.automaticallyAdjustsContentInsets = false

        context.coordinator.textView = textView
        context.coordinator.scrollView = scroll
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let doc = scroll.documentView else { return }
                let maxY = max(0, doc.bounds.height - scroll.contentView.bounds.height)
                context.coordinator.following = scroll.contentView.bounds.origin.y >= maxY - 24
            }
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        apply(document, to: context.coordinator, animated: false)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.lastGeneration != generation
                || context.coordinator.lastStyleGeneration != styleGeneration else { return }
        let restyled = context.coordinator.lastStyleGeneration != styleGeneration
        context.coordinator.lastGeneration = generation
        context.coordinator.lastStyleGeneration = styleGeneration
        if restyled {
            (scroll.documentView as? NSTextView)?.linkTextAttributes = [
                .foregroundColor: style.link,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .cursor: NSCursor.pointingHand,
            ]
        }
        apply(document, to: context.coordinator, animated: true)
    }

    private func apply(_ document: NSAttributedString, to coordinator: Coordinator, animated: Bool) {
        guard let textView = coordinator.textView, let scroll = coordinator.scrollView else { return }
        (textView.layoutManager as? TranscriptLayoutManager)?.style = style
        textView.backgroundColor = style.background
        scroll.backgroundColor = style.background
        let inset = max(0, (scroll.contentSize.width - measure) / 2)
        textView.textContainerInset = NSSize(width: max(24, inset), height: 20)
        textView.textStorage?.setAttributedString(document)
        guard coordinator.following else { return }
        DispatchQueue.main.async {
            textView.scrollToEndOfDocument(nil)
        }
    }
}

/// The pane: header chip when the binding is a guess, the document, empty states.
struct TranscriptPane: View {
    @EnvironmentObject var vm: EditorViewModel
    @ObservedObject private var store = TranscriptStore.shared
    /// Repaints with the terminal, whose ground it must match exactly — the two
    /// sit 1px apart in the same panel.
    @State private var paletteGeneration = 0

    private var style: TranscriptStyle {
        _ = paletteGeneration
        return TranscriptStyle.resolve(isDark: TerminalSessions.currentPalette().isDark)
    }

    var body: some View {
        GeometryReader { geo in
            let measure = min(480, max(320, geo.size.width - 48))
            ZStack(alignment: .top) {
                Color(nsColor: style.background)
                if store.turns.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TranscriptTextViewRepresentable(
                        document: TranscriptDocument.build(store.turns, style: style,
                                                           measure: measure),
                        style: style,
                        generation: store.generation,
                        styleGeneration: paletteGeneration,
                        measure: measure)
                }
                if !store.isAuthoritative, store.resolvedPath != nil {
                    guessChip
                }
                if store.isWorking {
                    TranscriptWorkingIndicator(style: style)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        // Aligned to the text column, not the pane edge: the
                        // view centres its measure and grows the gutters.
                        .padding(.leading, max(24, (geo.size.width - measure) / 2))
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .floatnoteTerminalPaletteChanged)) { _ in
            paletteGeneration &+= 1
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 20, weight: .light))
                .foregroundColor(Color(nsColor: style.muted).opacity(0.6))
            Text(store.resolvedPath == nil
                 ? "No conversation yet"
                 : "Reading…")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(nsColor: style.muted))
            Text(store.resolvedPath == nil
                 ? "This pane's transcript appears once Claude replies."
                 : "")
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: style.muted).opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    /// Steps 2–4 of the ladder are guesses and must say so: with two panes on one
    /// cwd, `lastSessionId` is wrong roughly half the time.
    private var guessChip: some View {
        Text("best guess")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(Color(nsColor: style.muted))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(nsColor: style.rule).opacity(0.6)))
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help("This pane hasn't reported its session id yet — showing the most likely conversation")
    }
}

// MARK: - Mode

/// What the terminal panel is showing. Visibility stays the panel's own business
/// — a separate `fn.transcriptVisible` would have to be threaded through the
/// route gate's hide branch and the pin stash, and missing either strands the pane.
/// Two states, not three. A transcript-only mode existed and was removed: the
/// terminal is the only place you can type, so a surface that hides it is a dead
/// end — you always want the input line in view. An unknown stored value (the old
/// `transcript`) falls back to `.split`.
enum TranscriptMode: String, CaseIterable {
    case terminal
    case split

    var next: TranscriptMode { self == .terminal ? .split : .terminal }

    var symbol: String {
        switch self {
        case .terminal: return "text.alignleft"
        case .split: return "rectangle.split.1x2"
        }
    }

    var help: String {
        switch self {
        case .terminal: return "Show the transcript"
        case .split: return "Hide the transcript"
        }
    }
}

/// Drag to re-apportion the panel between transcript and terminal. Mirrors
/// `TerminalResizeHandle`, but vertical and bounded by both surfaces' minimums:
/// the terminal keeps ~10 rows plus its input frame.
struct TranscriptSplitHandle: View {
    @EnvironmentObject var vm: EditorViewModel
    let totalHeight: CGFloat
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var startFraction: Double = 0.6

    private let transcriptMinimum: CGFloat = 180
    private let terminalMinimum: CGFloat = 220

    var body: some View {
        ZStack {
            Rectangle()
                .fill(isHovering || isDragging ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.12))
                .frame(height: isHovering || isDragging ? 2 : 1)
        }
        .frame(height: 6)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging { isDragging = true; startFraction = vm.transcriptSplitFraction }
                    guard totalHeight > transcriptMinimum + terminalMinimum else { return }
                    let proposed = startFraction * totalHeight + value.translation.height
                    let clamped = min(max(proposed, transcriptMinimum), totalHeight - terminalMinimum)
                    vm.transcriptSplitFraction = Double(clamped / totalHeight)
                }
                .onEnded { _ in isDragging = false }
        )
    }
}
