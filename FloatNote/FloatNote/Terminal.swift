import SwiftUI
import AppKit
import SwiftTerm

/// Owns terminal shells independently of the SwiftUI view lifecycle. A session
/// (its `LocalProcessTerminalView` + child shell) is created the first time its
/// id is shown and lives until `close(_:)` is called — i.e. the terminal's ✕
/// button — NOT when the SwiftUI view is dismantled. This is what makes hiding
/// the panel (or any view remount) keep the shell alive instead of killing it.
final class TerminalSessions {
    static let shared = TerminalSessions()
    private var sessions: [UUID: TerminalSession] = [:]

    private init() {
        // SwiftTerm defaults to 500 lines — a few seconds of Claude Code output,
        // after which the scrollback trims on every new line. Deep enough to
        // scroll back through a whole turn instead. (Vendored-fork knob; see
        // vendor-swiftterm.sh.)
        TerminalView.defaultScrollback = 20_000
    }

    /// The live session for `id`, creating (and starting its shell) on first use.
    /// `cwd` is the shell's working directory, used only on first creation; an
    /// existing session keeps the directory it was started in.
    /// `freshClaude` forces a brand-new Claude conversation for this pane
    /// (plain `claude`, never `--continue`) — see `TerminalSession.freshClaude`.
    func session(for id: UUID, cwd: String, freshClaude: Bool = false) -> TerminalSession {
        if let existing = sessions[id] { return existing }
        let s = TerminalSession(id: id, cwd: cwd, freshClaude: freshClaude)
        sessions[id] = s
        return s
    }

    /// The live session for `id` if one exists, without creating it.
    func existing(_ id: UUID) -> TerminalSession? { sessions[id] }

    /// Permanently end a session: terminate its shell and forget it. Called only
    /// when the user closes a terminal, never on hide.
    func close(_ id: UUID) {
        sessions[id]?.terminate()
        sessions[id] = nil
    }

    /// The session whose terminal view contains `responder`, if any. Used to
    /// decide whether keyboard focus is "inside a terminal" for Cmd+W / Cmd+N.
    func id(containing responder: NSResponder?) -> UUID? {
        guard let view = responder as? NSView else { return nil }
        return sessions.first { view.isDescendant(of: $0.value.view) }?.key
    }
}

/// A single terminal shell + its view, retained by `TerminalSessions`.
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let id: UUID
    let cwd: String
    let view: LocalProcessTerminalView
    /// Always start a brand-new Claude conversation in this pane, even when the
    /// project has saved sessions. Set for explicitly-added terminals: a second
    /// pane on the same project would otherwise `--continue` straight into the
    /// conversation the first pane is already running.
    let freshClaude: Bool
    private var resetObserver: NSObjectProtocol?
    /// Bumped on each (re)start so a delayed `claude` auto-send from a prior
    /// session can never land in a newer shell.
    private var sessionGen = 0
    /// Set before we kill the shell ourselves (restart / explicit close) so
    /// `processTerminated` can tell an intentional kill from the user typing
    /// `exit` — only the latter auto-closes the pane.
    private var expectedTermination = false

    init(id: UUID, cwd: String, freshClaude: Bool = false) {
        self.id = id
        self.cwd = cwd
        self.freshClaude = freshClaude
        self.view = LocalProcessTerminalView(frame: .zero)
        super.init()
        view.processDelegate = self
        view.caretViewTracksFocus = false  // always render filled block, even when unfocused
        // Selection beats mouse reporting. With reporting on (SwiftTerm's
        // default), every chunk of output runs `feedPrepare()` → `selection
        // .active = false`, so text selected while Claude is still streaming is
        // silently dropped and Cmd+C copies nothing. SwiftTerm's own docs flag
        // this ("This poses a problem for selection"). Claude Code is
        // keyboard-driven, so forwarding mouse events to it buys us little.
        view.allowMouseReporting = false
        if let mono = NSFont(name: "SF Mono", size: 12) ?? NSFont(name: "Menlo", size: 12) {
            view.font = mono
        }
        startShell()
        observeReset()
    }

    func observeReset() {
        resetObserver = NotificationCenter.default.addObserver(
            forName: .floatnoteTerminalReset, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            // A nil target restarts all terminals; a UUID target restarts
            // only the matching one.
            if let target = note.object as? UUID, target != self.id { return }
            self.restart()
        }
    }

    deinit {
        if let o = resetObserver { NotificationCenter.default.removeObserver(o) }
    }

    func startShell() {
        let term = view
        // Disable caret blink — steady block cursor.
        term.terminal?.setCursorStyle(.steadyBlock)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let home = NSHomeDirectory()
        // The session's route directory; fall back to HOME if it no longer exists.
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : home
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("HOME=\(home)")
        term.startProcess(
            executable: shell,
            args: ["-l"],
            environment: env,
            execName: "-\(NSString(string: shell).lastPathComponent)",
            currentDirectory: dir
        )
        // Auto-run `claude` (or `claude --continue`, see claudeLaunchCommand)
        // once the login shell has finished initializing. The shell already
        // starts in the target folder (via currentDirectory). The generation
        // guard ensures a restart invalidates a pending send from the
        // previous shell. The command is decided at send time so a restart
        // picks up whatever conversation history exists by then.
        sessionGen += 1
        let gen = sessionGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak term] in
            guard let self, self.sessionGen == gen else { return }
            let command = self.freshClaude ? "claude\n" : TerminalSession.claudeLaunchCommand(
                dir: dir,
                home: home,
                projectsRoot: home + "/.claude/projects"
            )
            term?.send(txt: command)
        }
    }

    /// Munges an absolute path into Claude Code's session-store directory
    /// name convention: every character outside `[A-Za-z0-9]` becomes `-`.
    /// e.g. `/Users/x/CodTemp/floatnote` → `-Users-x-CodTemp-floatnote`.
    static func mungedClaudeProjectDirName(for path: String) -> String {
        String(path.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        })
    }

    /// Decides the command to auto-send when a shell starts in `dir`. HOME
    /// always gets a fresh `claude`; any other directory resumes the most
    /// recent Claude Code conversation (`claude --continue`) if Claude
    /// Code's session store (`projectsRoot/<munged dir>`) has at least one
    /// saved `.jsonl` conversation for it, else starts fresh with plain
    /// `claude`. Pure and parameterized (no `NSHomeDirectory()` /
    /// `FileManager.default` baked in) so it can be exercised outside the
    /// app.
    static func claudeLaunchCommand(
        dir: String,
        home: String,
        projectsRoot: String,
        fileManager: FileManager = .default
    ) -> String {
        guard dir != home else { return "claude\n" }
        let sessionDir = projectsRoot + "/" + mungedClaudeProjectDirName(for: dir)
        let hasSession = (try? fileManager.contentsOfDirectory(atPath: sessionDir))?
            .contains { $0.hasSuffix(".jsonl") } ?? false
        return hasSession ? "claude --continue\n" : "claude\n"
    }

    func restart() {
        expectedTermination = true
        view.process.terminate()
        DispatchQueue.main.async { [weak self] in self?.startShell() }
    }

    /// Terminate the child shell for good (called on close).
    func terminate() {
        if let o = resetObserver { NotificationCenter.default.removeObserver(o); resetObserver = nil }
        expectedTermination = true
        view.process.terminate()
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    /// The shell ended on its own (e.g. the user typed `exit`) → close the pane.
    /// Intentional kills (restart / ✕ button) consume `expectedTermination` and
    /// are ignored so a restart doesn't close its own pane.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        if expectedTermination {
            expectedTermination = false
            return
        }
        let id = self.id
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .floatnoteTerminalExited, object: id)
        }
    }
}

