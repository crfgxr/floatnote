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

    // MARK: - Appearance

    static let appearanceKey = "fn.terminalAppearance"

    static var selectedAppearance: TerminalAppearance {
        UserDefaults.standard.string(forKey: appearanceKey)
            .flatMap(TerminalAppearance.init(rawValue:)) ?? .followApp
    }

    /// Is the *app's* current theme a dark one? Read from the same UserDefault
    /// `EditorViewModel.theme` persists to, so the terminal layer can resolve
    /// its own colors without a reference back to the view model.
    static var appThemeIsDark: Bool {
        guard let raw = UserDefaults.standard.string(forKey: "fn.theme") else { return true }
        switch raw {
        case "paper", "sepia": return false
        default: return true
        }
    }

    /// The palette every pane renders in right now.
    static func currentPalette() -> TerminalPalette {
        switch selectedAppearance {
        case .followApp:   return appThemeIsDark ? .claudeDark : .claudeLight
        case .claudeLight: return .claudeLight
        case .claudeDark:  return .claudeDark
        case .classic:     return .classic
        }
    }

    /// Persist an appearance and repaint every open pane — including hidden
    /// ones, so switching chips never reveals the old colors.
    func setAppearance(_ appearance: TerminalAppearance) {
        UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey)
        applyAppearance()
    }

    /// Repaint all panes in the current palette. Called on appearance changes
    /// and whenever the app theme flips.
    func applyAppearance() {
        let palette = Self.currentPalette()
        for session in sessions.values { Self.apply(palette, to: session.view) }
        NotificationCenter.default.post(name: .floatnoteTerminalPaletteChanged, object: nil)
        Self.syncClaudeCodeTheme(palette)
        dbg("terminal palette: \(Self.selectedAppearance.rawValue) → \(palette.isDark ? "dark" : "light") (\(sessions.count) pane(s))")
    }

    static func apply(_ palette: TerminalPalette, to view: TerminalView) {
        // installColors updates the terminal's palette AND the display; setting
        // Terminal.installPalette alone would leave the rendered cells stale.
        view.installColors(palette.ansi)
        view.nativeBackgroundColor = palette.background
        view.nativeForegroundColor = palette.foreground
        view.caretColor = palette.cursor
        view.caretTextColor = palette.background
        view.selectedTextBackgroundColor = palette.selection
        view.needsDisplay = true
    }

    /// Claude Code carries its own light/dark theme, and its diff and dim
    /// colors are chosen for that assumption — its dark theme on a cream
    /// background is unreadable. Keep `~/.claude/settings.json` in step.
    ///
    /// The file is global (every Claude Code session on this Mac reads it) and
    /// only *new* sessions pick up a change, so: write only when the value
    /// actually differs, preserve every other key, and never fail loudly.
    static func syncClaudeCodeTheme(_ palette: TerminalPalette) {
        let path = NSHomeDirectory() + "/.claude/settings.json"
        let wanted = palette.isDark ? "dark" : "light"
        var settings: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            settings = obj
        }
        if let current = settings["theme"] as? String, current == wanted { return }
        settings["theme"] = wanted
        guard let out = try? JSONSerialization.data(withJSONObject: settings,
                                                    options: [.prettyPrinted, .sortedKeys]) else { return }
        let tmp = path + ".floatnote-tmp"
        do {
            try out.write(to: URL(fileURLWithPath: tmp))
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                      withItemAt: URL(fileURLWithPath: tmp))
            dbg("claude settings: theme → \(wanted)")
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            dbg("claude settings: theme write failed — \(error)")
        }
    }

    // MARK: - Font

    static let fontFamilyKey = "fn.terminalFontFamily"
    static let fontSizeKey = "fn.terminalFontSize"
    static let fontWeightKey = "fn.terminalFontWeight"
    static let lineSpacingKey = "fn.terminalLineSpacing"
    /// Sentinel family meaning `NSFont.monospacedSystemFont` — i.e. real SF
    /// Mono. macOS ships SF Mono as a system-restricted face, so it is NOT in
    /// `availableFontFamilies` and `NSFont(name: "SF Mono")` fails on a stock
    /// Mac; this is the only way to actually get it, and it is the same face
    /// Claude Desktop renders code in.
    static let systemMonoFamily = "system"
    /// 13pt medium: Menlo-at-12 reads thin and wide against the cream Claude
    /// Light surface, which is what made the terminal look unlike Desktop.
    static let defaultFontSize: CGFloat = 13

    /// Monospaced families offered in the picker: the ones worth typing in that
    /// this Mac actually has. Enumerating every installed monospaced font would
    /// be a menu of dozens, most of them novelty faces.
    static let candidateFontFamilies = [
        "SF Mono", "Menlo", "Monaco", "Courier New", "Andale Mono",
        "JetBrains Mono", "Fira Code", "IBM Plex Mono", "Source Code Pro",
        "Hack", "Cascadia Code", "Cascadia Mono", "Iosevka", "Roboto Mono",
    ]

    static func availableFontFamilies() -> [String] {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return candidateFontFamilies.filter { installed.contains($0) }
    }

    static var selectedFontFamily: String {
        UserDefaults.standard.string(forKey: fontFamilyKey) ?? systemMonoFamily
    }

    /// Extra points per row. Normal (2pt) is the default: upstream SwiftTerm
    /// packs rows at exactly the font's ascent+descent+leading, which reads
    /// tighter than a rendered-markdown UI. Vendored-fork knob — see
    /// `TerminalView.extraLineSpacing`.
    static var selectedLineSpacing: CGFloat {
        guard UserDefaults.standard.object(forKey: lineSpacingKey) != nil else { return 2 }
        return CGFloat(UserDefaults.standard.double(forKey: lineSpacingKey))
    }

    /// Weight names → `NSFont.Weight`. Kept as strings in defaults so the
    /// stored value survives a change of cuts.
    static let fontWeights: [(String, NSFont.Weight)] = [
        ("Light", .light), ("Regular", .regular), ("Medium", .medium), ("Semibold", .semibold),
    ]

    static var selectedFontWeight: NSFont.Weight {
        guard let name = UserDefaults.standard.string(forKey: fontWeightKey) else { return .medium }
        return fontWeights.first { $0.0.lowercased() == name }?.1 ?? .medium
    }

    static var selectedFontSize: CGFloat {
        let stored = UserDefaults.standard.double(forKey: fontSizeKey)
        return stored > 0 ? CGFloat(stored) : defaultFontSize
    }

    /// The font every terminal view renders in. Falls back down the chain
    /// rather than returning nil: a missing font must never leave a pane
    /// rendering in a proportional face.
    static func currentFont() -> NSFont {
        let size = selectedFontSize
        let weight = selectedFontWeight
        let family = selectedFontFamily
        if family != systemMonoFamily, let font = NSFont(name: family, size: size) {
            // Apple's SF Mono ships one file per cut; asking for the PostScript
            // name gets the real face instead of a synthesised weight.
            if family == "SF Mono",
               let name = fontWeights.first(where: { $0.1 == weight })?.0,
               let exact = NSFont(name: "SFMono-\(name)", size: size) {
                return exact
            }
            guard weight != .regular else { return font }
            // Named families don't take a weight directly; go through the
            // descriptor so e.g. Menlo picks up its Bold-ish cut when asked.
            let descriptor = font.fontDescriptor.addingAttributes([
                .traits: [NSFontDescriptor.TraitKey.weight: weight]
            ])
            return NSFont(descriptor: descriptor, size: size) ?? font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Persist a new font and apply it to every open pane — including the ones
    /// that aren't on screen, so switching chips never shows the old face.
    func setFont(family: String? = nil, size: CGFloat? = nil, weight: NSFont.Weight? = nil,
                 lineSpacing: CGFloat? = nil) {
        let defaults = UserDefaults.standard
        if let family { defaults.set(family, forKey: Self.fontFamilyKey) }
        if let size { defaults.set(Double(size), forKey: Self.fontSizeKey) }
        if let weight, let name = Self.fontWeights.first(where: { $0.1 == weight })?.0 {
            defaults.set(name.lowercased(), forKey: Self.fontWeightKey)
        }
        if let lineSpacing { defaults.set(Double(lineSpacing), forKey: Self.lineSpacingKey) }
        let font = Self.currentFont()
        let spacing = Self.selectedLineSpacing
        // Spacing is read during the font setter's relayout, so it must be in
        // place first; assigning the font is then what repaints every pane.
        TerminalView.extraLineSpacing = spacing
        for session in sessions.values { session.view.font = font }
        dbg("terminal font: \(font.fontName) \(Int(font.pointSize))pt +\(Int(spacing))pt line (\(sessions.count) pane(s))")
    }

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
        TerminalView.extraLineSpacing = TerminalSessions.selectedLineSpacing
        view.font = TerminalSessions.currentFont()
        TerminalSessions.apply(TerminalSessions.currentPalette(), to: view)
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
    /// The terminal palette changed — chrome that paints itself in the
    /// terminal's colors (the tab bar's active chip) redraws.
    static let floatnoteTerminalPaletteChanged =
        Notification.Name("floatnote.terminal.paletteChanged")
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

/// Font picker for the terminal panel, as an `NSMenu` popped from the tab bar's
/// `Aa` button: family, then size. `NSMenuItem` needs an ObjC target, which a
/// SwiftUI view can't be — hence the singleton, matching `HandsfreeMenuTarget`.
@MainActor
final class TerminalFontMenuTarget: NSObject {
    static let shared = TerminalFontMenuTarget()

    @objc func selectFamily(_ sender: NSMenuItem) {
        guard let family = sender.representedObject as? String else { return }
        TerminalSessions.shared.setFont(family: family)
    }

    @objc func selectSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? Double else { return }
        TerminalSessions.shared.setFont(size: CGFloat(size))
    }

    /// Points added per row. Beyond ~8 the block caret starts to look detached
    /// from its line.
    static let lineSpacings: [(String, Double)] = [
        ("Tight", 0), ("Normal", 2), ("Relaxed", 5), ("Airy", 8),
    ]

    @objc func selectLineSpacing(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        TerminalSessions.shared.setFont(lineSpacing: CGFloat(value))
    }

    @objc func selectWeight(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let weight = TerminalSessions.fontWeights.first(where: { $0.0.lowercased() == raw })?.1
        else { return }
        TerminalSessions.shared.setFont(weight: weight)
    }

    /// Sizes worth offering: below 10 the block caret stops being legible,
    /// above 18 a terminal panel holds too few columns for Claude Code's UI.
    static let sizes: [Double] = [10, 11, 12, 13, 14, 15, 16, 18]

    @objc func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let appearance = TerminalAppearance(rawValue: raw) else { return }
        TerminalSessions.shared.setAppearance(appearance)
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let family = TerminalSessions.selectedFontFamily
        let size = TerminalSessions.selectedFontSize
        let appearance = TerminalSessions.selectedAppearance

        let header = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for option in TerminalAppearance.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(selectAppearance(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = appearance == option ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let fontHeader = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
        fontHeader.isEnabled = false
        menu.addItem(fontHeader)

        let systemItem = NSMenuItem(title: "SF Mono (System)",
                                    action: #selector(selectFamily(_:)), keyEquivalent: "")
        systemItem.target = self
        systemItem.representedObject = TerminalSessions.systemMonoFamily
        systemItem.state = family == TerminalSessions.systemMonoFamily ? .on : .off
        menu.addItem(systemItem)
        menu.addItem(.separator())

        for name in TerminalSessions.availableFontFamilies() {
            let item = NSMenuItem(title: name, action: #selector(selectFamily(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = family == name ? .on : .off
            // Show each family in its own face — picking a terminal font by
            // name alone is guesswork.
            if let font = NSFont(name: name, size: 13) {
                item.attributedTitle = NSAttributedString(string: name, attributes: [.font: font])
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for value in Self.sizes {
            let item = NSMenuItem(title: "\(Int(value)) pt", action: #selector(selectSize(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(size - CGFloat(value)) < 0.01 ? .on : .off
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let weightItem = NSMenuItem(title: "Weight", action: nil, keyEquivalent: "")
        let weightMenu = NSMenu()
        for (title, weight) in TerminalSessions.fontWeights {
            let item = NSMenuItem(title: title, action: #selector(selectWeight(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = title.lowercased()
            item.state = TerminalSessions.selectedFontWeight == weight ? .on : .off
            weightMenu.addItem(item)
        }
        weightItem.submenu = weightMenu
        menu.addItem(weightItem)

        let spacingItem = NSMenuItem(title: "Line Spacing", action: nil, keyEquivalent: "")
        let spacingMenu = NSMenu()
        for (title, value) in Self.lineSpacings {
            let item = NSMenuItem(title: title, action: #selector(selectLineSpacing(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(TerminalSessions.selectedLineSpacing - CGFloat(value)) < 0.01 ? .on : .off
            spacingMenu.addItem(item)
        }
        spacingItem.submenu = spacingMenu
        menu.addItem(spacingItem)
        return menu
    }
}

// MARK: - Terminal appearance

/// Which colors the terminal panes render in.
enum TerminalAppearance: String, CaseIterable {
    /// Claude Light under a light app theme, Claude Dark under a dark one.
    case followApp
    case claudeLight
    case claudeDark
    /// The pre-v1.70 look: black surface, SwiftTerm's stock ANSI palette.
    case classic

    var title: String {
        switch self {
        case .followApp:   return "Follow App Theme"
        case .claudeLight: return "Claude Light"
        case .claudeDark:  return "Claude Dark"
        case .classic:     return "Classic Black"
        }
    }
}

/// A terminal color scheme: surface, text, caret, selection and the 16 ANSI
/// colors Claude Code paints its TUI with.
///
/// A terminal can't reproduce Claude Desktop's typography — rounded code
/// chips, proportional text and underlined links are HTML, and this is a grid
/// of monospaced cells that Claude Code draws itself. What it *can* match is
/// the paint, which is what these two palettes are: Claude's own surface
/// colors, its coral accent on the caret, and ANSI values picked to read
/// correctly against each background.
struct TerminalPalette {
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let selection: NSColor
    let ansi: [SwiftTerm.Color]
    let isDark: Bool

    /// Claude's coral, on the caret in both palettes.
    static let accentHex = 0xD9_77_57

    static let claudeLight = TerminalPalette(
        background: nsColor(0xFA_F9_F5),
        foreground: nsColor(0x1F_1E_1D),
        cursor: nsColor(accentHex),
        selection: nsColor(0xE4_DF_D2),
        ansi: [
            // Normal: darker, for legibility on cream.
            termColor(0x26_26_24), termColor(0xB5_37_2B), termColor(0x2C_6E_49), termColor(0x9A_67_00),
            termColor(0x25_63_EB), termColor(0x7C_3A_ED), termColor(0x0E_74_90), termColor(0x6B_68_62),
            // Bright.
            termColor(0x8C_88_80), termColor(0xD9_63_4E), termColor(0x3B_8F_60), termColor(0xB7_79_1F),
            termColor(0x3B_82_F6), termColor(0x93_66_F0), termColor(0x0E_9B_B5), termColor(0x1F_1E_1D),
        ],
        isDark: false)

    static let claudeDark = TerminalPalette(
        background: nsColor(0x26_26_24),
        foreground: nsColor(0xF5_F4_EF),
        cursor: nsColor(accentHex),
        selection: nsColor(0x45_44_40),
        ansi: [
            termColor(0x30_30_2E), termColor(0xE0_6C_5A), termColor(0x57_B8_7F), termColor(0xE0_B2_52),
            termColor(0x6E_A8_FE), termColor(0xB7_9C_F5), termColor(0x56_C7_D6), termColor(0xD5_D2_CA),
            termColor(0x6B_68_62), termColor(0xF0_8A_76), termColor(0x7F_D3_A0), termColor(0xF0_C8_78),
            termColor(0x8E_C0_FF), termColor(0xC9_B4_FF), termColor(0x7F_DC_E8), termColor(0xFA_F9_F5),
        ],
        isDark: true)

    /// What every pane looked like before this existed.
    static let classic = TerminalPalette(
        background: .black,
        foreground: nsColor(0xD0_D0_D0),
        cursor: nsColor(0xD0_D0_D0),
        selection: nsColor(0x44_44_44),
        ansi: [
            termColor(0x00_00_00), termColor(0xCD_00_00), termColor(0x00_CD_00), termColor(0xCD_CD_00),
            termColor(0x00_00_EE), termColor(0xCD_00_CD), termColor(0x00_CD_CD), termColor(0xE5_E5_E5),
            termColor(0x7F_7F_7F), termColor(0xFF_00_00), termColor(0x00_FF_00), termColor(0xFF_FF_00),
            termColor(0x5C_5C_FF), termColor(0xFF_00_FF), termColor(0x00_FF_FF), termColor(0xFF_FF_FF),
        ],
        isDark: true)

    /// SwiftTerm components are 0…65535, so each 8-bit channel scales by 257.
    private static func termColor(_ hex: Int) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16((hex >> 16 & 0xFF) * 257),
                        green: UInt16((hex >> 8 & 0xFF) * 257),
                        blue: UInt16((hex & 0xFF) * 257))
    }

    private static func nsColor(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255,
                green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    /// SwiftUI mirrors, for chrome that paints itself in the terminal's colors.
    var backgroundColor: SwiftUI.Color { SwiftUI.Color(nsColor: background) }
    var foregroundColor: SwiftUI.Color { SwiftUI.Color(nsColor: foreground) }
}