extension Notification.Name {
    /// Posted (object = session UUID) when a shell exits by itself, so the app
    /// can close that terminal pane.
    static let floatnoteTerminalExited = Notification.Name("floatnote.terminal.exited")
}

/// Thin SwiftUI wrapper that displays a session's view. It deliberately does NOT
/// create or tear down the shell — `TerminalSessions` owns that lifecycle — so
/// hiding the panel (which dismantles/remakes this wrapper) never kills the shell.
///
/// `makeNSView` returns a FRESH container each time (SwiftUI doesn't reliably
/// re-display a reused representable view), then re-parents the persistent
/// terminal view into it. On hide the container is discarded but the terminal
/// view (owned by `TerminalSessions`) survives and is re-attached on unhide.
struct SwiftTermContainer: NSViewRepresentable {
    let id: UUID
    let cwd: String
    var freshClaude: Bool = false

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attachTerminal(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attachTerminal(to: nsView)
    }

    private func attachTerminal(to container: NSView) {
        let term = TerminalSessions.shared.session(for: id, cwd: cwd, freshClaude: freshClaude).view
        guard term.superview !== container else { return }
        term.removeFromSuperview()
        term.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(term)
        NSLayoutConstraint.activate([
            term.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            term.topAnchor.constraint(equalTo: container.topAnchor),
            term.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

// MARK: - Scroll-back pill

/// "↓ N lines below" badge shown over a terminal the user has scrolled up in,
/// the way iTerm2 signals that output is still arriving out of view. Clicking
/// it returns to the newest output (and resumes following it, since landing on
/// the last row clears the vendored SwiftTerm's `userScrolling` flag).
///
/// The count is polled rather than pushed: SwiftTerm's `TerminalViewDelegate`
/// callbacks aren't forwarded through `LocalProcessTerminalViewDelegate`, and
/// reading two ints four times a second is cheaper than widening the fork.
struct TerminalScrollPill: View {
    let terminalId: UUID

    @State private var linesBelow = 0
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if linesBelow > 0 {
                Button(action: scrollToBottom) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 9, weight: .bold))
                        Text(linesBelow == 1 ? "1 line below" : "\(linesBelow) lines below")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .help("Jump to the newest output")
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.trailing, 12)
        .padding(.bottom, 10)
        .onReceive(tick) { _ in
            let count = TerminalSessions.shared.existing(terminalId)?.view.linesBelowViewport ?? 0
            if count != linesBelow {
                withAnimation(.easeOut(duration: 0.15)) { linesBelow = count }
            }
        }
    }

    private func scrollToBottom() {
        TerminalSessions.shared.existing(terminalId)?.view.scrollToBottom()
        linesBelow = 0
    }
}
