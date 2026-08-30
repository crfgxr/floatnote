import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation
import AudioToolbox
import ScreenCaptureKit
import UserNotifications

func dbg(_ msg: String) {
    let path = NSHomeDirectory() + "/.floatnote-debug.log"
    let line = "\(Date()): \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: path) {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            }
        } else { try? data.write(to: URL(fileURLWithPath: path)) }
    }
}

let APP_VERSION = "v1.94.12"
let LOCAL_SAVE_PATH = NSHomeDirectory() + "/.floatnote-local.html"
let LOCAL_TABS_PATH = NSHomeDirectory() + "/.floatnote-tabs.json"
let LOCAL_FOLDERS_PATH = NSHomeDirectory() + "/.floatnote-folders.json"

@main
struct FloatNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var vm = EditorViewModel()

    @ObservedObject private var handsfree = HandsfreeManager.shared

    var body: some Scene {
        WindowGroup {
            EditorView()
                .environmentObject(vm)
                .background(WindowAccessor())
                .onAppear { appDelegate.vm = vm }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 800, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) { } // Disable Cmd+N / new window
            CommandGroup(replacing: .saveItem) {
                Button("Export Notes…") { vm.exportNotes() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Import Notes…") { vm.importNotes() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            // The toolbar's photo button lives in a horizontally scrolling zone,
            // so it can be off-screen when the terminal panel is open. This menu
            // item is the always-reachable way to attach an image.
            CommandGroup(after: .pasteboard) {
                Button("Insert Image…") { vm.attachImage() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
            // Hands-free voice needs a reachable, *named* way in: the toolbar
            // has a second mic-shaped button (editor dictation) right next to
            // it, and one icon among a dozen is not a discoverable switch.
            // No key equivalent — the menu item and the toolbar button are the
            // two ways in, and a global chord here would collide with whatever
            // the terminal's TUI wants that key for.
            CommandGroup(after: .toolbar) {
                Button(handsfree.isEnabled ? "Turn Off Hands-Free Voice"
                                           : "Hands-Free Voice") { vm.toggleHandsfree() }
                Button(vm.isBrowserVisible ? "Hide Browser" : "Browser") { vm.toggleBrowser() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var vm: EditorViewModel?
    private var fileWatchTimer: Timer?
    private var terminalKeyMonitor: Any?
    private var terminalExitObserver: NSObjectProtocol?
    private var browserVisibilityObserver: NSObjectProtocol?
    private var browserAnnotationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        // Claude hook notifications: banner when a Claude session in a
        // FloatNote terminal finishes a turn or needs input; click routes back
        // to that terminal. One-time permission prompt (persists across
        // rebuilds — stable signing identity).
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        dbg("APP LAUNCHED")

        // Immediate delivery of Claude hook events; the timer below still
        // sweeps the spool as a safety net.
        if let vm {
            MainActor.assumeIsolated {
                vm.startClaudeEventWatcher()
                HandsfreeManager.shared.vm = vm
                // Claude's browser calls arrive as files; the watcher runs them
                // the moment they land, the 2s timer below sweeps as a net.
                BrowserSessions.shared.startRPCWatcher()
            }
        }
        // Sync Claude Code's own light/dark theme to the terminal palette at
        // launch, so a pane opened later doesn't start in the wrong one.
        MainActor.assumeIsolated {
            TerminalSessions.syncClaudeCodeTheme(TerminalSessions.currentPalette())
        }

        // Poll tabs + folders files for external changes (e.g. from MCP server)
        fileWatchTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let vm = self?.vm else { return }
            MainActor.assumeIsolated {
                vm.checkExternalTabChanges()
                vm.checkExternalFolderChanges()
                vm.checkExternalBoardChanges()
                vm.checkClaudeEvents()
                vm.sweepExpiredJobStatuses()
                TranscriptStore.shared.poll()
                vm.checkPaneActivity()
                BrowserSessions.shared.pollRPC()
            }
        }

        // A finished annotation goes into the active terminal's prompt as text
        // naming the PNG, not as a clipboard paste: Claude Code reads the file
        // itself, and no Accessibility permission or synthetic ⌘V is involved.
        // Deliberately not submitted — you get to add the question.
        browserAnnotationObserver = NotificationCenter.default.addObserver(
            forName: .floatnoteBrowserAnnotationReady, object: nil, queue: .main
        ) { [weak self] note in
            guard let vm = self?.vm, let text = note.userInfo?["text"] as? String else { return }
            MainActor.assumeIsolated {
                guard let id = vm.activeTerminalId,
                      let session = TerminalSessions.shared.existing(id) else {
                    dbg("browser: annotation dropped — no live terminal")
                    return
                }
                session.view.send(txt: text + " ")
                vm.focusActiveTerminal()
                dbg("browser: annotation pasted into pane \(vm.terminalTabs.first { $0.id == id }?.label ?? "?")")
            }
        }

        // An agent that opens a page means to show it: the panel comes up on
        // its own rather than loading a page nobody can see.
        browserVisibilityObserver = NotificationCenter.default.addObserver(
            forName: .floatnoteBrowserRequestedVisible, object: nil, queue: .main
        ) { [weak self] _ in
            guard let vm = self?.vm else { return }
            MainActor.assumeIsolated {
                guard !vm.isBrowserVisible else { return }
                withAnimation(.easeInOut(duration: 0.18)) { vm.isBrowserVisible = true }
            }
        }

        // Terminal-scoped shortcuts: when keyboard focus is inside a terminal,
        // Cmd+N opens a new terminal, and Shift+Enter inserts a newline in the
        // input (so a TUI like Claude Code drops to the line below instead of
        // submitting). With focus elsewhere those keep their defaults.
        // Cmd+W is swallowed app-wide — it must never close the window (which
        // would take the terminal panel with it); tabs close only via ✕ / exit.
        terminalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let vm = self.vm,
                  let key = event.charactersIgnoringModifiers?.lowercased()
            else { return event }
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if mods == [.command] && key == "w" { return nil }
            // Cmd+. — the classic macOS cancel — shuts the voice up without
            // relying on the mic hearing you over its own playback.
            if mods == [.command] && key == "." {
                var stopped = false
                MainActor.assumeIsolated {
                    stopped = HandsfreeManager.shared.stopSpeakingFromKeyboard()
                }
                if stopped { return nil }
            }
            // Cmd+F → in-note find bar. Terminals keep their own keys, and the
            // board view has no text to search.
            if mods == [.command] && key == "f",
               TerminalSessions.shared.id(containing: NSApp.keyWindow?.firstResponder) == nil {
                var handled = false
                MainActor.assumeIsolated {
                    guard !BoardWindowController.shared.isBoardWindow(NSApp.keyWindow),
                          let tv = vm.editorCoordinator?.textView else { return }
                    tv.window?.makeFirstResponder(tv)
                    let action = NSMenuItem()
                    action.tag = NSTextFinder.Action.showFindInterface.rawValue
                    tv.performTextFinderAction(action)
                    handled = true
                }
                return handled ? nil : event
            }
            // Cmd+V with an IMAGE-ONLY clipboard always goes to the note. Nothing
            // else in the app can consume an image paste (a shell can't, and when
            // focus sits on a non-text view AppKit just drops Cmd+V), so routing
            // it here is unambiguous — and it makes screenshot paste work no
            // matter what has focus. Clipboards containing text fall through
            // untouched, so terminal/editor text paste behaves exactly as before.
            if mods == [.command] && key == "v" {
                var handled = false
                MainActor.assumeIsolated {
                    let pb = NSPasteboard.general
                    let hasText = !(pb.string(forType: .string) ?? "").isEmpty
                    let hasImage = pb.availableType(from: [.tiff, .png]) != nil
                    guard !BoardWindowController.shared.isBoardWindow(NSApp.keyWindow),
                          !hasText, hasImage,
                          let img = NSImage(pasteboard: pb),
                          let tv = vm.editorCoordinator?.textView as? BlockCaretTextView
                    else { return }
                    tv.window?.makeFirstResponder(tv)
                    tv.insertImage(img)
                    handled = true
                }
                if handled { return nil }
            }
            // Escape inside a terminal cancels Claude's turn. The transcript
            // has no other way to know: no hook fires, and the interrupt record
            // is not always written. The event is NOT swallowed — the terminal
            // still gets its escape.
            if mods.isEmpty, event.keyCode == 53 {
                MainActor.assumeIsolated {
                    if let id = TerminalSessions.shared.id(containing: NSApp.keyWindow?.firstResponder) {
                        TranscriptStore.shared.noteInterrupted(paneId: id)
                        vm.clearPaneActivity(id)
                    }
                }
                return event
            }
            // ⌘− / ⌘+ / ⌘0 resize the TRANSCRIPT text, from anywhere, while it is
            // on screen. Focus is almost always in the terminal when you want the
            // reading a notch bigger, and the terminal never sees ⌘ combinations,
            // so this cannot steal a key Claude Code wanted.
            if mods == [.command] || mods == [.command, .shift] {
                var handled = false
                MainActor.assumeIsolated {
                    guard vm.isTerminalVisible, vm.transcriptMode == .split else { return }
                    switch key {
                    case "-": TerminalFontMenuTarget.stepPanelText(-1); handled = true
                    case "=", "+": TerminalFontMenuTarget.stepPanelText(1); handled = true
                    case "0": TerminalFontMenuTarget.resetPanelText(); handled = true
                    default: break
                    }
                }
                if handled { return nil }
            }
            let isCmd = mods == [.command] && (key == "n" || key == "\r")
            let isShiftEnter = mods == [.shift] && key == "\r"
            guard isCmd || isShiftEnter,
                  let focusedId = TerminalSessions.shared.id(containing: NSApp.keyWindow?.firstResponder)
            else { return event }
            MainActor.assumeIsolated {
                if isShiftEnter {
                    // Shift+Enter → insert a newline without submitting. Send the
                    // Option/Meta+Return sequence (ESC + CR), which line editors
                    // like Claude Code interpret as "newline", not "submit".
                    TerminalSessions.shared.existing(focusedId)?.view.send(txt: "\u{1b}\r")
                } else if key == "n" {
                    withAnimation(.easeInOut(duration: 0.18)) { vm.addTerminal() }
                } else {
                    // Cmd+Enter → line feed (Ctrl+J): newline without submitting.
                    TerminalSessions.shared.existing(focusedId)?.view.send(txt: "\n")
                }
            }
            return nil // swallow the event — fully handled
        }

        // A shell that exits on its own (user typed `exit`) closes its pane.
        terminalExitObserver = NotificationCenter.default.addObserver(
            forName: .floatnoteTerminalExited, object: nil, queue: .main
        ) { [weak self] note in
            guard let vm = self?.vm, let id = note.object as? UUID,
                  vm.terminalTabs.contains(where: { $0.id == id }) else { return }
            MainActor.assumeIsolated {
                withAnimation(.easeInOut(duration: 0.18)) { vm.closeTerminal(id) }
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate (Claude hook notifications)

    /// Show the banner even while FloatNote is frontmost ("always notify").
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Click → activate the app and jump to the terminal the event came from.
    /// The tab is re-resolved by path at click time (ids can go stale); a
    /// closed tab degrades to just activating the app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let path = response.notification.request.content.userInfo["terminalPath"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                if let path,
                   let vm = self.vm,
                   let tab = vm.terminalTabs.first(where: { $0.path == path }) {
                    vm.selectTerminal(tab.id)   // chip + note navigation + focus
                    vm.isTerminalVisible = true // chips with no folder mapping don't auto-show
                }
            }
            completionHandler()
        }
    }

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
}

// MARK: - Window Accessor

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.title = "FloatNote"
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.toolbar = nil
                Self.applyMinSize(window: window, sidebarCollapsed: false)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Small global minimum so the window never collapses to nothing;
    /// responsive auto-hide of the sidebar lives in EditorView via GeometryReader.
    static func applyMinSize(window: NSWindow, sidebarCollapsed: Bool) {
        window.minSize = NSSize(width: 240, height: 180)
    }
}

// MARK: - Format Actions

enum FormatAction: Equatable {
    case bold, italic, underline, heading1, heading2, heading3, bulletList, checklist, link, divider, body
}

// MARK: - Theme

enum AppTheme: String, CaseIterable, Identifiable {
    case obsidian, paper, sepia, midnight, solarized

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .obsidian: return "Obsidian"
        case .paper: return "Paper"
        case .sepia: return "Sepia"
        case .midnight: return "Midnight"
        case .solarized: return "Solarized"
        }
    }

    var iconName: String {
        switch self {
        case .obsidian: return "moon.fill"
        case .paper: return "sun.max.fill"
        case .sepia: return "leaf.fill"
        case .midnight: return "moon.stars.fill"
        case .solarized: return "circle.lefthalf.filled"
        }
    }

    var swiftUIScheme: ColorScheme {
        switch self {
        case .obsidian, .midnight, .solarized: return .dark
        case .paper, .sepia: return .light
        }
    }

    /// Background for the NSTextView editor surface.
    var editorBackgroundNS: NSColor {
        switch self {
        case .obsidian: return NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
        case .paper:    return NSColor(calibratedRed: 0.995, green: 0.995, blue: 0.993, alpha: 1.0)
        case .sepia:    return NSColor(calibratedRed: 0.96, green: 0.92, blue: 0.83, alpha: 1.0)
        case .midnight: return NSColor(calibratedRed: 0.102, green: 0.094, blue: 0.086, alpha: 1.0)
        case .solarized: return NSColor(srgbRed: 0.0275, green: 0.2118, blue: 0.2588, alpha: 1.0) // base02 #073642
        }
    }

    /// Primary body text color in the editor.
    var editorTextNS: NSColor {
        switch self {
        case .obsidian: return NSColor(calibratedWhite: 0.88, alpha: 1.0)
        case .paper:    return NSColor(calibratedWhite: 0.13, alpha: 1.0)
        case .sepia:    return NSColor(calibratedRed: 0.36, green: 0.25, blue: 0.15, alpha: 1.0)
        case .midnight: return NSColor(calibratedRed: 0.83, green: 0.81, blue: 0.76, alpha: 1.0)
        case .solarized: return NSColor(srgbRed: 0.5137, green: 0.5804, blue: 0.5882, alpha: 1.0) // base0 #839496
        }
    }

    var editorCaretNS: NSColor {
        switch self {
        case .obsidian: return .white
        case .paper:    return NSColor(calibratedWhite: 0.1, alpha: 1.0)
        case .sepia:    return NSColor(calibratedRed: 0.36, green: 0.25, blue: 0.15, alpha: 1.0)
        case .midnight: return NSColor(calibratedRed: 0.79, green: 0.66, blue: 0.43, alpha: 1.0)
        case .solarized: return NSColor(srgbRed: 0.5765, green: 0.6314, blue: 0.6314, alpha: 1.0) // base1 #93a1a1
        }
    }

    /// Window background (used for sepia tint; other themes fall back to system).
    var windowNSColor: NSColor {
        switch self {
        case .obsidian: return NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
        case .paper:    return NSColor(calibratedRed: 0.99, green: 0.99, blue: 0.99, alpha: 1.0)
        case .sepia:    return NSColor(calibratedRed: 0.96, green: 0.92, blue: 0.83, alpha: 1.0)
        case .midnight: return NSColor(calibratedRed: 0.102, green: 0.094, blue: 0.086, alpha: 1.0)
        case .solarized: return NSColor(srgbRed: 0.0275, green: 0.2118, blue: 0.2588, alpha: 1.0) // base02 #073642
        }
    }

    /// Sidebar / toolbar chrome background. `.bar` material on non-sepia, a
    /// warm tinted color on sepia so chrome matches the editor surface.
    @ViewBuilder
    var chromeBackground: some View {
        switch self {
        case .sepia:
            Color(red: 0.93, green: 0.88, blue: 0.78)
        case .midnight:
            Color(red: 0.082, green: 0.074, blue: 0.066)
        case .solarized:
            Color(red: 0.0, green: 0.169, blue: 0.212) // base03 #002b36 — slightly darker than the editor
        default:
            Rectangle().fill(.bar)
        }
    }
}

// MARK: - Tab Model

struct TabData: Codable {
    var id: String
    var title: String
    var noteGuid: String?  // legacy field, ignored
    var html: String
    var recordingPath: String?  // legacy single pointer — kept in sync (= newest) for MCP/old readers
    var recordingPaths: [String]? = nil  // all recordings of the note, chronological; nil in old files
    var folderId: String?  // optional — nil means "root / ungrouped"
    var localPath: String? = nil  // optional per-note terminal-folder override; nil = inherit from folder chain
    var jobStatus: String? = nil  // busy label while a job runs on this note ("Summarizing…", MCP-set, …); nil = idle
    var jobStatusAt: Double? = nil  // epoch seconds the status was last set — drives the 30-min stale TTL
    var isBoardOpen: Bool? = nil  // was the Excalidraw board showing when this note was last left? nil/absent = no
}

class NoteTab: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    var html: String = ""
    var lastSavedHTML: String = ""
    /// All recordings of this note, chronological (newest last).
    @Published var recordingPaths: [String] = []
    @Published var folderId: UUID? = nil
    /// Per-note terminal-folder override. Non-nil = this note pins its own
    /// working directory, taking precedence over its folder chain. nil = inherit.
    @Published var localPath: String? = nil
    /// Number of unchecked (`☐`) checklist items in this note. Drives the sidebar badge.
    @Published var uncheckedCount: Int = 0
    /// Whether this note was showing its Excalidraw board rather than the text
    /// editor when it was last left. Restored on the next visit so the board
    /// stays "the view" for notes that are really diagrams.
    var isBoardOpen: Bool = false
    /// Busy label while a job (transcribe/summarize, or an external MCP-set job)
    /// runs on this note. nil = idle. Drives the blue sidebar pulse.
    @Published var jobStatus: String? = nil
    var jobStatusAt: Date? = nil

    /// Statuses older than this are considered stale (crashed agent, leftover
    /// flag) and ignored/swept. Long-running MCP jobs re-set to stay alive.
    static let jobStatusTTL: TimeInterval = 30 * 60

    /// True while a non-expired job status is present.
    var isJobActive: Bool {
        guard jobStatus != nil else { return false }
        guard let at = jobStatusAt else { return true }
        return Date().timeIntervalSince(at) < NoteTab.jobStatusTTL
    }

    init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
    }

    /// Count unchecked checkbox glyphs (`☐`) in a piece of text. Works on both the
    /// stored HTML (which keeps `☐` literal) and the live editor's plain string.
    static func countUnchecked(in text: String) -> Int {
        var count = 0
        for ch in text where ch == "☐" { count += 1 }
        return count
    }

    /// Recompute `uncheckedCount` from this note's stored HTML.
    func recomputeUncheckedFromHTML() {
        uncheckedCount = NoteTab.countUnchecked(in: html)
    }

    func toData() -> TabData {
        TabData(
            id: id.uuidString,
            title: title,
            html: html,
            recordingPath: recordingPaths.last,
            recordingPaths: recordingPaths,
            folderId: folderId?.uuidString,
            localPath: localPath,
            jobStatus: jobStatus,
            jobStatusAt: jobStatusAt?.timeIntervalSince1970,
            isBoardOpen: isBoardOpen
        )
    }

    static func from(_ data: TabData) -> NoteTab {
        let tab = NoteTab(id: UUID(uuidString: data.id) ?? UUID(), title: data.title)
        tab.html = data.html
        // Migrate legacy single-recording notes on the fly.
        tab.recordingPaths = data.recordingPaths ?? data.recordingPath.map { [$0] } ?? []
        if let fid = data.folderId { tab.folderId = UUID(uuidString: fid) }
        tab.localPath = data.localPath
        tab.jobStatus = data.jobStatus
        tab.jobStatusAt = data.jobStatusAt.map { Date(timeIntervalSince1970: $0) }
        tab.isBoardOpen = data.isBoardOpen ?? false
        tab.recomputeUncheckedFromHTML()
        return tab
    }
}

// MARK: - Folder model

struct FolderData: Codable {
    var id: String
    var name: String
    var isExpanded: Bool
    var isTrashed: Bool? = nil  // optional for backwards-compat with older JSON
    var parentId: String? = nil // optional; nil = root (back-compat with flat JSON)
    var localPath: String? = nil // optional; the linked local directory (a "project"). nil = plain folder.
}

class Folder: Identifiable, ObservableObject {
    let id: UUID
    @Published var name: String
    @Published var isExpanded: Bool
    @Published var isTrashed: Bool
    /// Parent folder for nesting. `nil` = root-level folder.
    @Published var parentId: UUID?
    /// Linked local directory. A folder with a non-nil `localPath` is a
    /// "project": its notes inherit this path as their terminal working dir.
    /// `nil` = plain folder (no terminal).
    @Published var localPath: String?

    init(id: UUID = UUID(), name: String, isExpanded: Bool = true, isTrashed: Bool = false,
         parentId: UUID? = nil, localPath: String? = nil) {
        self.id = id
        self.name = name
        self.isExpanded = isExpanded
        self.isTrashed = isTrashed
        self.parentId = parentId
        self.localPath = localPath
    }

    func toData() -> FolderData {
        FolderData(id: id.uuidString, name: name, isExpanded: isExpanded, isTrashed: isTrashed,
                   parentId: parentId?.uuidString, localPath: localPath)
    }

    static func from(_ data: FolderData) -> Folder {
        Folder(
            id: UUID(uuidString: data.id) ?? UUID(),
            name: data.name,
            isExpanded: data.isExpanded,
            isTrashed: data.isTrashed ?? false,
            parentId: data.parentId.flatMap { UUID(uuidString: $0) },
            localPath: data.localPath
        )
    }
}

/// Sentinel folder ID used to mark a note as "loose-trashed" (trashed by itself,
/// not via a containing folder). Notes in this virtual folder are rendered
/// inside the sidebar's Trash section. The Trash itself is not stored as a
/// `Folder` — it's synthesized at render time.
let TRASH_FOLDER_ID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

/// One terminal in the panel's tab bar. Identified for dedup by `path` (the
/// shell's working directory); `label` is the folder name shown on the chip.
struct TerminalTab: Identifiable, Equatable, Codable {
    let id: UUID
    let path: String
    let label: String
    /// True for a pane the user explicitly added (toolbar + / Cmd+N) rather than
    /// one opened by note routing. Such a pane always starts a fresh agent
    /// session instead of continuing one another pane may already be running.
    var freshClaude: Bool = false
    /// The note this pane belongs to. Several panes can share a project
    /// directory, so path alone no longer identifies "the note's terminal" —
    /// this binding does. At most one pane is bound to a given note (the most
    /// recent binding wins); nil = unbound, reachable only by path fallback.
    var noteId: UUID? = nil
    /// Which Claude Code conversation this pane is running, learned from the
    /// hook (`session_id` / `transcript_path`, stamped in `checkClaudeEvents`).
    /// `TerminalTab.path` cannot identify a conversation — several panes share
    /// one project directory and `freshClaude` deliberately starts a second
    /// `.jsonl` in the same store. Persisted, so a restored pane shows the
    /// right transcript before any new hook event arrives; nil = fall back to
    /// the provisional resolution ladder.
    var claudeSessionId: String? = nil
    var claudeTranscriptPath: String? = nil
}

// MARK: - ViewModel

@MainActor
class EditorViewModel: ObservableObject {
    @Published var status: String = "Loading..."
    @Published var isSaving = false
    @Published var charCount: Int = 0
    @Published var isPinned: Bool = false
    /// Chrome visibility captured at pin time, restored on unpin.
    private var prePinSidebarCollapsed: Bool?
    private var prePinTerminalVisible: Bool?
    /// Window frame captured at pin time, restored on unpin.
    private var prePinWindowFrame: NSRect?
    /// Compact floating-note size applied when pinning.
    static let pinnedWindowSize = NSSize(width: 300, height: 600)
    @Published var theme: AppTheme = {
        if let raw = UserDefaults.standard.string(forKey: "fn.theme"),
           let t = AppTheme(rawValue: raw) { return t }
        return .obsidian
    }() {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "fn.theme")
            BoardWindowController.shared.applyTheme(theme)
            // Repaint the terminal panel HERE, not from an .onChange: the palette
            // is resolved by reading `fn.theme` back out of UserDefaults, and a
            // view-side observer can run before this line has written it — which
            // left the terminal and the transcript one theme behind.
            TerminalSessions.shared.applyAppearance()
        }
    }
    @Published var isSidebarCollapsed: Bool = UserDefaults.standard.bool(forKey: "fn.sidebarCollapsed") {
        didSet { UserDefaults.standard.set(isSidebarCollapsed, forKey: "fn.sidebarCollapsed") }
    }
    /// True while the sidebar was closed by the auto-hide threshold (not the user).
    /// Lets us re-open on resize without overriding a manual collapse.
    /// Persisted, because it is the receipt for an automatic collapse. In memory
    /// only, a relaunch forgot that the app (not the user) had hidden the
    /// sidebar — so the collapse never got undone and the sidebar was gone for
    /// good, with only the toolbar toggle to bring it back.
    @Published var isSidebarAutoHidden: Bool =
        UserDefaults.standard.bool(forKey: "fn.sidebarAutoHidden") {
        didSet { UserDefaults.standard.set(isSidebarAutoHidden, forKey: "fn.sidebarAutoHidden") }
    }
    /// User-resizable sidebar width, persisted across launches.
    @Published var sidebarWidth: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "fn.sidebarWidth")
        return v > 0 ? CGFloat(v) : 220
    }() {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: "fn.sidebarWidth") }
    }
    /// Whether the embedded terminal panel is shown on the right edge.
    @Published var isTerminalVisible: Bool = UserDefaults.standard.bool(forKey: "fn.terminalVisible") {
        didSet {
            UserDefaults.standard.set(isTerminalVisible, forKey: "fn.terminalVisible")
            guard isTerminalVisible != oldValue else { return }
            syncTranscriptBinding()
        }
    }
    /// Terminals shown in the panel, one visible at a time via the tab bar. Each
    /// tab maps to a mounted SwiftTermContainer (and its shell process), kept
    /// alive across re-renders. Hiding the panel only unmounts the view — the
    /// shells survive (hide ≠ kill). Driven by the active note's folder route.
    @Published var terminalTabs: [TerminalTab] = [] {
        didSet { saveTerminalTabs() }
    }
    /// The currently visible terminal tab.
    @Published var activeTerminalId: UUID? {
        didSet {
            saveTerminalTabs()
            guard activeTerminalId != oldValue else { return }
            syncTranscriptBinding()
        }
    }
    /// True while restoring panes at launch, so the restore doesn't write back
    /// over the very state it is reading.
    private var isRestoringTerminals = false
    /// Which pane each note last used. `TerminalTab.noteId` answers "whose pane
    /// is this" for chip → note; this answers "which pane does this note want",
    /// which is what has to stay stable when panes are reordered or when
    /// several notes share one project directory. Persisted with the panes.
    var terminalForNote: [UUID: UUID] = [:] {
        didSet { saveTerminalTabs() }
    }
    /// Terminal chip currently being dragged along the tab bar.
    @Published var draggingTerminalId: UUID?

    /// Move the dragged pane to sit where `destId` is. Hover-swap, matching how
    /// note tabs reorder; the new order persists like any other pane change.
    func moveTerminal(from sourceId: UUID, to destId: UUID) {
        guard sourceId != destId,
              let from = terminalTabs.firstIndex(where: { $0.id == sourceId }),
              let to = terminalTabs.firstIndex(where: { $0.id == destId }) else { return }
        dbg("moveTerminal before: " + terminalTabs.map { "\($0.label)/note=\($0.noteId?.uuidString.prefix(8) ?? "nil")" }.joined(separator: ", "))
        withAnimation(.easeInOut(duration: 0.18)) {
            terminalTabs.move(fromOffsets: IndexSet(integer: from),
                              toOffset: to > from ? to + 1 : to)
        }
        dbg("moveTerminal after:  " + terminalTabs.map { "\($0.label)/note=\($0.noteId?.uuidString.prefix(8) ?? "nil")" }.joined(separator: ", "))
    }

    /// Most-recently-active note per folder, so selecting a terminal tab can return
    /// the user to where they last were in that folder (reverse of folder routing).
    private var lastActiveNotePerFolder: [UUID: UUID] = [:]

    /// Persisted width of the terminal panel.
    @Published var terminalWidth: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "fn.terminalWidth")
        return v > 0 ? CGFloat(v) : 460
    }() {
        didSet { UserDefaults.standard.set(Double(terminalWidth), forKey: "fn.terminalWidth") }
    }

    /// Narrowest the panel may get (also the resize-handle minimum).
    static let minTerminalColumnWidth: CGFloat = 200

    /// Current window content width, fed in by `EditorView` from its
    /// GeometryReader. Used to keep the terminal panel inside the window.
    /// Published: the panel budget is derived from it, so a window resize has to
    /// re-run the layout. As a plain property it was written on every resize and
    /// read by nobody until the next unrelated redraw.
    @Published var windowContentWidth: CGFloat = 0

    /// Horizontal room the terminal panel may occupy: window width minus the
    /// sidebar (when open) and the resize handles flanking the panel.
    /// Room the note itself always keeps. A panel that ate the editor would
    /// also eat the handle you'd drag back with.
    static let editorFloorWidth: CGFloat = 260

    /// The widths the terminal and browser panels are actually rendered at.
    ///
    /// They used to be clamped independently, each against the OTHER's full
    /// width — so opening both in a window too narrow for both shrank BOTH to a
    /// sliver instead of taking the room off one. They now share one budget:
    /// stored widths when they fit, scaled in proportion when they don't. At
    /// launch, before the geometry reader has measured anything, the stored
    /// widths are used as-is — clamping against a window width of 0 is what
    /// made a relaunch come up with two hairline panels.
    func panelWidths() -> (terminal: CGFloat, browser: CGFloat) {
        let showTerminal = isTerminalVisible && !terminalTabs.isEmpty
        let showBrowser = isBrowserVisible
        guard showTerminal || showBrowser else { return (0, 0) }
        let wantTerminal = showTerminal ? terminalWidth : 0
        let wantBrowser = showBrowser ? browserWidth : 0
        // Before the geometry reader has measured anything, clamp against the
        // SCREEN rather than handing back the stored widths raw: an unclamped
        // first pass is what let the window grow past the display and stay there.
        guard windowContentWidth > 0 else {
            let screen = NSScreen.main?.visibleFrame.width ?? 1440
            let ceiling = max(320, screen - Self.editorFloorWidth - 40)
            let wanted = wantTerminal + wantBrowser
            guard wanted > ceiling, wanted > 0 else { return (wantTerminal, wantBrowser) }
            let scale = ceiling / wanted
            return ((wantTerminal * scale).rounded(), (wantBrowser * scale).rounded())
        }
        let sidebar: CGFloat = isSidebarCollapsed ? 0 : sidebarWidth + 6
        let handles: CGFloat = (showTerminal ? 10 : 0) + (showBrowser ? 10 : 0)
        let floor: CGFloat = isEditorVisible ? Self.editorFloorWidth : 0
        let budget = max(0, windowContentWidth - sidebar - handles - floor)
        let wanted = wantTerminal + wantBrowser
        guard wanted > 0 else { return (0, 0) }
        // With the note hidden there is no flexible column left to absorb the
        // slack, so an HStack of fixed-width panels centred itself and left a
        // dead margin down the left edge — the terminal looked locked in place,
        // unable to reach the window's edge. Stretch as well as shrink then:
        // with no editor, the panels take the WHOLE budget, in proportion.
        guard wanted > budget || !isEditorVisible else { return (wantTerminal, wantBrowser) }
        let scale = budget / wanted
        guard showTerminal, showBrowser else {
            return (showTerminal ? budget : 0, showBrowser ? budget : 0)
        }
        // Spend the rounding remainder on the browser so the pair adds up to
        // the budget exactly; a leftover point reads as a misaligned edge.
        let terminal = (wantTerminal * scale).rounded()
        return (terminal, budget - terminal)
    }

    /// While the note column is hidden the panels are RENDERED filling the
    /// whole budget, which is wider than their stored widths. Write the
    /// rendered widths back, so a drag on a resize handle moves the edge with
    /// the cursor instead of at the stretch factor, and so the proportion the
    /// user dragged them to survives a window resize. The pre-fill widths are
    /// kept once, to be handed back when the note returns.
    func normalizeFilledPanelWidths() {
        guard !isEditorVisible, windowContentWidth > 0 else { return }
        let filled = panelWidths()
        guard filled.terminal > 0 || filled.browser > 0 else { return }
        if widthsBeforeEditorHidden == nil {
            widthsBeforeEditorHidden = (terminalWidth, browserWidth)
        }
        if showsTerminalPanel, filled.terminal > 0 { terminalWidth = filled.terminal }
        if isBrowserVisible, filled.browser > 0 { browserWidth = filled.browser }
    }

    var showsTerminalPanel: Bool { isTerminalVisible && !terminalTabs.isEmpty }

    /// Total width the two panels may occupy together.
    func panelBudget() -> CGFloat {
        guard windowContentWidth > 0 else { return 3200 }
        let sidebar: CGFloat = isSidebarCollapsed ? 0 : sidebarWidth + 6
        let handles: CGFloat = 20
        let floor: CGFloat = isEditorVisible ? Self.editorFloorWidth : 0
        return max(320, windowContentWidth - sidebar - handles - floor)
    }

    /// Resize the terminal panel, taking the difference out of the browser when
    /// the two would exceed the budget.
    ///
    /// Without the push, a drag on a pair of panels that already filled the
    /// window did nothing visible: `panelWidths()` simply scaled both back down
    /// in proportion, so the panel you were dragging ended up the same width it
    /// started. A drag has to move space from one side to the other.
    func setTerminalWidth(_ proposed: CGFloat) {
        let budget = panelBudget()
        let width = min(proposed, budget - (isBrowserVisible ? 280 : 0))
        terminalWidth = max(Self.minTerminalColumnWidth, width)
        guard isBrowserVisible, terminalWidth + browserWidth > budget else { return }
        browserWidth = max(280, budget - terminalWidth)
    }

    func setBrowserWidth(_ proposed: CGFloat) {
        let budget = panelBudget()
        let terminalOpen = isTerminalVisible && !terminalTabs.isEmpty
        let width = min(proposed, budget - (terminalOpen ? Self.minTerminalColumnWidth : 0))
        browserWidth = max(280, width)
        guard terminalOpen, terminalWidth + browserWidth > budget else { return }
        terminalWidth = max(Self.minTerminalColumnWidth, budget - browserWidth)
    }

    /// Drag ceilings: each panel may grow into the editor's slack, never into
    /// the other panel's stored width.
    func maxTerminalWidth() -> CGFloat {
        let sidebar: CGFloat = isSidebarCollapsed ? 0 : sidebarWidth + 6
        let browser: CGFloat = isBrowserVisible ? browserWidth + 10 : 0
        guard windowContentWidth > 0 else { return 1600 }
        return max(Self.minTerminalColumnWidth,
                   windowContentWidth - sidebar - browser - 10
                       - (isEditorVisible ? Self.editorFloorWidth : 0))
    }

    func maxBrowserWidth() -> CGFloat {
        let sidebar: CGFloat = isSidebarCollapsed ? 0 : sidebarWidth + 6
        let terminal: CGFloat = (isTerminalVisible && !terminalTabs.isEmpty) ? terminalWidth + 10 : 0
        guard windowContentWidth > 0 else { return 1600 }
        return max(280, windowContentWidth - sidebar - terminal - 10
                       - (isEditorVisible ? Self.editorFloorWidth : 0))
    }

    func availablePanelWidth() -> CGFloat {
        let sidebar: CGFloat = isSidebarCollapsed ? 0 : sidebarWidth + 6
        let browser: CGFloat = isBrowserVisible ? browserWidth + 6 : 0
        return max(0, windowContentWidth - sidebar - browser - 10)
    }

    /// Room the browser panel may occupy: everything the sidebar and the
    /// terminal panel are not using. Same rule as `availablePanelWidth` —
    /// neither panel may be rendered wider than the window it sits in.
    func availableBrowserWidth() -> CGFloat {
        let sidebar: CGFloat = isSidebarCollapsed ? 0 : sidebarWidth + 6
        let terminal: CGFloat = (isTerminalVisible && !terminalTabs.isEmpty) ? terminalWidth + 6 : 0
        return max(0, windowContentWidth - sidebar - terminal - 10)
    }

    /// Make the active terminal's view first responder. Focus moves only at
    /// discrete presentation events (note switch, chip tap, toggle, new tab) —
    /// clicking into the editor keeps focus there until the next such event.
    func focusActiveTerminal() {
        guard let id = activeTerminalId else { return }
        focusTerminal(id)
    }

    /// The panel/view may still be mounting when focus is requested (SwiftUI
    /// needs a tick after `isTerminalVisible` flips, and sessions are created
    /// lazily on mount), so retry briefly. Bails if the tab closed or another
    /// terminal became active meanwhile.
    private func focusTerminal(_ id: UUID, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            MainActor.assumeIsolated {
                guard self.activeTerminalId == id,
                      self.terminalTabs.contains(where: { $0.id == id }) else { return }
                if let session = TerminalSessions.shared.existing(id),
                   let window = session.view.window {
                    window.makeFirstResponder(session.view)
                } else if attempt < 8 {
                    self.focusTerminal(id, attempt: attempt + 1)
                }
            }
        }
    }

    /// Put keyboard focus back in the note editor.
    func focusEditor() {
        guard let tv = editorCoordinator?.textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    /// Restart every live pane after the toolbar changes its selected agent.
    /// TerminalTab state is untouched, so routes, labels, ordering and note
    /// bindings survive while each shell relaunches in its original directory.
    func restartTerminalsForAgentChange() {
        guard !terminalTabs.isEmpty else { return }
        NotificationCenter.default.post(name: .floatnoteTerminalReset, object: nil)
        focusActiveTerminal()
    }

    /// Hide the panel but keep all sessions mounted/alive (hide ≠ kill).
    func hideTerminal() { isTerminalVisible = false; normalizeFilledPanelWidths() }
    func toggleTerminal() { isTerminalVisible ? hideTerminal() : applyTerminalRouteForActiveNote() }

    /// Activate the tab for `path` if one exists, else create it. Opens the panel.
    func switchToRoute(path: String, label: String) {
        // Prefer the pane bound to this note, so a project with several panes
        // returns each note to its own. Fall back to any pane on the path (the
        // single-pane case, and notes that share a project without their own
        // pane), and only then create one — bound to the note that opened it.
        // Resolution order, most specific first. Deliberately NOT "the first pane
        // on this path" — that made the mapping depend on tab order, so dragging
        // a chip handed the note a different terminal.
        let chosen: UUID
        if let remembered = activeTabId.flatMap({ terminalForNote[$0] }),
           terminalTabs.contains(where: { $0.id == remembered && $0.path == path }) {
            chosen = remembered                                     // this note's own pane
        } else if let own = terminalTabs.first(where: { $0.noteId == activeTabId && $0.path == path }) {
            chosen = own.id                                         // pane that claims this note
        } else if let free = terminalTabs.first(where: { $0.path == path && $0.noteId == nil }) {
            chosen = free.id                                        // an unclaimed pane (e.g. restored)
        } else if let existing = terminalTabs.first(where: { $0.path == path }) {
            chosen = existing.id                                    // share one
        } else {
            let id = UUID()
            terminalTabs.append(TerminalTab(id: id, path: path, label: label, noteId: activeTabId))
            chosen = id
        }
        activeTerminalId = chosen
        if let note = activeTabId {
            terminalForNote[note] = chosen
            // Re-home the pane on the note that is using it NOW — not only when
            // it has no owner at all. A claim goes stale on its own: a `+` fork
            // hands the note to the new pane, and the old one then adopts
            // whatever note its folder happens to list first. That wrong note
            // is persisted, so its chip kept opening it forever and nothing in
            // normal use ever corrected the binding. The note you are working
            // in is the better answer, every time.
            if let i = terminalTabs.firstIndex(where: { $0.id == chosen }),
               terminalTabs[i].noteId != note {
                terminalTabs[i].noteId = note
            }
        }
        isTerminalVisible = true
    }

    /// Last time each pane's Claude session FILE grew. The transcript only tails
    /// the pane you are looking at, so this is the one signal that exists for the
    /// others: Claude writes a record for every step it takes, and a file that is
    /// growing means a turn is running.
    @Published var paneActivity: [UUID: Date] = [:]
    private var paneFileSizes: [UUID: UInt64] = [:]

    /// Long enough to ride out a slow tool call that emits nothing, short enough
    /// that a finished turn stops spinning before you wonder about it.
    static let paneWorkingWindow: TimeInterval = 25

    /// Sweep the panes' session files. Cheap: one `stat` per open pane, on the
    /// existing 2s timer.
    func checkPaneActivity() {
        for tab in terminalTabs {
            guard let path = tab.claudeTranscriptPath,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value else { continue }
            defer { paneFileSizes[tab.id] = size }
            guard let previous = paneFileSizes[tab.id] else { continue }
            if size > previous { paneActivity[tab.id] = Date() }
        }
    }

    /// A pane is working while its file is still growing — unless a hook, or an
    /// escape, has already said the turn is over.
    func isPaneWorking(_ id: UUID, now: Date = Date()) -> Bool {
        guard let last = paneActivity[id] else { return false }
        return now.timeIntervalSince(last) < Self.paneWorkingWindow
    }

    func clearPaneActivity(_ id: UUID) { paneActivity[id] = nil }

    /// The pane bound to this note, if one is open. Drives the sidebar's terminal
    /// glyph — "this note has a shell running against it" is worth seeing from
    /// the list, without opening the note to find out.
    func terminalTab(forNote id: UUID) -> TerminalTab? {
        terminalTabs.first { $0.noteId == id }
    }

    /// Bind `terminalId` to `noteId`, clearing any other pane's claim on that
    /// note. One note ↔ at most one pane keeps route resolution unambiguous.
    private func bindTerminal(_ terminalId: UUID, toNote noteId: UUID?) {
        guard let noteId else { return }
        for i in terminalTabs.indices {
            if terminalTabs[i].noteId == noteId { terminalTabs[i].noteId = nil }
            if terminalTabs[i].id == terminalId { terminalTabs[i].noteId = noteId }
        }
    }

    /// Expand `~`, trim whitespace; returns nil for nil/empty. Central helper so
    /// stored paths (absolute from the picker, or `~`-form from migration) resolve
    /// consistently everywhere.
    private func expandedPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return expanded.isEmpty ? nil : expanded
    }

    /// Where a note's terminal directory comes from.
    enum RouteSource: Equatable { case own, inherited, none }

    /// Reverse of the route: the (non-trashed) project folder whose linked
    /// `localPath` resolves to `path`. Used to navigate from a terminal chip back
    /// to its note. Override-only paths that match no folder return nil (the chip
    /// then leaves the active note untouched — no ping-pong).
    func folderForTerminalPath(_ path: String) -> Folder? {
        for folder in folders where !folder.isTrashed {
            if let p = expandedPath(folder.localPath), p == path { return folder }
        }
        return nil
    }

    /// The note to land on when entering `folder` via its terminal: the last note
    /// the user had open anywhere in the folder's subtree, else the folder's own
    /// first note.
    private func noteToActivate(forTerminalFolder folder: Folder) -> NoteTab? {
        if let lastId = lastActiveNotePerFolder[folder.id],
           let last = tabs.first(where: { $0.id == lastId }),
           let lastFolderId = last.folderId,
           lastFolderId != TRASH_FOLDER_ID,
           isSelfOrDescendant(lastFolderId, of: folder.id) {
            return last
        }
        return tabs.first(where: { $0.folderId == folder.id })
    }

    /// Activate a terminal tab (user tapped its chip) and, if its path maps to a
    /// project folder, navigate to the related note. The resulting note→terminal
    /// route dedups to this same tab, so there is no ping-pong.
    func selectTerminal(_ id: UUID) {
        activeTerminalId = id
        focusActiveTerminal()
        syncTranscriptBinding()
        guard let tab = terminalTabs.first(where: { $0.id == id }) else { return }
        dbg("selectTerminal \(tab.label) noteId=\(tab.noteId?.uuidString.prefix(8) ?? "nil")")
        // A pane bound to a live note goes straight back to it. Pin the reverse
        // map to THIS pane first: several panes can share one project, and if
        // `terminalForNote` still pointed at a sibling, the note→terminal route
        // fired by `switchTab` would hand the note straight back to it — the
        // chip you tapped would lose to the last pane on the path.
        if let boundId = tab.noteId, let bound = tabs.first(where: { $0.id == boundId }),
           bound.folderId != TRASH_FOLDER_ID {
            terminalForNote[boundId] = id
            if bound.id != activeTabId { switchTab(bound.id) }
            return
        }
        // Unbound (or its note is gone): fall back to the folder's last note —
        // but only when no sibling pane already claims it. Navigating there
        // anyway is what made the second `floatnote` chip open the last one; and
        // stealing the note instead would just make the two chips trade it back
        // and forth on every tap. So an unclaimed note is adopted (the chip
        // gains a home), a claimed one leaves the editor alone and the tapped
        // pane simply becomes active.
        guard let folder = folderForTerminalPath(tab.path),
              let note = noteToActivate(forTerminalFolder: folder) else { return }
        if terminalTabs.contains(where: { $0.id != id && $0.noteId == note.id }) {
            dbg("selectTerminal \(tab.label): note claimed by another pane — staying put")
            return
        }
        bindTerminal(id, toNote: note.id)
        terminalForNote[note.id] = id
        saveTerminalTabs()
        if note.id != activeTabId { switchTab(note.id) }
    }

    // MARK: - Terminal pane persistence

    /// Open panes survive a quit. The *shells* can't — those die with the app —
    /// but the tabs, their working directories and their note bindings do, and
    /// each restored pane asks the selected agent to resume, so a relaunch lands
    /// back on the same projects with their conversations resumed when possible.
    private func saveTerminalTabs() {
        guard !isRestoringTerminals else { return }
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(terminalTabs) {
            defaults.set(data, forKey: "fn.terminalTabs")
        }
        let map = Dictionary(uniqueKeysWithValues:
            terminalForNote.map { ($0.key.uuidString, $0.value.uuidString) })
        defaults.set(map, forKey: "fn.terminalForNote")
        defaults.set(activeTerminalId?.uuidString, forKey: "fn.activeTerminalId")
    }

    /// Rebuild the pane list saved by the previous run. Call before the launch
    /// route is applied, so `switchToRoute` dedups onto a restored pane instead
    /// of opening a second one for the same project.
    func restoreTerminalTabs() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: "fn.terminalTabs"),
              let saved = try? JSONDecoder().decode([TerminalTab].self, from: data),
              !saved.isEmpty else { return }
        isRestoringTerminals = true
        defer { isRestoringTerminals = false }

        if let map = defaults.dictionary(forKey: "fn.terminalForNote") as? [String: String] {
            terminalForNote = Dictionary(uniqueKeysWithValues: map.compactMap { k, v in
                guard let n = UUID(uuidString: k), let t = UUID(uuidString: v) else { return nil }
                return (n, t)
            })
        }

        // Drop panes whose directory is gone (deleted or unmounted project).
        terminalTabs = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let raw = defaults.string(forKey: "fn.activeTerminalId"),
           let id = UUID(uuidString: raw),
           terminalTabs.contains(where: { $0.id == id }) {
            activeTerminalId = id
        } else {
            activeTerminalId = terminalTabs.first?.id
        }
        dbg("restored \(terminalTabs.count) terminal pane(s)")
    }

    /// Manual "+": a fresh tab at the active note's route, else HOME.
    func addTerminal() {
        let route = terminalRoute(for: activeTab)
        let id = UUID()
        terminalTabs.append(TerminalTab(id: id,
                                        path: route?.path ?? NSHomeDirectory(),
                                        label: route?.label ?? "terminal",
                                        freshClaude: true))
        // The pane the user just asked for becomes this note's pane, so
        // returning to the note comes back here rather than to the older one —
        // but the older pane KEEPS its own claim. Clearing it (which is what an
        // exclusive `bindTerminal` did) orphaned the terminal that was already
        // open: its chip had no note to navigate back to, and every route for
        // that note went to the new pane forever. `terminalForNote` is the
        // tie-breaker, so routing still prefers this one.
        if let note = activeTabId {
            if let i = terminalTabs.firstIndex(where: { $0.id == id }) {
                terminalTabs[i].noteId = note
            }
            terminalForNote[note] = id
        }
        activeTerminalId = id
        isTerminalVisible = true
        focusActiveTerminal()
    }

    /// The nearest non-trashed ancestor folder (the note's own folder included)
    /// with a non-empty `localPath`. Nil when none in the chain. Capped at 64
    /// hops so a corrupt parent cycle can never hang the walk.
    private func nearestLinkedFolder(startingAt folderId: UUID) -> Folder? {
        var currentId: UUID? = folderId
        var hops = 0
        while let cid = currentId, hops < 64 {
            hops += 1
            guard let folder = folders.first(where: { $0.id == cid }) else { break }
            if !folder.isTrashed, expandedPath(folder.localPath) != nil { return folder }
            currentId = folder.parentId
        }
        return nil
    }

    /// Resolve a note's terminal working directory, with provenance:
    ///   1. the note's own `localPath` override (wins), else
    ///   2. the NEAREST ancestor project folder's `localPath`, else
    ///   3. none.
    /// `label` is the terminal-tab label: the project folder's name when
    /// inherited, the path's last component for an override.
    func effectiveRoute(for tab: NoteTab?) -> (path: String, label: String, source: RouteSource) {
        guard let tab else { return ("", "", .none) }
        if let own = expandedPath(tab.localPath) {
            return (own, (own as NSString).lastPathComponent, .own)
        }
        if let folderId = tab.folderId,
           let folder = nearestLinkedFolder(startingAt: folderId),
           let path = expandedPath(folder.localPath) {
            return (path, folder.name, .inherited)
        }
        return ("", "", .none)
    }

    /// `effectiveRoute` for the active note — drives the toolbar folder chip.
    var activeRoute: (path: String, label: String, source: RouteSource) {
        effectiveRoute(for: activeTab)
    }

    /// Set the active note's own folder override, then re-resolve the terminal.
    func setNoteFolderOverride(_ path: String) {
        guard let tab = activeTab else { return }
        tab.localPath = path
        tabs = tabs
        saveTabsLocal()
        applyTerminalRouteForActiveNote()
    }

    /// Clear the active note's override (back to inheriting from its folder).
    func clearNoteFolderOverride() {
        guard let tab = activeTab else { return }
        tab.localPath = nil
        tabs = tabs
        saveTabsLocal()
        applyTerminalRouteForActiveNote()
    }

    /// Unlink whatever the active note's chip points at: its own override if it
    /// has one, otherwise the project folder it inherits from. No-op when there's
    /// nothing linked.
    func unlinkActiveRoute() {
        guard let tab = activeTab else { return }
        if tab.localPath != nil {
            clearNoteFolderOverride()
        } else if let fid = tab.folderId, let folder = nearestLinkedFolder(startingAt: fid) {
            unlinkFolder(folder.id)
        }
    }

    /// The terminal route for a note as `(path, label)`, or nil when unrouted.
    /// Thin wrapper over `effectiveRoute`; the rest of the terminal machinery
    /// (switchToRoute, dedup, applyTerminalRouteForActiveNote) is unchanged.
    func terminalRoute(for tab: NoteTab?) -> (path: String, label: String)? {
        let r = effectiveRoute(for: tab)
        if case .none = r.source { return nil }
        return (r.path, r.label)
    }

    /// Drive the terminal panel from the active note: route → open + switch/create
    /// that tab; no route → hide the panel (sessions survive).
    /// `focusTerminal: false` keeps focus in the editor (new-note creation —
    /// the user is about to type the title).
    func applyTerminalRouteForActiveNote(focusTerminal: Bool = true) {
        // Pinned = compact floating note: never auto-open the panel. Unpin
        // re-applies the route for whatever note is active then.
        if isPinned { return }
        if let route = terminalRoute(for: activeTab) {
            switchToRoute(path: route.path, label: route.label)
            if focusTerminal { focusActiveTerminal() }
        } else {
            // Don't strand focus on a hidden terminal — but leave it alone when
            // it was elsewhere (sidebar, find bar).
            let focusWasInTerminal =
                TerminalSessions.shared.id(containing: NSApp.keyWindow?.firstResponder) != nil
            hideTerminal()
            if focusWasInTerminal { focusEditor() }
        }
    }

    // MARK: - Transcript pane

    /// Which surface the terminal panel is showing. Deliberately NOT a
    /// visibility flag: the panel's own show/hide rules (route gate, pin stash)
    /// still decide whether anything is on screen at all.
    /// Split is the default: the pane is what the panel is FOR, and a terminal
    /// with no transcript beside it reads as the old panel.
    @Published var transcriptMode: TranscriptMode = {
        UserDefaults.standard.string(forKey: "fn.transcriptMode")
            .flatMap(TranscriptMode.init(rawValue:)) ?? .split
    }() {
        didSet {
            UserDefaults.standard.set(transcriptMode.rawValue, forKey: "fn.transcriptMode")
            syncTranscriptBinding()
        }
    }

    // MARK: - Browser panel

    /// A fourth column, right of the terminal: a tabbed `WKWebView` the agent in
    /// the terminal can read and drive over MCP. App-global, not per note —
    /// whichever pane's Claude opens a page, it lands here.
    @Published var isBrowserVisible: Bool = UserDefaults.standard.bool(forKey: "fn.browserVisible") {
        didSet { UserDefaults.standard.set(isBrowserVisible, forKey: "fn.browserVisible") }
    }

    @Published var browserWidth: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: "fn.browserWidth")
        return stored > 0 ? CGFloat(stored) : 520
    }() {
        didSet { UserDefaults.standard.set(Double(browserWidth), forKey: "fn.browserWidth") }
    }

    /// The note column can be hidden like the sidebar: with a terminal and a
    /// browser open, the note is often not what you are looking at, and 300pt of
    /// unread prose is worse than none. Never hidden with nothing to fall back
    /// on — the toggle is disabled unless a panel is up.
    @Published var isEditorVisible: Bool =
        UserDefaults.standard.object(forKey: "fn.editorVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isEditorVisible, forKey: "fn.editorVisible") }
    }

    var canHideEditor: Bool {
        (isTerminalVisible && !terminalTabs.isEmpty) || isBrowserVisible
    }

    /// Panel widths from before the note column was hidden. Hiding the note
    /// grows the panels into its column; showing it again has to give that room
    /// back, or the note reopens permanently pinned at its 260pt floor.
    private var widthsBeforeEditorHidden: (terminal: CGFloat, browser: CGFloat)?

    func toggleEditor() {
        guard canHideEditor || !isEditorVisible else { return }
        isEditorVisible.toggle()
        if isEditorVisible {
            if let prev = widthsBeforeEditorHidden {
                terminalWidth = prev.terminal
                browserWidth = prev.browser
                widthsBeforeEditorHidden = nil
            }
        } else {
            normalizeFilledPanelWidths()
        }
        dbg("editor: note column \(isEditorVisible ? "shown" : "hidden")")
    }

    /// Browser fills the window, everything else stands down. Deliberately NOT
    /// persisted: launching into a window that is nothing but a web page, with
    /// no note and no terminal in sight, looks like the app failed to start.
    @Published var isBrowserFullScreen = false

    func toggleBrowserFullScreen() {
        if !isBrowserVisible { isBrowserVisible = true }
        isBrowserFullScreen.toggle()
        dbg("browser: full screen \(isBrowserFullScreen ? "on" : "off")")
    }

    func toggleBrowser() {
        isBrowserVisible.toggle()
        // With the note hidden the remaining panel takes the closed one's room;
        // keep the stored widths on top of that so its handle still drags 1:1.
        normalizeFilledPanelWidths()
        dbg("browser: panel \(isBrowserVisible ? "shown" : "hidden")")
    }

    @Published var transcriptSplitFraction: Double = {
        let stored = UserDefaults.standard.double(forKey: "fn.transcriptSplitFraction")
        return stored > 0 ? stored : 0.6
    }() {
        didSet { UserDefaults.standard.set(transcriptSplitFraction, forKey: "fn.transcriptSplitFraction") }
    }

    func cycleTranscriptMode() {
        withAnimation(.easeInOut(duration: 0.16)) {
            transcriptMode = transcriptMode.next
        }
        dbg("transcript: mode → \(transcriptMode.rawValue)")
    }

    /// Point the store at the active pane — or at nothing, when the transcript
    /// isn't showing. Only the active pane tails; background panes keep their
    /// binding on `TerminalTab` but hold no file descriptor.
    func syncTranscriptBinding() {
        guard transcriptMode != .terminal, isTerminalVisible,
              let id = activeTerminalId,
              let tab = terminalTabs.first(where: { $0.id == id }) else {
            TranscriptStore.shared.unbind()
            return
        }
        TranscriptStore.shared.bind(to: tab)
    }

    /// Toggle hands-free voice. Everything that can turn it on goes through
    /// here — toolbar button, ⌘⇧M, menu item — so the route gate and its
    /// logging live in one place instead of being duplicated per affordance.
    /// Turning it *off* never needs a route.
    func toggleHandsfree() {
        let manager = HandsfreeManager.shared
        let hasRoute = terminalRoute(for: activeTab) != nil
        dbg("handsfree: toggle requested (enabled=\(manager.isEnabled), route=\(hasRoute))")
        guard hasRoute || manager.isEnabled else {
            // Nothing to talk to: no project folder is linked for this note.
            NSSound.beep()
            return
        }
        manager.toggle()
    }

    /// Close (kill) a single terminal session. Activates a neighbor; closing the
    /// last one hides the panel.
    func closeTerminal(_ id: UUID) {
        // Sessions are owned by TerminalSessions (not the SwiftUI view), so the
        // shell is killed only here on explicit close — never on hide.
        TerminalSessions.shared.close(id)
        terminalForNote = terminalForNote.filter { $0.value != id }
        guard let idx = terminalTabs.firstIndex(where: { $0.id == id }) else { return }
        terminalTabs.remove(at: idx)
        if activeTerminalId == id {
            activeTerminalId = terminalTabs.isEmpty ? nil
                : terminalTabs[min(idx, terminalTabs.count - 1)].id
        }
        if terminalTabs.isEmpty { isTerminalVisible = false }
    }

    // MARK: - Claude hook notifications

    /// Spool dir the Claude Code hook writes into (one JSON file per event).
    static let CLAUDE_EVENTS_DIR = NSHomeDirectory() + "/.floatnote-claude-events"
    /// Directory watcher on the spool, so hook events land immediately rather
    /// than on the next 2s tick. See `startClaudeEventWatcher()`.
    private var claudeEventWatcher: DispatchSourceFileSystemObject?

    /// Consume Claude Code hook events (Stop / Notification) dropped by
    /// ~/.claude/hooks/floatnote-notify.sh. Only events whose cwd matches an
    /// OPEN terminal tab produce a banner — claude runs in external terminals
    /// are silently dropped. Registered on the AppDelegate 2s timer.
    /// Which pane a hook event belongs to, and whether that is more than a
    /// guess. `cwd` alone is not an answer: several panes can each run their own
    /// Claude in one project directory, and matching on the path sent every
    /// event to whichever pane came first in the list — stamping it with the
    /// sibling's session id, which the transcript treats as authoritative and
    /// then never re-checks, so the pane silently showed the other
    /// conversation. The session id is the identity; an open fd settles a
    /// session nobody has claimed yet; a pane with no conversation of its own is
    /// the better guess when neither answers.
    private func paneForClaudeEvent(cwd: String, sessionId: String?,
                                    transcriptPath: String?,
                                    pidChain: [Int]) -> (tab: TerminalTab, identified: Bool)? {
        let onPath = terminalTabs.filter {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == cwd
        }
        guard let first = onPath.first else { return nil }
        if onPath.count == 1 { return (first, true) }
        if let sid = sessionId, !sid.isEmpty,
           let known = onPath.first(where: { $0.claudeSessionId == sid }) {
            return (known, true)
        }
        // The hook ran as a child of the pane's own shell, so the pane's shell
        // pid is somewhere up the chain it recorded. Exact, and free on this
        // side — no `lsof`, no guessing. This is the signal that actually
        // identifies a fork: the open-fd probe below cannot, because Claude does
        // not hold its session file open between turns and a subagent inherits
        // its parent session's descriptor.
        if !pidChain.isEmpty {
            let chain = Set(pidChain)
            if let match = onPath.first(where: { tab in
                guard let pid = TerminalSessions.shared.existing(tab.id)?.view.process.shellPid,
                      pid > 0 else { return false }
                return chain.contains(Int(pid))
            }) {
                return (match, true)
            }
        }
        // A session this app has not seen before, with siblings in the running:
        // ask the shells which one is holding the file open. Same probe the
        // transcript uses (~16ms), and only ever on this path.
        if let path = transcriptPath, !path.isEmpty {
            let store = (path as NSString).deletingLastPathComponent
            for tab in onPath {
                guard let pid = TerminalSessions.shared.existing(tab.id)?.view.process.shellPid,
                      pid > 0 else { continue }
                if TranscriptResolver.openTranscript(shellPid: pid, storeDir: store) == path {
                    return (tab, true)
                }
            }
        }
        return (onPath.first(where: { $0.claudeSessionId == nil }) ?? first, false)
    }

    /// Claude Code sends a `Notification` for two different things: "I need your
    /// permission to use X" (the turn really is parked) and "I am waiting for
    /// your input" (fired while nothing is running, but also 60s into a turn the
    /// human has not answered). Only the first ends a turn.
    static func isIdleNudge(_ message: String?) -> Bool {
        guard let message else { return false }
        return message.lowercased().contains("waiting for your input")
    }

    func checkClaudeEvents() {
        let dir = Self.CLAUDE_EVENTS_DIR
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir),
              !names.isEmpty else { return }
        for name in names where name.hasSuffix(".json") {
            let path = dir + "/" + name
            defer { try? FileManager.default.removeItem(atPath: path) }
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty
            else { continue }
            // A banner about a long-finished turn is noise, so stale events get
            // none. The transcript's spinner is another matter: "this turn
            // ended" stays true however late the news arrives, and dropping the
            // whole event left the pane spinning after every app restart — the
            // hook fires while FloatNote is down, and it is down on every
            // rebuild. So a stale event still stops the spinner, then stops.
            let stale = (obj["ts"] as? Double).map { Date().timeIntervalSince1970 - $0 > 120 } ?? false
            let event = obj["event"] as? String ?? ""
            let std = URL(fileURLWithPath: cwd).standardizedFileURL.path
            guard let resolved = paneForClaudeEvent(cwd: std,
                                                    sessionId: obj["session_id"] as? String,
                                                    transcriptPath: obj["transcript_path"] as? String,
                                                    pidChain: (obj["pid_chain"] as? [Int]) ?? [])
            else {
                dbg("claude event [\(event)] dropped — no open pane for \(std)")
                continue
            }
            let tab = resolved.tab
            if stale {
                if event == "Stop" || (event == "Notification" && !Self.isIdleNudge(obj["message"] as? String)) {
                    TranscriptStore.shared.noteTurnEnded(paneId: tab.id)
                    clearPaneActivity(tab.id)
                }
                dbg("claude event [\(event)] stale — spinner cleared, no banner")
                continue
            }
            // Claude's last turn, for hands-free voice. Empty when the hook
            // install predates the field, or the event carries no turn text.
            let turnText = obj["last_assistant_message"] as? String ?? ""
            // Bind this pane to its conversation. Authoritative — Claude Code
            // itself named the session — and cheap: two string fields the hook
            // already had and threw away.
            // Only a pane we actually IDENTIFIED may be re-stamped. Guessing
            // between siblings on one directory is how a pane ended up showing
            // the other one's conversation: the transcript trusts these two
            // fields above everything else and stops re-checking.
            if !resolved.identified {
                dbg("claude event [\(event)] on \(std): two panes share it and nothing named the session — pane \(tab.label) keeps its own")
            }
            if resolved.identified,
               let sid = obj["session_id"] as? String, !sid.isEmpty,
               let idx = terminalTabs.firstIndex(where: { $0.id == tab.id }),
               terminalTabs[idx].claudeSessionId != sid {
                terminalTabs[idx].claudeSessionId = sid
                terminalTabs[idx].claudeTranscriptPath = obj["transcript_path"] as? String
                saveTerminalTabs()
                dbg("transcript: pane \(tab.label) bound to session \(sid.prefix(8))")
                if tab.id == activeTerminalId { TranscriptStore.shared.rebind(to: terminalTabs[idx]) }
            }
            dbg("claude event [\(event)] → pane \(tab.label) turnText=\(turnText.count)ch")
            // A conversation was started, resumed (`/resume`) or cleared in this
            // pane. No banner — the stamp above is the whole point: `/resume`
            // switches the CLI to a different session file without writing
            // anything the app can see, so the transcript kept tailing the
            // conversation the pane had BEFORE the resume until some later
            // prompt happened to name the new one.
            if event == "SessionStart" {
                TranscriptStore.shared.noteTurnEnded(paneId: tab.id)
                clearPaneActivity(tab.id)
                continue
            }
            // The human just submitted a prompt: the turn has started. This is
            // the only start signal that always exists — a Workflow run keeps
            // its agents' records out of the session file, so the pane can look
            // idle on disk for minutes while it is plainly busy.
            if event == "UserPromptSubmit" {
                TranscriptStore.shared.noteTurnStarted(paneId: tab.id)
                paneActivity[tab.id] = Date()
                continue   // no banner: the human is right there, typing
            }
            // Stop ends the turn. So does a Notification that is a permission
            // prompt — but NOT Claude Code's idle "waiting for your input"
            // nudge, which arrives 60s into a long turn and used to stop a
            // spinner over a pane that was still working.
            if event == "Stop" || (event == "Notification" && !Self.isIdleNudge(obj["message"] as? String)) {
                TranscriptStore.shared.noteTurnEnded(paneId: tab.id)
                clearPaneActivity(tab.id)
            }
            if event == "Stop", !turnText.isEmpty {
                HandsfreeManager.shared.handleTurnEnd(message: turnText, tab: tab)
            } else if event == "Notification" {
                // Permission prompt (or "waiting for input"): read it out and
                // take "yes" / "no" / a number as the answer.
                HandsfreeManager.shared.handlePermissionPrompt(
                    message: obj["message"] as? String ?? "", tab: tab)
            }
            postClaudeNotification(event: event,
                                   message: obj["message"] as? String ?? "",
                                   tab: tab)
        }
    }

    /// Fires `checkClaudeEvents()` the moment the hook drops a file, instead of
    /// waiting out the 2s poll — hands-free voice needs Claude to start speaking
    /// as soon as the turn ends. The timer stays as a safety net (a watcher can
    /// miss events if the directory is recreated).
    func startClaudeEventWatcher() {
        let dir = Self.CLAUDE_EVENTS_DIR
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            dbg("claude event watcher: cannot open \(dir)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.checkClaudeEvents() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        claudeEventWatcher = source
        dbg("claude event watcher started on \(dir)")
    }

    private func postClaudeNotification(event: String, message: String, tab: TerminalTab) {
        let content = UNMutableNotificationContent()
        content.title = tab.label
        content.body = event == "Stop"
            ? "Claude finished working"
            : (message.isEmpty ? "Claude needs your input" : message)
        content.sound = .default
        content.userInfo = ["terminalPath": tab.path]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        dbg("claude notification: \(tab.label) [\(event)]")
    }

    // MARK: - Excalidraw boards

    /// Note ids whose board window is on screen. The board lives in its own
    /// window now instead of swapping into the editor column, so "the board is
    /// showing" is a fact about a note, not one global view flag — several can
    /// be open at once. Kept in sync from `BoardWindowController.onChange`.
    @Published var openBoardIds: Set<UUID> = []

    /// Whether this note's board window is open.
    func isBoardOpen(_ id: UUID?) -> Bool { id.map { openBoardIds.contains($0) } ?? false }
    /// Note IDs whose board currently has at least one element. Drives the toolbar
    /// button's active/passive state. Seeded at launch, updated whenever a board saves.
    @Published var boardContentIds: Set<UUID> = []
    /// Observer token for board-save notifications from `ExcalidrawBoardView`.
    private var boardSaveObserver: NSObjectProtocol?
    /// Board-file mod-dates as last seen/written by this app — the External
    /// File Sync pattern's capture-on-save guard, applied to boards. A file
    /// whose date differs was written by MCP.
    private var lastBoardModDates: [UUID: Date] = [:]

    func toggleBoard() {
        guard let tab = activeTab else { return }
        BoardWindowController.shared.toggle(noteId: tab.id, title: tab.title, theme: theme)
    }

    /// Mirror the window controller's state into `openBoardIds` and onto the
    /// notes. Registered once at launch.
    func startBoardWindowTracking() {
        BoardWindowController.shared.onChange = { [weak self] _ in
            guard let self else { return }
            self.openBoardIds = BoardWindowController.shared.openNoteIds
            self.persistBoardVisibility()
        }
    }

    /// Remember on the active note whether its board is showing, so the next
    /// visit (and the next launch) restores the same view.
    func persistBoardVisibility() {
        var changed = false
        for tab in tabs {
            let open = openBoardIds.contains(tab.id)
            if tab.isBoardOpen != open { tab.isBoardOpen = open; changed = true }
        }
        if changed { saveTabsLocal() }
    }

    /// True when the given note has a non-empty board.
    func boardHasContent(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return boardContentIds.contains(id)
    }

    /// Seed `boardContentIds` from disk and start listening for board saves so the
    /// toolbar button's active/passive state stays current.
    private func startBoardTracking() {
        startBoardWindowTracking()
        boardContentIds = ExcalidrawStore.scanContentIds()
        lastBoardModDates = ExcalidrawStore.scanModDates()
        boardSaveObserver = NotificationCenter.default.addObserver(
            forName: .floatnoteBoardSaved, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let id = note.userInfo?["tabId"] as? UUID,
                  let hasContent = note.userInfo?["hasContent"] as? Bool else { return }
            if hasContent { self.boardContentIds.insert(id) }
            else { self.boardContentIds.remove(id) }
            // Capture the date of our own write so the external-change watcher
            // doesn't treat it as a foreign (MCP) edit.
            self.lastBoardModDates[id] = ExcalidrawStore.modDate(for: id)
        }
    }

    /// Detect board files rewritten from outside the app (MCP `draw_on_board`):
    /// refresh the toolbar indicator and surface the change — the active note's
    /// board auto-opens, or reloads in place when already open. Polled by the
    /// same 2s AppDelegate timer as the tabs/folders watchers.
    func checkExternalBoardChanges() {
        let current = ExcalidrawStore.scanModDates()
        let changed = current.filter { lastBoardModDates[$0.key] != $0.value }.map(\.key)
        let removed = Set(lastBoardModDates.keys).subtracting(current.keys)
        guard !changed.isEmpty || !removed.isEmpty else { return }
        lastBoardModDates = current
        for id in removed { boardContentIds.remove(id) }
        for id in changed {
            if ExcalidrawStore.hasContent(for: id) { boardContentIds.insert(id) }
            else { boardContentIds.remove(id) }
            guard id == activeTabId else { continue }
            if isBoardOpen(id) {
                NotificationCenter.default.post(name: .floatnoteBoardExternallyChanged, object: id)
            } else if let tab = tabs.first(where: { $0.id == id }) {
                // Claude drew on the note you are looking at: raise its board so
                // the drawing is not a change nobody sees.
                BoardWindowController.shared.open(noteId: id, title: tab.title, theme: theme)
            }
        }
    }
    /// Folders tree. Flat list; notes reference folders by `folderId`.
    @Published var folders: [Folder] = []
    /// Folder pending permanent deletion (from inside the Trash section).
    @Published var folderPendingDeletion: Folder?
    /// Set when the user has asked to permanently empty the trash.
    @Published var emptyTrashConfirming: Bool = false
    /// Whether the Trash section in the sidebar is expanded.
    @Published var isTrashExpanded: Bool = UserDefaults.standard.bool(forKey: "fn.trashExpanded") {
        didSet { UserDefaults.standard.set(isTrashExpanded, forKey: "fn.trashExpanded") }
    }
    /// ID of a folder that the user just created — lets the sidebar focus its title for rename.
    @Published var editingFolderId: UUID?
    /// Drop-target folder during a tab drag (nil = root).
    @Published var dropTargetFolderId: UUID? = nil
    @Published var isDictating: Bool = false
    var wantsDictation: Bool = false  // user intent: keep dictation alive
    @Published var tabs: [NoteTab] = []
    @Published var activeTabId: UUID? {
        // Remember the last note the user had open so cold start restores it.
        didSet {
            if let id = activeTabId {
                UserDefaults.standard.set(id.uuidString, forKey: "fn.lastActiveNoteId")
            }
        }
    }
    @Published var editingTabId: UUID?
    /// A rename stays separate from the live note model until it is committed.
    /// This prevents SwiftUI from publishing the whole tab collection for each
    /// keystroke and gives drag/drop one reliable value to flush first.
    @Published var editingTabTitle: String = ""
    @Published var draggingTabId: UUID?
    /// Folder currently being dragged in the sidebar (for folder→folder nesting).
    @Published var draggingFolderId: UUID?
    /// Insertion line shown while a folder is hovered over a sibling drop zone
    /// (the top/bottom edge of another folder's row). Nil while the hover means
    /// "nest inside", which uses `dropTargetFolderId`'s fill instead.
    @Published var folderInsertIndicator: FolderInsertIndicator?
    /// True while a sidebar note or folder drag is in flight. Drop indicators
    /// only render while this holds.
    var isDragging: Bool { draggingTabId != nil || draggingFolderId != nil }
    /// Wipe every transient sidebar drag/drop indicator. MUST be called from
    /// each drag start and each `performDrop` — a drop handled by one delegate
    /// (e.g. a note row) otherwise leaves *another* row's indicator painted
    /// forever, which reads as a bogus "selected folder" highlight.
    func clearDragIndicators() {
        dropTargetFolderId = nil
        folderInsertIndicator = nil
        draggingTabId = nil
        draggingFolderId = nil
    }
    @Published var isRecording = false
    @Published var isSavingRecording = false
    @Published var recordPermissionDenied = false
    @Published var recordingTabId: UUID?
    @Published var recordingStartTime: Date?
    @Published var currentRecordingPath: String?
    @Published var selectedLanguage: TranscriptLanguage = .turkish
    @Published var isTranscribing = false
    @Published var isSummarizing = false
    /// True while the editor's first line is still an empty/in-progress H1
    /// title — drives the toolbar's H1 button highlight.

    let recordingManager = RecordingManager()
    let deepgramClient = DeepgramClient()
    let openRouterClient = OpenRouterClient()

    var activeTab: NoteTab? { tabs.first { $0.id == activeTabId } }

    /// Notes that should appear in the top tab bar — i.e. not in the Trash and
    /// not inside a trashed folder.
    var visibleTabs: [NoteTab] {
        let trashedFolderIds = Set(folders.filter { $0.isTrashed }.map { $0.id })
        return tabs.filter { tab in
            tab.folderId != TRASH_FOLDER_ID &&
            !(tab.folderId.map { trashedFolderIds.contains($0) } ?? false)
        }
    }
    var attributedText = NSMutableAttributedString()
    var onContentLoaded: ((NSAttributedString) -> Void)?
    weak var editorCoordinator: RichTextEditor.Coordinator?
    /// Hooks supplied by the text view so we can capture / restore its scroll
    /// position and caret per note when the user switches tabs.
    var captureScrollState: (() -> (scrollY: CGFloat, selection: NSRange)?)?
    var restoreScrollState: ((CGFloat, NSRange) -> Void)?
    /// Scroll + caret position remembered per tab (in-memory; per-session).
    var tabScrollStates: [UUID: (scrollY: CGFloat, selection: NSRange)] = [:]
    var isLoadingContent = false

    private var lastSavedHTML: String = ""
    private var currentHTML: String = ""
    var lastTabsModDate: Date?
    var lastFoldersModDate: Date?
    /// Tokens for the block-based dictation observers so they can be removed.
    /// (The View struct can't be used as an observer; these must live here.)
    var dictationEndToken: NSObjectProtocol?
    var appActiveToken: NSObjectProtocol?
    private var deletedTabIds: Set<String> = []
    private var isSavingInternally = false
    private var suppressSaveAfterReload = false

    init() {
        loadOrCreateNote()
        startBoardTracking()
    }

    private func loadOrCreateNote() {
        // Migrate old tabs file path if needed
        let oldTabsPath = NSHomeDirectory() + "/.evernote-editor-tabs.json"
        if !FileManager.default.fileExists(atPath: LOCAL_TABS_PATH),
           FileManager.default.fileExists(atPath: oldTabsPath) {
            try? FileManager.default.moveItem(atPath: oldTabsPath, toPath: LOCAL_TABS_PATH)
        }

        loadTabsLocal()
        loadFoldersLocal()
        migrateTerminalPathNotesIfNeeded()

        if tabs.isEmpty {
            let tab = NoteTab(title: "Untitled")
            if let localHTML = loadLocal(), !localHTML.isEmpty {
                tab.html = localHTML
            }
            tabs = [tab]
            saveTabsLocal()
        }

        // On launch, restore the note that was open when the app last quit
        // (fn.lastActiveNoteId, kept fresh by activeTabId.didSet). Falls back
        // to a note titled "agentforce tasks" (case/whitespace insensitive),
        // then the first non-trashed tab, then tabs[0].
        let trashedFolderIds = Set(folders.filter { $0.isTrashed }.map { $0.id })
        func isVisible(_ t: NoteTab) -> Bool {
            t.folderId != TRASH_FOLDER_ID &&
            !(t.folderId.map { trashedFolderIds.contains($0) } ?? false)
        }
        func normalize(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: .whitespaces)
        }
        let lastOpenId = UserDefaults.standard.string(forKey: "fn.lastActiveNoteId")
            .flatMap(UUID.init)
        let preferredTitle = "agentforce tasks"
        let firstTab = tabs.first(where: { $0.id == lastOpenId && isVisible($0) })
            ?? tabs.first(where: { isVisible($0) && normalize($0.title).contains(preferredTitle) })
            ?? tabs.first(where: { isVisible($0) })
            ?? tabs[0]
        // Bring back last run's terminal panes first: the route applied at the
        // end of this load then dedups onto them rather than opening duplicates.
        restoreTerminalTabs()
        activeTabId = firstTab.id
        currentHTML = firstTab.html
        lastSavedHTML = firstTab.lastSavedHTML
        currentRecordingPath = firstTab.recordingPaths.last

        if !firstTab.html.isEmpty, let attrStr = htmlToAttributedString(firstTab.html) {
            attributedText = NSMutableAttributedString(attributedString: attrStr)
            charCount = attributedText.length
            onContentLoaded?(attributedText)
        }
        status = currentHTML.isEmpty ? "Ready" : "Loaded"
        lastTabsModDate = tabsFileModDate()
        applyTerminalRouteForActiveNote()
    }

    private func loadTabsLocal() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: LOCAL_TABS_PATH)),
              let tabsData = try? JSONDecoder().decode([TabData].self, from: data) else { return }
        tabs = tabsData.map { NoteTab.from($0) }
    }

    func checkExternalTabChanges() {
        if isSavingInternally { return }
        let current = tabsFileModDate()
        if let current, current != lastTabsModDate {
            lastTabsModDate = current
            reloadTabsFromDisk()
        }
    }

    private func tabsFileModDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: LOCAL_TABS_PATH)[.modificationDate] as? Date
    }

    private func reloadTabsFromDisk() {
        guard !isSavingInternally else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: LOCAL_TABS_PATH)),
              let tabsData = try? JSONDecoder().decode([TabData].self, from: data) else { return }

        // Commit any pending editor edits to currentHTML / activeTab.html BEFORE
        // we cancel the save timer — otherwise the user's last <0.5s of typing is
        // dropped (the timer that would have serialized it is about to be killed).
        flushPendingHTML()

        // Cancel any pending save to avoid overwriting external changes
        saveTimer?.invalidate()
        saveTimer = nil

        let newTabs = tabsData.map { NoteTab.from($0) }
        let currentActiveId = activeTabId

        // Merge: keep active tab's in-memory HTML if user is editing,
        // but add any new tabs from disk (e.g. MCP-created)
        let existingIds = Set(tabs.map { $0.id })
        let diskIds = Set(newTabs.map { $0.id })

        // Add new tabs that appeared on disk — but never resurrect a note the
        // user just permanently deleted (its id may still linger in a stale
        // on-disk copy until the next write settles).
        for newTab in newTabs where !existingIds.contains(newTab.id)
            && !deletedTabIds.contains(newTab.id.uuidString.uppercased()) {
            tabs.append(newTab)
        }
        // Remove tabs deleted from disk (except active)
        tabs.removeAll { !diskIds.contains($0.id) && $0.id != currentActiveId }

        // Refresh tab content from disk
        for diskTab in newTabs {
            guard let existing = tabs.first(where: { $0.id == diskTab.id }) else { continue }
            // folderId can change externally (e.g. MCP create_note + move_note_to_folder
            // sequence). Always sync it — for active and non-active tabs alike — so
            // the sidebar reflects MCP-driven moves.
            let diskFolderId = diskTab.folderId
            if existing.folderId != diskFolderId {
                existing.folderId = diskFolderId
            }
            // Sync the per-note terminal-folder override too (MCP / external edit).
            if existing.localPath != diskTab.localPath {
                existing.localPath = diskTab.localPath
            }
            // Sync the busy label (MCP set_note_status) — active tab included.
            if existing.jobStatus != diskTab.jobStatus {
                existing.jobStatus = diskTab.jobStatus
                existing.jobStatusAt = diskTab.jobStatusAt
            }
            if diskTab.id == currentActiveId {
                // Active tab: only adopt the disk copy if it diverged from what
                // WE last saved (a genuine external edit to this note). Comparing
                // against lastSavedHTML — not currentHTML — means our own unsaved
                // in-memory edits are preserved when some *other* note changed.
                if diskTab.html != lastSavedHTML && !diskTab.html.isEmpty {
                    currentHTML = diskTab.html
                    existing.html = diskTab.html
                    existing.recomputeUncheckedFromHTML()
                    lastSavedHTML = diskTab.html
                    suppressSaveAfterReload = true
                    if let attrStr = htmlToAttributedString(diskTab.html) {
                        isLoadingContent = true
                        attributedText = NSMutableAttributedString(attributedString: attrStr)
                        charCount = attributedText.length
                        onContentLoaded?(attributedText)
                        DispatchQueue.main.async { self.isLoadingContent = false }
                    }
                }
            } else {
                existing.html = diskTab.html
                existing.title = diskTab.title
                existing.recordingPaths = diskTab.recordingPaths
                existing.recomputeUncheckedFromHTML()
            }
        }
        // Re-fire @Published since we mutated nested NoteTab properties.
        tabs = tabs
    }

    func saveTabsLocal() {
        isSavingInternally = true
        // Merge externally-added tabs (e.g. from MCP) before saving — but only
        // if the file actually changed on disk since our last save. When it's
        // unchanged (the common keystroke-debounce path) the merge can find
        // nothing new, so we skip the disk read + full JSON decode entirely.
        if tabsFileModDate() != lastTabsModDate,
           let diskData = try? Data(contentsOf: URL(fileURLWithPath: LOCAL_TABS_PATH)),
           let diskTabs = try? JSONDecoder().decode([TabData].self, from: diskData) {
            let memoryIds = Set(tabs.map { $0.id })
            let tabsById = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for dt in diskTabs {
                guard let diskId = UUID(uuidString: dt.id),
                      !deletedTabIds.contains(dt.id.uppercased()) else { continue }
                if !memoryIds.contains(diskId) {
                    // New tab from external source
                    tabs.append(NoteTab.from(dt))
                } else if let tab = tabsById[diskId] {
                    // Always sync folderId from disk — MCP can move a note while
                    // we hold a stale in-memory copy, and we must not clobber the
                    // move with our save. Same for active tab.
                    let diskFolderId = dt.folderId.flatMap { UUID(uuidString: $0) }
                    if tab.folderId != diskFolderId {
                        tab.folderId = diskFolderId
                    }
                    if tab.localPath != dt.localPath {
                        tab.localPath = dt.localPath
                    }
                    // Body/title/recording: don't overwrite the active tab
                    // (user may be typing); for others, adopt the disk version.
                    if diskId != activeTabId, tab.html != dt.html {
                        tab.html = dt.html
                        tab.title = dt.title
                        tab.recordingPaths = dt.recordingPaths ?? dt.recordingPath.map { [$0] } ?? []
                    }
                }
            }
        }
        let data = tabs.map { $0.toData() }
        if let json = try? JSONEncoder().encode(data) {
            try? json.write(to: URL(fileURLWithPath: LOCAL_TABS_PATH), options: .atomic)
        }
        lastTabsModDate = tabsFileModDate()
        DispatchQueue.main.async { self.isSavingInternally = false }
    }

    // MARK: - Folder Management

    func loadFoldersLocal() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: LOCAL_FOLDERS_PATH)),
              let list = try? JSONDecoder().decode([FolderData].self, from: data) else { return }
        folders = list.map { Folder.from($0) }
        lastFoldersModDate = foldersFileModDate()
    }

    func saveFoldersLocal() {
        let payload = folders.map { $0.toData() }
        if let json = try? JSONEncoder().encode(payload) {
            let tmp = URL(fileURLWithPath: LOCAL_FOLDERS_PATH + ".tmp")
            try? json.write(to: tmp)
            _ = try? FileManager.default.replaceItemAt(
                URL(fileURLWithPath: LOCAL_FOLDERS_PATH), withItemAt: tmp
            )
        }
        // Capture our own write's mod date so the external-change watcher
        // doesn't treat it as a foreign edit and clobber in-memory state.
        lastFoldersModDate = foldersFileModDate()
    }

    private func foldersFileModDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: LOCAL_FOLDERS_PATH)[.modificationDate] as? Date
    }

    /// Polled from the file-watch timer. If the folders file has changed on
    /// disk since our last save (e.g. MCP server created/renamed/trashed a
    /// folder), reload from disk so the sidebar reflects the change.
    func checkExternalFolderChanges() {
        let current = foldersFileModDate()
        if let current, current != lastFoldersModDate {
            lastFoldersModDate = current
            if let data = try? Data(contentsOf: URL(fileURLWithPath: LOCAL_FOLDERS_PATH)),
               let list = try? JSONDecoder().decode([FolderData].self, from: data) {
                folders = list.map { Folder.from($0) }
            }
        }
    }

    func addFolder(name: String = "New Folder") {
        let folder = Folder(name: name, isExpanded: true)
        folders.append(folder)
        editingFolderId = folder.id
        saveFoldersLocal()
    }

    /// Submitting an empty name is a cancel, not a rename: the folder keeps the
    /// name it had. "Untitled" is only a last resort when there's nothing to keep.
    func renameFolder(_ id: UUID, to newName: String) {
        guard let f = folders.first(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            f.name = trimmed
        } else if f.name.trimmingCharacters(in: .whitespaces).isEmpty {
            f.name = "Untitled"
        }
        folders = folders  // re-fire @Published (nested prop mutated)
        editingFolderId = nil
        saveFoldersLocal()
    }

    func toggleFolderExpanded(_ id: UUID) {
        guard let f = folders.first(where: { $0.id == id }) else { return }
        f.isExpanded.toggle()
        saveFoldersLocal()
    }

    /// Link a folder to a local directory, making it a "project". Notes in its
    /// subtree inherit `path` as their terminal working directory.
    func linkFolder(_ id: UUID, to path: String) {
        guard let f = folders.first(where: { $0.id == id }) else { return }
        f.localPath = path
        folders = folders  // re-fire @Published (sidebar partitions on folder props)
        saveFoldersLocal()
        applyTerminalRouteForActiveNote()
    }

    /// Unlink a folder's local directory — back to a plain folder (no terminal).
    func unlinkFolder(_ id: UUID) {
        guard let f = folders.first(where: { $0.id == id }) else { return }
        f.localPath = nil
        folders = folders
        saveFoldersLocal()
        applyTerminalRouteForActiveNote()
    }

    /// One-time migration (guarded by a UserDefaults flag): fold each legacy
    /// "…terminal path" note into its folder's `localPath`, so existing routed
    /// folders keep working with zero user action. The old note is left in place
    /// as an ordinary note the user can delete.
    private func migrateTerminalPathNotesIfNeeded() {
        let key = "fn.projectFoldersMigrated"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        var changed = false
        for folder in folders where !folder.isTrashed && folder.localPath == nil {
            guard let note = tabs.first(where: {
                $0.folderId == folder.id && $0.title.lowercased().contains("terminal path")
            }) else { continue }
            let plain = htmlToAttributedString(note.html)?.string ?? ""
            guard let firstLine = plain
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty }) else { continue }
            let expanded = (firstLine as NSString).expandingTildeInPath
            guard !expanded.isEmpty else { continue }
            folder.localPath = expanded
            changed = true
        }
        if changed { folders = folders; saveFoldersLocal() }
        UserDefaults.standard.set(true, forKey: key)
    }

    // MARK: - Folder nesting

    /// Where a dragged folder would land relative to the folder row under the
    /// cursor: on its top edge (`below == false`) or its bottom edge.
    struct FolderInsertIndicator: Equatable {
        let id: UUID
        let below: Bool
    }

    /// Direct child folders of `parent` (nil = root), trash state ignored.
    func childFolders(of parent: UUID?) -> [Folder] {
        folders.filter { $0.parentId == parent }
    }

    /// All descendant folder IDs of `id` (children, grandchildren, …).
    func descendantFolderIds(of id: UUID) -> Set<UUID> {
        var result = Set<UUID>()
        var stack = [id]
        while let current = stack.popLast() {
            for child in folders where child.parentId == current {
                if result.insert(child.id).inserted { stack.append(child.id) }
            }
        }
        return result
    }

    /// True if `candidate` is `ancestor` itself or nested anywhere beneath it.
    private func isSelfOrDescendant(_ candidate: UUID, of ancestor: UUID) -> Bool {
        candidate == ancestor || descendantFolderIds(of: ancestor).contains(candidate)
    }

    /// Move `folderId` under `newParent` (nil = root). Rejected if it would
    /// create a cycle (dropping a folder onto itself or one of its descendants).
    func moveFolder(_ folderId: UUID, toParent newParent: UUID?) {
        guard let folder = folders.first(where: { $0.id == folderId }) else { return }
        if let newParent {
            guard !isSelfOrDescendant(newParent, of: folderId) else { return }
            // Auto-expand the destination so the moved folder is visible.
            folders.first(where: { $0.id == newParent })?.isExpanded = true
        }
        guard folder.parentId != newParent else { return }
        folder.parentId = newParent
        folders = folders  // re-fire @Published so the sidebar repartitions
        saveFoldersLocal()
    }

    /// Reorder `folderId` to sit immediately before (or after, when `below`)
    /// `targetId`, adopting the target's parent. This is what makes the sidebar
    /// reorderable: display order within a level is the relative order of
    /// `folders`, so moving the element moves the row.
    ///
    /// Dropping next to a folder in a *different* parent both reparents and
    /// positions — that's how a subfolder gets promoted to root (drop it between
    /// two root folders) and vice versa.
    func moveFolder(_ folderId: UUID, relativeTo targetId: UUID, below: Bool) {
        guard folderId != targetId,
              let dragIndex = folders.firstIndex(where: { $0.id == folderId }),
              let target = folders.first(where: { $0.id == targetId }) else { return }
        // Landing next to a descendant would reparent the folder under itself.
        guard !isSelfOrDescendant(targetId, of: folderId) else { return }

        let dragged = folders[dragIndex]
        if dragged.parentId != target.parentId {
            dragged.parentId = target.parentId
            if let newParent = target.parentId {
                folders.first(where: { $0.id == newParent })?.isExpanded = true
            }
        }

        folders.remove(at: dragIndex)
        // Recompute the target's index — removing the dragged element may have
        // shifted it.
        guard let targetIndex = folders.firstIndex(where: { $0.id == targetId }) else {
            folders.append(dragged)  // unreachable in practice; keep the folder alive
            folders = folders
            saveFoldersLocal()
            return
        }
        folders.insert(dragged, at: below ? targetIndex + 1 : targetIndex)
        folders = folders  // re-fire @Published so the sidebar repartitions
        saveFoldersLocal()
    }

    /// Move a folder (and its contained notes) to the Trash. Reversible via
    /// `restoreFolder`. The folder + its notes remain on disk; only the
    /// folder's `isTrashed` flag changes.
    func trashFolder(_ id: UUID) {
        guard let f = folders.first(where: { $0.id == id }) else { return }
        // Cascade: the folder and every subfolder beneath it go to Trash together.
        let subtree = descendantFolderIds(of: id).union([id])
        for folder in folders where subtree.contains(folder.id) {
            folder.isTrashed = true
        }
        folders = folders  // re-fire @Published so sidebar repartitions
        // If the active note lives anywhere in this subtree, switch to a visible one.
        if let active = activeTab, let fid = active.folderId, subtree.contains(fid) {
            switchToFirstVisibleTab(excluding: nil)
        }
        isTrashExpanded = true
        saveFoldersLocal()
    }

    /// Restore a trashed folder subtree back to the sidebar. If its parent is no
    /// longer present/visible, the restored root is reparented to root so it
    /// can't become orphaned.
    func restoreFolder(_ id: UUID) {
        guard let f = folders.first(where: { $0.id == id }) else { return }
        let subtree = descendantFolderIds(of: id).union([id])
        for folder in folders where subtree.contains(folder.id) {
            folder.isTrashed = false
        }
        // If the parent is missing or still trashed, lift this root to top level.
        if let pid = f.parentId,
           folders.first(where: { $0.id == pid })?.isTrashed != false {
            f.parentId = nil
        }
        folders = folders  // re-fire @Published so sidebar repartitions
        // Also nudge tabs so any tab views inside the (now-restored) folder rerender.
        tabs = tabs
        saveFoldersLocal()
    }

    /// Permanently delete a folder and ALL notes inside it. Recordings on disk
    /// are removed. No restore after this.
    func permanentlyDeleteFolder(_ id: UUID) {
        // Cascade: this folder plus every subfolder beneath it, and all their notes.
        let doomedFolderIds = descendantFolderIds(of: id).union([id])
        let doomedTabs = tabs.filter { $0.folderId.map { doomedFolderIds.contains($0) } ?? false }
        let doomedActive = doomedTabs.contains { $0.id == activeTabId }
        for tab in doomedTabs {
            deletedTabIds.insert(tab.id.uuidString.uppercased())
            for recPath in tab.recordingPaths {
                try? FileManager.default.removeItem(atPath: recPath)
            }
            ExcalidrawStore.deleteBoard(for: tab.id)
            boardContentIds.remove(tab.id)
            ImageStore.deleteImages(inHTML: tab.html)
        }
        tabs.removeAll { $0.folderId.map { doomedFolderIds.contains($0) } ?? false }
        folders.removeAll { doomedFolderIds.contains($0.id) }
        if doomedActive { switchToFirstVisibleTab(excluding: nil) }
        saveFoldersLocal()
        saveTabsLocal()
    }

    /// Permanently empty the Trash: hard-delete all trashed folders, every note
    /// inside them, and every loose-trashed note.
    func emptyTrash() {
        // Hard-delete loose-trashed notes (folderId == TRASH_FOLDER_ID).
        let looseTrashed = tabs.filter { $0.folderId == TRASH_FOLDER_ID }
        for tab in looseTrashed {
            deletedTabIds.insert(tab.id.uuidString.uppercased())
            for recPath in tab.recordingPaths {
                try? FileManager.default.removeItem(atPath: recPath)
            }
            ExcalidrawStore.deleteBoard(for: tab.id)
            boardContentIds.remove(tab.id)
            ImageStore.deleteImages(inHTML: tab.html)
        }
        tabs.removeAll { $0.folderId == TRASH_FOLDER_ID }

        // Hard-delete every trashed folder + its notes.
        let trashedIds = Set(folders.filter { $0.isTrashed }.map { $0.id })
        for tab in tabs where tab.folderId.map({ trashedIds.contains($0) }) ?? false {
            deletedTabIds.insert(tab.id.uuidString.uppercased())
            for recPath in tab.recordingPaths {
                try? FileManager.default.removeItem(atPath: recPath)
            }
            ExcalidrawStore.deleteBoard(for: tab.id)
            boardContentIds.remove(tab.id)
            ImageStore.deleteImages(inHTML: tab.html)
        }
        tabs.removeAll { tab in tab.folderId.map { trashedIds.contains($0) } ?? false }
        folders.removeAll { $0.isTrashed }

        // If active tab is gone, switch to a visible one.
        if activeTabId == nil || tabs.first(where: { $0.id == activeTabId }) == nil {
            switchToFirstVisibleTab(excluding: nil)
        }
        saveFoldersLocal()
        saveTabsLocal()
    }

    /// Move a note into a folder (or pass nil to move back to root).
    /// Note: passing TRASH_FOLDER_ID is equivalent to `trashTab(...)`.
    func moveTab(_ tabId: UUID, toFolder folderId: UUID?) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        guard tab.folderId != folderId else { return }
        tab.folderId = folderId
        tabs = tabs  // re-fire @Published so sidebar repartitions
        saveTabsLocal()
        // The note's inherited route changed with its folder — re-resolve it so
        // the terminal follows immediately instead of waiting for a tab switch.
        if tabId == activeTabId { applyTerminalRouteForActiveNote() }
    }

    /// Convenience: switch to the preferred home note ("agentforce tasks")
    /// if available, otherwise the first non-trashed tab. If nothing visible
    /// remains, create an Untitled note so the editor always has something.
    private func switchToFirstVisibleTab(excluding excludeId: UUID?) {
        let trashedFolderIds = Set(folders.filter { $0.isTrashed }.map { $0.id })
        func isVisible(_ tab: NoteTab) -> Bool {
            tab.id != excludeId &&
            tab.folderId != TRASH_FOLDER_ID &&
            !(tab.folderId.map { trashedFolderIds.contains($0) } ?? false)
        }
        let normalizedPreferred = "agentforce tasks"
        let preferred = tabs.first { tab in
            isVisible(tab) &&
            tab.title.lowercased().trimmingCharacters(in: .whitespaces).contains(normalizedPreferred)
        }
        if let target = preferred ?? tabs.first(where: isVisible) {
            switchTab(target.id)
        } else {
            addTab()
        }
    }

    // MARK: - Tab Management

    /// Re-render the current note with fresh attributes (used after changing
    /// body font size so existing content picks up the new scale).
    func reloadActive() {
        guard let id = activeTabId, let tab = tabs.first(where: { $0.id == id }) else { return }
        isLoadingContent = true
        if let attrStr = htmlToAttributedString(tab.html) {
            attributedText = NSMutableAttributedString(attributedString: attrStr)
            charCount = attributedText.length
            onContentLoaded?(attributedText)
        }
        DispatchQueue.main.async { self.isLoadingContent = false }
    }

    func switchTab(_ id: UUID) {
        guard id != activeTabId, let newTab = tabs.first(where: { $0.id == id }) else { return }

        // Commit any active rename before changing the selected model.
        commitTabRename()

        flushPendingHTML()

        // Save current tab's state
        if let current = activeTab {
            current.html = currentHTML
            current.lastSavedHTML = lastSavedHTML
            // Remember where the user was (scroll + caret) so we can restore on return.
            if let state = captureScrollState?() {
                tabScrollStates[current.id] = state
            }
        }
        saveTabsLocal()

        activeTabId = id
        if let fid = newTab.folderId, fid != TRASH_FOLDER_ID {
            lastActiveNotePerFolder[fid] = newTab.id
            // Also remember the note under its project folder (the nearest linked
            // ancestor it routes to), so tapping that terminal's chip returns to
            // subtree notes, not just notes in the project folder itself.
            if let routeRoot = nearestLinkedFolder(startingAt: fid), routeRoot.id != fid {
                lastActiveNotePerFolder[routeRoot.id] = newTab.id
            }
        }
        currentRecordingPath = newTab.recordingPaths.last
        currentHTML = newTab.html
        lastSavedHTML = newTab.lastSavedHTML

        isLoadingContent = true
        if let attrStr = htmlToAttributedString(newTab.html) {
            attributedText = NSMutableAttributedString(attributedString: attrStr)
            charCount = attributedText.length
            onContentLoaded?(attributedText)
        } else {
            attributedText = NSMutableAttributedString()
            charCount = 0
            onContentLoaded?(NSAttributedString(string: ""))
        }
        // Restore previously-remembered scroll + caret for this note, if any.
        if let saved = tabScrollStates[id] {
            DispatchQueue.main.async { [weak self] in
                self?.restoreScrollState?(saved.scrollY, saved.selection)
            }
        }
        DispatchQueue.main.async { self.isLoadingContent = false }
        status = "Loaded"
        applyTerminalRouteForActiveNote()
    }

    func addTab() {
        flushPendingHTML()
        // Save current tab
        if let current = activeTab {
            current.html = currentHTML
            current.lastSavedHTML = lastSavedHTML
        }

        let tab = NoteTab(title: "Untitled")
        tabs.append(tab)
        activeTabId = tab.id
        currentHTML = ""
        currentRecordingPath = nil
        lastSavedHTML = ""
        charCount = 0
        onContentLoaded?(NSAttributedString(string: ""))
        saveTabsLocal()
        status = "New note"
        applyTerminalRouteForActiveNote(focusTerminal: false)
        focusEditor()
    }

    /// Move a note to Trash. Reversible via `restoreTab`.
    func trashTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if id == recordingTabId && isRecording { return }
        // Save dirty state on the soon-to-be-trashed active tab before switching.
        if activeTabId == id {
            flushPendingHTML()
            tab.html = currentHTML
            tab.lastSavedHTML = lastSavedHTML
        }
        tab.folderId = TRASH_FOLDER_ID
        tabs = tabs  // re-fire @Published so sidebar repartitions
        if activeTabId == id {
            switchToFirstVisibleTab(excluding: id)
        }
        saveTabsLocal()
    }

    /// Restore a trashed note: lift it back to the root. If the note's prior
    /// containing folder has been permanently deleted we fall back to root.
    func restoreTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        // Loose-trashed → return to root. Folder-trashed notes are restored
        // implicitly by restoring their folder.
        if tab.folderId == TRASH_FOLDER_ID {
            tab.folderId = nil
            tabs = tabs  // re-fire @Published so sidebar repartitions
            saveTabsLocal()
        }
    }

    /// Permanently delete a note from disk. No restore after this.
    func permanentlyDeleteTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if id == recordingTabId && isRecording { return }
        deletedTabIds.insert(id.uuidString.uppercased())

        // Delete associated recording file from disk
        for recPath in tabs[index].recordingPaths {
            try? FileManager.default.removeItem(atPath: recPath)
        }
        // Delete the note's Excalidraw board and stored images, if any.
        ExcalidrawStore.deleteBoard(for: id)
        boardContentIds.remove(id)
        ImageStore.deleteImages(inHTML: tabs[index].html)

        // Switch away if deleting the active tab
        if activeTabId == id {
            tabs.remove(at: index)
            switchToFirstVisibleTab(excluding: nil)
        } else {
            tabs.remove(at: index)
        }
        saveTabsLocal()
    }

    func beginTabRename(_ id: UUID) {
        if editingTabId != id { commitTabRename() }
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        editingTabTitle = tab.title
        editingTabId = id
    }

    func commitTabRename() {
        guard let id = editingTabId else { return }
        renameTab(id, title: editingTabTitle)
    }

    func renameTab(_ id: UUID, title: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else {
            editingTabId = nil
            return
        }
        if tab.title != title {
            BoardWindowController.shared.retitle(noteId: id, to: title)
            tab.title = title
            saveTabsLocal()
        }
        editingTabId = nil
    }

    func moveTab(from sourceId: UUID, to destId: UUID) {
        guard sourceId != destId,
              let fromIdx = tabs.firstIndex(where: { $0.id == sourceId }),
              let toIdx = tabs.firstIndex(where: { $0.id == destId }) else { return }
        let destFolderId = tabs[toIdx].folderId
        let folderChanged = tabs[fromIdx].folderId != destFolderId
        withAnimation(.easeInOut(duration: 0.2)) {
            // Adopt the destination's folder so dropping on a note that lives
            // inside a folder places the dragged note in that same folder.
            if folderChanged {
                tabs[fromIdx].folderId = destFolderId
            }
            tabs.move(fromOffsets: IndexSet(integer: fromIdx), toOffset: toIdx > fromIdx ? toIdx + 1 : toIdx)
        }
        saveTabsLocal()
        // Reordering onto a note in another folder reparents the dragged note,
        // so its inherited route changed — re-resolve it (see moveTab(_:toFolder:)).
        if folderChanged && sourceId == activeTabId { applyTerminalRouteForActiveNote() }
    }

    private var saveTimer: Timer?

    /// If the debounced save timer is pending, immediately serialize the editor
    /// state into `currentHTML` and cancel the timer. Call this before any
    /// code path that needs the latest HTML (tab switch, save, export, trash).
    func flushPendingHTML() {
        guard saveTimer != nil else { return }
        saveTimer?.invalidate()
        saveTimer = nil
        if let coord = editorCoordinator, let tv = coord.textView {
            let html = coord.extractHTML(from: tv)
            currentHTML = html
            activeTab?.html = html
        }
    }

    func textDidChange(html: String, length: Int, uncheckedCount: Int? = nil) {
        guard !isLoadingContent else { return }
        if suppressSaveAfterReload {
            suppressSaveAfterReload = false
            return
        }
        charCount = length
        // Live badge update: reflect checked/unchecked toggles + typed checkboxes in
        // the sidebar instantly, before the debounced save fires.
        if let uncheckedCount { activeTab?.uncheckedCount = uncheckedCount }
        status = "Editing..."
        // Debounce disk writes — save after 0.5s of idle.
        // HTML serialization is expensive (full-document WebKit-style serialize),
        // so we only do it once when the timer fires, not on every keystroke.
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let latestHTML: String
                if let coord = self.editorCoordinator, let tv = coord.textView {
                    latestHTML = coord.extractHTML(from: tv)
                } else {
                    latestHTML = self.currentHTML
                }
                self.currentHTML = latestHTML
                self.activeTab?.html = latestHTML
                self.saveLocal(html: latestHTML)
                self.saveTabsLocal()
                // Track what's now on disk so the external-reload path can tell a
                // genuine foreign edit from our own unsaved in-memory edits.
                self.lastSavedHTML = latestHTML
                self.status = "Saved"
            }
        }
    }

    /// Toolbar "photo" button: pick an image file and insert it at the caret.
    func attachImage() {
        guard let tv = editorCoordinator?.textView as? BlockCaretTextView else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.title = "Attach Images"
        guard panel.runModal() == .OK else { return }
        let images = panel.urls.compactMap { NSImage(contentsOf: $0) }
        guard !images.isEmpty else { return }
        tv.window?.makeFirstResponder(tv)
        tv.insertImages(images)
    }

    func performFormat(_ action: FormatAction) {
        guard let coordinator = editorCoordinator, let textView = coordinator.textView else {
            dbg("performFormat BAIL: coordinator=\(editorCoordinator != nil), textView=\(editorCoordinator?.textView != nil)")
            return
        }
        textView.window?.makeFirstResponder(textView)
        let savedRange = coordinator.lastSelectedRange
        let maxLen = textView.textStorage?.length ?? 0
        dbg("performFormat: action=\(action), savedRange=(\(savedRange.location),\(savedRange.length)), storageLen=\(maxLen)")
        if savedRange.location <= maxLen && NSMaxRange(savedRange) <= maxLen {
            textView.setSelectedRange(savedRange)
        }
        coordinator.applyFormat(action, textView: textView)
    }

    func togglePin() {
        isPinned.toggle()
        let window = NSApp.windows.first(where: { $0.isKeyWindow }) ?? NSApp.windows.first
        window?.level = isPinned ? .floating : .normal
        if isPinned {
            // Pinned = compact floating note: stash chrome state, then hide the
            // sidebar and terminal panel (sessions survive — hide ≠ kill).
            prePinSidebarCollapsed = isSidebarCollapsed
            prePinTerminalVisible = isTerminalVisible
            isSidebarCollapsed = true
            hideTerminal()
            if let window {
                prePinWindowFrame = window.frame
                // The pinned size is below the global 240×180 floor — lower it
                // for the duration of the pin so setFrame isn't clamped.
                window.minSize = NSSize(width: Self.pinnedWindowSize.width,
                                        height: Self.pinnedWindowSize.height)
                var frame = window.frame
                frame.origin.y += frame.height - Self.pinnedWindowSize.height  // keep top edge put
                frame.size = Self.pinnedWindowSize
                window.setFrame(frame, display: true, animate: true)
            }
        } else {
            if let window {
                WindowAccessor.applyMinSize(window: window, sidebarCollapsed: isSidebarCollapsed)
                if let frame = prePinWindowFrame {
                    window.setFrame(frame, display: true, animate: true)
                }
            }
            prePinWindowFrame = nil
            if let collapsed = prePinSidebarCollapsed { isSidebarCollapsed = collapsed }
            if prePinTerminalVisible == true {
                // Re-apply the active note's route; a routeless note simply
                // stays hidden (no HOME-fallback terminal — see toggleTerminal()).
                applyTerminalRouteForActiveNote()
            }
            prePinSidebarCollapsed = nil
            prePinTerminalVisible = nil
        }
    }

    func startRecording() async {
        guard let tab = activeTab else { return }

        // The mic is exclusive: meeting capture beats hands-free voice.
        HandsfreeManager.shared.yieldToRecording()
        recordingTabId = tab.id
        isRecording = true
        recordingStartTime = Date()
        saveTabsLocal()

        // Check permissions and start recording
        let ok = await recordingManager.checkAndRequestPermissions()
        if !ok {
            recordPermissionDenied = true
            isRecording = false
            recordingStartTime = nil
            recordingTabId = nil
            return
        }
        recordPermissionDenied = false

        await recordingManager.start()
    }

    func stopRecording() async {
        isRecording = false
        recordingStartTime = nil
        isSavingRecording = true

        // stop() now returns quickly (mic file only, system audio cleanup is background)
        guard let url = await recordingManager.stop() else {
            isSavingRecording = false
            recordingTabId = nil
            return
        }
        isSavingRecording = false
        currentRecordingPath = url.path
        if let tabId = recordingTabId, let tab = tabs.first(where: { $0.id == tabId }) {
            tab.recordingPaths.append(url.path)
            tabs = tabs
        }
        recordingTabId = nil
        saveTabsLocal()
    }

    /// Remove one recording from a note: deletes the .m4a from disk and drops
    /// the entry from the note's list. Called from a row's confirmed ✕.
    func deleteRecording(path: String, from tabId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        try? FileManager.default.removeItem(atPath: path)
        tab.recordingPaths.removeAll { $0 == path }
        if currentRecordingPath == path { currentRecordingPath = tab.recordingPaths.last }
        tabs = tabs
        saveTabsLocal()
    }

    /// Set or clear (status = nil) a note's busy label. Re-fires the sidebar and
    /// persists immediately so the on-disk copy never diverges from memory (the
    /// external-change merge would otherwise resurrect a cleared flag).
    func setJobStatus(_ status: String?, for tabId: UUID?) {
        guard let tabId, let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.jobStatus = status
        tab.jobStatusAt = status == nil ? nil : Date()
        tabs = tabs
        saveTabsLocal()
    }

    /// Clear job statuses older than the TTL (crashed agent / leftover flag).
    /// Called from the AppDelegate 2s timer.
    func sweepExpiredJobStatuses() {
        var changed = false
        for tab in tabs where tab.jobStatus != nil && !tab.isJobActive {
            tab.jobStatus = nil
            tab.jobStatusAt = nil
            changed = true
        }
        if changed {
            tabs = tabs
            saveTabsLocal()
        }
    }

    func transcribeRecording(path: String? = nil) async {
        // Capture origin tab + path up-front so the result lands on the note the
        // user pressed the button on, even if they switch tabs while it's running.
        // `path` targets a specific recording row; nil = the note's newest.
        let originTabId = activeTabId
        let originPath = path
            ?? tabs.first(where: { $0.id == originTabId })?.recordingPaths.last
            ?? currentRecordingPath
        dbg("transcribe: CALLED, originTab=\(originTabId?.uuidString ?? "nil") path=\(originPath ?? "nil")")
        guard let path = originPath, let client = deepgramClient else {
            dbg("transcribe: guard failed — path=\(originPath ?? "nil") client=\(deepgramClient != nil)")
            return
        }
        let fileURL = URL(fileURLWithPath: path)
        isTranscribing = true
        status = "Transcribing…"
        setJobStatus("Transcribing…", for: originTabId)
        defer { setJobStatus(nil, for: originTabId) }
        guard let result = await client.transcribe(fileURL: fileURL, language: selectedLanguage, includeSummary: false) else {
            isTranscribing = false
            status = "Transcription failed"
            return
        }
        isTranscribing = false
        status = "Transcription done"
        insertTextIntoEditor(result.transcript, targetTabId: originTabId)
    }

    func summarizeRecording(path: String? = nil) async {
        let originTabId = activeTabId
        let originPath = path
            ?? tabs.first(where: { $0.id == originTabId })?.recordingPaths.last
            ?? currentRecordingPath
        guard let path = originPath, let deepgram = deepgramClient, let router = openRouterClient else {
            dbg("summarize: guard failed — path=\(originPath ?? "nil") deepgram=\(deepgramClient != nil) router=\(openRouterClient != nil)")
            return
        }
        let fileURL = URL(fileURLWithPath: path)
        isSummarizing = true
        status = "Transcribing…"
        setJobStatus("Summarizing…", for: originTabId)
        defer { setJobStatus(nil, for: originTabId) }

        // Step 1: Transcribe audio via Deepgram
        guard let result = await deepgram.transcribe(fileURL: fileURL, language: selectedLanguage, includeSummary: false) else {
            isSummarizing = false
            status = "Transcription failed"
            return
        }

        // Step 2: Summarize transcript via OpenRouter
        guard let summary = await router.summarize(transcript: result.transcript, language: selectedLanguage, onStatus: { [weak self] msg in
            self?.status = msg
        }) else {
            isSummarizing = false
            return
        }

        isSummarizing = false
        status = "Summary done"
        insertTextIntoEditor(summary, targetTabId: originTabId)
    }

    private func insertTextIntoEditor(_ text: String, targetTabId: UUID? = nil) {
        let tid = targetTabId ?? activeTabId
        guard let tid, let tab = tabs.first(where: { $0.id == tid }) else { return }

        if tid == activeTabId { flushPendingHTML() }

        let newHtml = text.components(separatedBy: "\n").map { line in
            let escaped = line.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "<p>\(escaped.isEmpty ? "<br>" : escaped)</p>"
        }.joined()

        let baseHtml = (tid == activeTabId) ? currentHTML : tab.html
        let existing = baseHtml.trimmingCharacters(in: .whitespacesAndNewlines)
        let html = existing.isEmpty ? newHtml : existing + "<hr>" + newHtml

        tab.html = html

        if tid == activeTabId {
            currentHTML = html
            if let attrStr = htmlToAttributedString(html) {
                attributedText = NSMutableAttributedString(attributedString: attrStr)
                charCount = attributedText.length
                onContentLoaded?(attributedText)
            }
            saveLocal(html: html)
        }
        saveTabsLocal()
    }

    private func saveLocal(html: String) {
        try? html.write(toFile: LOCAL_SAVE_PATH, atomically: true, encoding: .utf8)
    }

    func saveLocalSync() {
        flushPendingHTML()
        activeTab?.html = currentHTML
        try? currentHTML.write(toFile: LOCAL_SAVE_PATH, atomically: true, encoding: .utf8)
        saveTabsLocal()
    }

    private func loadLocal() -> String? {
        try? String(contentsOfFile: LOCAL_SAVE_PATH, encoding: .utf8)
    }

    // MARK: - Import / Export

    func exportNotes() {
        flushPendingHTML()
        // Commit current editor state before exporting
        if let current = activeTab {
            current.html = currentHTML
            current.lastSavedHTML = lastSavedHTML
        }

        let panel = NSSavePanel()
        panel.title = "Export Notes"
        panel.nameFieldStringValue = "floatnote-export.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let data = tabs.map { $0.toData() }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = try encoder.encode(data)
            try json.write(to: url)
            status = "Exported \(tabs.count) note(s)"
        } catch {
            status = "Export failed"
        }
    }

    func importNotes() {
        let panel = NSOpenPanel()
        panel.title = "Import Notes"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let imported = try JSONDecoder().decode([TabData].self, from: data)
            guard !imported.isEmpty else { status = "No notes in file"; return }

            // Assign new IDs to avoid collisions with existing tabs
            for td in imported {
                let tab = NoteTab(title: td.title)
                tab.html = td.html
                tab.recordingPaths = td.recordingPaths ?? td.recordingPath.map { [$0] } ?? []
                tabs.append(tab)
            }

            // Switch to the first imported tab
            let firstImportedIndex = tabs.count - imported.count
            switchTab(tabs[firstImportedIndex].id)

            saveTabsLocal()
            status = "Imported \(imported.count) note(s)"
        } catch {
            status = "Import failed – invalid file"
        }
    }

    func htmlToAttributedString(_ html: String) -> NSAttributedString? {
        let styledHTML = """
        <html dir="ltr"><head><style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 14px; direction: ltr; text-align: left; }
        h1 { font-size: 28px; font-weight: 700; }
        h2 { font-size: 22px; font-weight: 600; }
        h3 { font-size: 18px; font-weight: 600; }
        a { color: #6cb6ff; }
        </style></head><body dir="ltr">\(html)</body></html>
        """
        guard let data = styledHTML.data(using: .utf8),
              let attrStr = try? NSMutableAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              ) else { return nil }

        // Normalize baked-in body text colors. HTML exports inline per-run colors
        // from whatever theme produced them; without this, notes saved on Obsidian
        // render as near-invisible light-gray when re-opened on Paper/Sepia.
        // Accent colors (headings / links, which are shades of blue) are left alone.
        let bodyColor = theme.editorTextNS
        let fullRange = NSRange(location: 0, length: attrStr.length)
        attrStr.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, range, _ in
            let isAccent: Bool
            if let c = (value as? NSColor)?.usingColorSpace(.genericRGB) {
                // Accent blue family: blue dominant, red low.
                isAccent = c.blueComponent > 0.85 && c.redComponent < 0.6
            } else {
                isAccent = false
            }
            if !isAccent {
                attrStr.addAttribute(.foregroundColor, value: bodyColor, range: range)
            }
        }

        // Normalize legacy fonts to the new sans-serif defaults while preserving
        // bold/italic traits and heading sizes. Old notes were saved at Times 16pt;
        // we remap body-size ranges to 14pt so every note reads the same.
        let full = NSRange(location: 0, length: attrStr.length)
        attrStr.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let traits = font.fontDescriptor.symbolicTraits
            let originalSize = font.pointSize

            // Heading buckets: snap to the current heading sizes.
            // Non-heading sizes collapse to the 14pt body default.
            let newSize: CGFloat
            if originalSize >= 26 { newSize = 24 }
            else if originalSize >= 20 { newSize = 19 }
            else if originalSize >= 17 { newSize = 16 }
            else { newSize = 14 }

            // Build the replacement in the user's selected editor font family,
            // preserving bold/italic so a font switch re-renders every run.
            let isBold = traits.contains(.bold)
            let isItalic = traits.contains(.italic)
            let replacement = Tokens.Typography.editorFont(size: newSize, bold: isBold, italic: isItalic)
            attrStr.addAttribute(.font, value: replacement, range: range)
        }

        // Swap persisted ⟦img:…⟧ markers back into live image attachments.
        // Single choke point: launch, tab switch, reload and external merge all
        // load through here.
        attrStr.resolveImageMarkers(bodyFont: Tokens.Typography.body(),
                                    bodyColor: theme.editorTextNS)

        return attrStr
    }
}

// MARK: - Deepgram Client

enum TranscriptLanguage: String, CaseIterable {
    case turkish = "tr"
    case english = "en"

    var label: String {
        switch self {
        case .english: return "English"
        case .turkish: return "Turkish"
        }
    }
}

struct DeepgramResult {
    var transcript: String   // diarized speaker-formatted text
    var summary: String?     // summarize=v2 result (English only)
}

// MARK: - OpenRouter Client

class OpenRouterClient {
    private let apiKey: String
    // Free tiers come and go — the gpt-oss pair this used to name lost theirs
    // and answered every summary with a 404, so the whole chain reported "all
    // models rate limited". These three were tested against a real Turkish
    // meeting transcript (16k chars): plain-text output with no markdown leak,
    // correct • bullets and ☐ action items, 7-11s each. `openrouter/free` is
    // last on purpose: it auto-routes to whatever free model is up, so it
    // survives the upstream 429s that take a named model down.
    private let models = [
        "minimax/minimax-m3:free",
        "nvidia/nemotron-3-super-120b-a12b:free",
        "openrouter/free"
    ]

    init?() {
        let keyPath = NSHomeDirectory() + "/.floatnote-openrouter.key"
        guard let key = try? String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        self.apiKey = key
    }

    func summarize(transcript: String, language: TranscriptLanguage, onStatus: @escaping (String) -> Void) async -> String? {
        for (i, model) in models.enumerated() {
            let shortName = model.components(separatedBy: "/").last?.replacingOccurrences(of: ":free", with: "") ?? model
            onStatus("Summarizing via \(shortName)…")
            dbg("openrouter: trying model \(model)")
            if let result = await callModel(model: model, transcript: transcript, language: language, onStatus: onStatus, shortName: shortName) {
                return result
            }
            if i < models.count - 1 {
                onStatus("\(shortName) rate limited, trying next…")
            }
            dbg("openrouter: \(model) failed, trying next")
        }
        onStatus("All AI models rate limited")
        dbg("openrouter: all models failed")
        return nil
    }

    private func callModel(model: String, transcript: String, language: TranscriptLanguage, onStatus: @escaping (String) -> Void, shortName: String) async -> String? {
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else { return nil }

        let langInstruction: String
        switch language {
        case .turkish:
            langInstruction = "Respond entirely in Turkish."
        case .english:
            langInstruction = "Respond entirely in English."
        }

        let systemPrompt = """
            You are a meeting notes summarizer. Summarize the following meeting transcript into clear, structured meeting notes. \(langInstruction)

            CRITICAL FORMATTING RULES — you MUST follow these exactly:
            - Output ONLY plain text. NO markdown whatsoever. No **, no ## , no |tables|, no ---, no ```code```.
            - For section headers, write them as a plain line in ALL CAPS or with a colon, e.g. "DECISIONS:" or "Action Items:"
            - For bullet points, start the line with "• " (bullet character followed by a space)
            - For action items/tasks, start the line with "☐ " (checkbox character followed by a space)
            - Use blank lines to separate sections
            - For sub-items, indent with 4 spaces before the bullet: "    • sub-item"
            - Never use tables. Use bullet lists instead.
            - Keep it concise and well-organized.

            Structure the notes as:
            1. Meeting title and date
            2. Key discussion points (use • bullets)
            3. Decisions made (use • bullets)
            4. Action items with responsible person (use ☐ checkboxes)
            """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": transcript]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = jsonData

        dbg("openrouter: sending \(transcript.count) chars, lang=\(language.rawValue), model=\(model)")

        // Retry up to 2 times on 429 rate limit per model
        for attempt in 1...2 {
            if attempt > 1 {
                onStatus("\(shortName) rate limited, retrying in 10s…")
                dbg("openrouter: retry \(attempt)/2 after 10s for \(model)")
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                onStatus("Retrying \(shortName)…")
            }

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                dbg("openrouter: request failed — \(error.localizedDescription)")
                continue
            }
            guard let httpResp = response as? HTTPURLResponse else {
                dbg("openrouter: not an HTTP response")
                return nil
            }
            if httpResp.statusCode == 429 {
                dbg("openrouter: 429 rate limited \(model) (attempt \(attempt)/2)")
                continue
            }
            guard httpResp.statusCode == 200 else {
                dbg("openrouter: HTTP \(httpResp.statusCode) — \(String(data: data, encoding: .utf8) ?? "")")
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                dbg("openrouter: failed to parse response from \(model)")
                return nil
            }

            dbg("openrouter: success with \(model)")
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }
}

class DeepgramClient {
    private let apiKey: String

    init?() {
        let keyPath = NSHomeDirectory() + "/.floatnote-deepgram.key"
        guard let key = try? String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        self.apiKey = key
    }

    func transcribe(fileURL: URL, language: TranscriptLanguage, includeSummary: Bool) async -> DeepgramResult? {
        guard let audioData = try? Data(contentsOf: fileURL) else { return nil }

        var params = "model=nova-3&diarize=true&smart_format=true&punctuate=true&utterances=true&language=\(language.rawValue)"
        if includeSummary {
            params += "&summarize=v2"
        }

        guard let url = URL(string: "https://api.deepgram.com/v1/listen?\(params)") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300  // 5 min for large audio files
        request.httpBody = audioData

        dbg("deepgram: uploading \(audioData.count) bytes, timeout=300s")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            dbg("deepgram: request failed — \(error.localizedDescription)")
            return nil
        }
        guard let httpResp = response as? HTTPURLResponse else {
            dbg("deepgram: not an HTTP response")
            return nil
        }
        guard httpResp.statusCode == 200 else {
            dbg("deepgram: HTTP \(httpResp.statusCode) — \(String(data: data, encoding: .utf8) ?? "")")
            return nil
        }

        return parseResponse(data)
    }

    private func parseResponse(_ data: Data) -> DeepgramResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any] else { return nil }

        // Build diarized transcript from utterances (preferred) or channel words
        var transcript = ""

        if let utterances = results["utterances"] as? [[String: Any]] {
            // Utterances give us speaker-labeled segments
            for utt in utterances {
                let speaker = utt["speaker"] as? Int ?? 0
                let text = utt["transcript"] as? String ?? ""
                transcript += "Speaker \(speaker): \(text)\n\n"
            }
        } else if let channels = results["channels"] as? [[String: Any]],
                  let firstChannel = channels.first,
                  let alternatives = firstChannel["alternatives"] as? [[String: Any]],
                  let firstAlt = alternatives.first {
            // Fallback: build from words with speaker labels
            if let words = firstAlt["words"] as? [[String: Any]] {
                var currentSpeaker = -1
                var currentLine = ""
                for word in words {
                    let speaker = word["speaker"] as? Int ?? 0
                    let w = word["punctuated_word"] as? String ?? word["word"] as? String ?? ""
                    if speaker != currentSpeaker {
                        if !currentLine.isEmpty {
                            transcript += "Speaker \(currentSpeaker): \(currentLine.trimmingCharacters(in: .whitespaces))\n\n"
                        }
                        currentSpeaker = speaker
                        currentLine = w
                    } else {
                        currentLine += " \(w)"
                    }
                }
                if !currentLine.isEmpty {
                    transcript += "Speaker \(currentSpeaker): \(currentLine.trimmingCharacters(in: .whitespaces))\n\n"
                }
            } else {
                transcript = firstAlt["transcript"] as? String ?? ""
            }
        }

        // Extract summary if present
        var summary: String? = nil
        if let summaryObj = results["summary"] as? [String: Any],
           let shortSummary = summaryObj["short"] as? String {
            summary = shortSummary
        }

        return DeepgramResult(transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines), summary: summary)
    }
}

// MARK: - Recording Manager (Core Audio Taps + AVAudioRecorder)

class RecordingManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var permissionDenied = false

    // Background cleanup task from previous stop
    private var cleanupTask: Task<Void, Never>?

    // System audio capture (ScreenCaptureKit)
    private var scStream: SCStream?
    private var scDelegate: SystemAudioDelegate?
    private var systemTempURL: URL?

    // Mic
    private var micRecorder: AVAudioRecorder?
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
        DispatchQueue.main.async { self.permissionDenied = false }
        return true
    }

    // MARK: Start

    func start() async {
        try? FileManager.default.createDirectory(atPath: Self.recordingsDir, withIntermediateDirectories: true)
        let uuid = UUID().uuidString
        systemTempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fn_sys_\(uuid).caf")
        micTempURL    = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fn_mic_\(uuid).m4a")

        // Start mic first — this is instant and shows the mic icon
        startMicCapture()
        DispatchQueue.main.async { self.isRecording = true }

        // Wait for any previous background cleanup, then start system audio
        if let task = cleanupTask {
            dbg("start: waiting for previous cleanup...")
            await task.value
            cleanupTask = nil
            dbg("start: previous cleanup done")
        }
        await startSystemCapture()
    }

    private func startSystemCapture() async {
        dbg("systemCapture: starting with ScreenCaptureKit...")
        guard let sysURL = systemTempURL else { dbg("systemCapture: systemTempURL is nil"); return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { dbg("systemCapture: no display found"); return }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.channelCount = 2
            config.sampleRate = 48000
            // Minimal video capture (OBS pattern: need both screen+audio outputs)
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 10, timescale: 1)

            let delegate = SystemAudioDelegate(outputURL: sysURL)
            scDelegate = delegate

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            // OBS pattern: add both screen and audio outputs
            try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: .global(qos: .utility))
            try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            try await stream.startCapture()
            scStream = stream
            dbg("systemCapture: ScreenCaptureKit stream started")
        } catch {
            dbg("systemCapture: failed: \(error)")
        }
    }

    private func startMicCapture() {
        guard let micURL = micTempURL else {
            dbg("startMicCapture: micTempURL is nil")
            return
        }
        // Clean up any leftover recorder from a previous session
        if micRecorder != nil {
            micRecorder?.stop()
            micRecorder = nil
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000
        ]
        do {
            let recorder = try AVAudioRecorder(url: micURL, settings: settings)
            recorder.prepareToRecord()
            let started = recorder.record()
            dbg("startMicCapture: created recorder, record()=\(started)")
            micRecorder = recorder
        } catch {
            dbg("startMicCapture: failed to create recorder: \(error)")
        }
    }

    // MARK: Stop

    /// Quickly stops mic recording and returns the mic file immediately.
    /// Stops recording, merges system+mic audio, returns merged file URL.
    func stop() async -> URL? {
        DispatchQueue.main.async { self.isRecording = false }

        // 1. Stop mic
        micRecorder?.stop()
        micRecorder = nil

        // 2. Stop system audio capture
        let stream = scStream
        let delegate = scDelegate
        let sysURL = systemTempURL
        scStream = nil
        scDelegate = nil

        if let stream {
            try? await stream.stopCapture()
            dbg("stop: SCStream stopped")
        }
        delegate?.closeFile()

        let outputURL = makeOutputURL()
        guard let micURL = micTempURL else {
            dbg("stop: micTempURL is nil")
            return nil
        }
        systemTempURL = nil
        micTempURL = nil

        // 3. Merge system + mic audio (synchronous — fast PCM mix)
        var merged = false
        if let sysURL, FileManager.default.fileExists(atPath: sysURL.path) {
            merged = await mergeAudio(systemURL: sysURL, micURL: micURL, to: outputURL)
            if merged {
                dbg("stop: merge succeeded -> \(outputURL.path)")
            }
            try? FileManager.default.removeItem(at: sysURL)
        }

        // 4. Fallback: use mic-only file if merge failed
        if !merged {
            do {
                try FileManager.default.copyItem(at: micURL, to: outputURL)
                dbg("stop: mic-only fallback -> \(outputURL.path)")
            } catch {
                dbg("stop: mic copy failed: \(error)")
                try? FileManager.default.removeItem(at: micURL)
                return nil
            }
        }
        try? FileManager.default.removeItem(at: micURL)

        dbg("stop: returning url=\(outputURL.path) merged=\(merged)")
        return outputURL
    }

    private func cleanupSystemAudio() {
        if let stream = scStream {
            Task { try? await stream.stopCapture() }
        }
        scDelegate?.closeFile()
        scStream = nil
        scDelegate = nil
        if let sysURL = systemTempURL { try? FileManager.default.removeItem(at: sysURL) }
        if let micURL = micTempURL { try? FileManager.default.removeItem(at: micURL) }
        systemTempURL = nil
        micTempURL = nil
    }

    // MARK: Merge

    private func mergeAudio(systemURL: URL, micURL: URL, to outputURL: URL) async -> Bool {
        dbg("merge: PCM-level mix starting...")
        do {
            // Read both files — AVAudioFile decodes to Float32 PCM automatically
            let sysFile = try AVAudioFile(forReading: systemURL)
            let micFile = try AVAudioFile(forReading: micURL)
            let sysFmt = sysFile.processingFormat
            let micFmt = micFile.processingFormat
            dbg("merge: sys=\(sysFmt.sampleRate)Hz \(sysFmt.channelCount)ch, mic=\(micFmt.sampleRate)Hz \(micFmt.channelCount)ch")

            let sysFrames = AVAudioFrameCount(sysFile.length)
            let micFrames = AVAudioFrameCount(micFile.length)

            // Read system audio
            guard let sysBuf = AVAudioPCMBuffer(pcmFormat: sysFmt, frameCapacity: sysFrames) else { return false }
            try sysFile.read(into: sysBuf)

            // Read mic audio
            guard let micBuf = AVAudioPCMBuffer(pcmFormat: micFmt, frameCapacity: micFrames) else { return false }
            try micFile.read(into: micBuf)

            // Output format matches system audio (48kHz stereo Float32)
            let outFormat = sysFmt
            // Calculate mic frame count at output sample rate
            let micFramesResampled = AVAudioFrameCount(Double(micFrames) * outFormat.sampleRate / micFmt.sampleRate)
            let maxFrames = max(sysFrames, micFramesResampled)

            // Resample mic if needed using AVAudioConverter
            let micResampled: AVAudioPCMBuffer
            if micFmt.sampleRate != outFormat.sampleRate || micFmt.channelCount != outFormat.channelCount {
                guard let converter = AVAudioConverter(from: micFmt, to: outFormat) else {
                    dbg("merge: failed to create converter"); return false
                }
                guard let buf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: micFramesResampled + 1024) else { return false }
                var error: NSError?
                var allRead = false
                converter.convert(to: buf, error: &error) { _, outStatus in
                    if allRead {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    outStatus.pointee = .haveData
                    allRead = true
                    return micBuf
                }
                if let error { dbg("merge: converter error: \(error)") }
                micResampled = buf
                dbg("merge: mic resampled to \(buf.frameLength) frames")
            } else {
                micResampled = micBuf
            }

            // Mix into output buffer
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: maxFrames) else { return false }
            outBuf.frameLength = maxFrames

            let sysData = sysBuf.floatChannelData!
            let micData = micResampled.floatChannelData!
            let outData = outBuf.floatChannelData!
            let sysLen = Int(sysBuf.frameLength)
            let micLen = Int(micResampled.frameLength)

            for ch in 0..<Int(outFormat.channelCount) {
                let sysCh = ch < Int(sysFmt.channelCount) ? ch : 0
                let micCh = ch < Int(micResampled.format.channelCount) ? ch : 0
                for i in 0..<Int(maxFrames) {
                    let s: Float = i < sysLen ? sysData[sysCh][i] : 0
                    let m: Float = i < micLen ? micData[micCh][i] : 0
                    outData[ch][i] = s + m
                }
            }

            // Write as M4A
            let outFile = try AVAudioFile(forWriting: outputURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: outFormat.sampleRate,
                AVNumberOfChannelsKey: outFormat.channelCount,
                AVEncoderBitRateKey: 256000
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try outFile.write(from: outBuf)
            dbg("merge: PCM mix succeeded, \(maxFrames) frames written")
            return true
        } catch {
            dbg("merge: PCM mix FAILED: \(error)")
            return false
        }
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

// MARK: - ScreenCaptureKit Audio Delegate

class SystemAudioDelegate: NSObject, SCStreamOutput {
    private var audioFile: AVAudioFile?
    private var cachedFormat: AVAudioFormat?
    private let outputURL: URL
    private var callbackCount = 0

    init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only process audio buffers
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }

        guard let formatDesc = sampleBuffer.formatDescription,
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let format: AVAudioFormat
        if let cached = cachedFormat {
            format = cached
        } else {
            guard let f = AVAudioFormat(streamDescription: asbdPtr) else { return }
            cachedFormat = f
            format = f
        }

        // Lazy-init audio file on first callback
        if audioFile == nil {
            audioFile = try? AVAudioFile(forWriting: outputURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            if audioFile != nil {
                dbg("scDelegate: audio file created, \(format.sampleRate)Hz \(format.channelCount)ch")
            } else {
                dbg("scDelegate: failed to create audio file")
                return
            }
        }

        // Convert CMSampleBuffer to AVAudioPCMBuffer
        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        let abl = pcmBuffer.mutableAudioBufferList
        let copyErr = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frameCount), into: abl)
        guard copyErr == noErr else { return }

        callbackCount += 1

        try? audioFile?.write(from: pcmBuffer)
    }

    func closeFile() {
        dbg("scDelegate: closed, total cb=\(callbackCount)")
        audioFile = nil
    }
}

// MARK: - Editor View

struct EditorView: View {
    @EnvironmentObject var vm: EditorViewModel

    /// Window widths below this force the sidebar closed even if the user had
    /// it open; 220pt sidebar + ~340pt minimum editor room = 560pt.
    private let sidebarAutoHideThreshold: CGFloat = 560

    var body: some View {
        GeometryReader { geo in
            content
                .onAppear {
                    vm.windowContentWidth = geo.size.width
                    evaluateAutoHide(width: geo.size.width)
                    vm.normalizeFilledPanelWidths()
                    applyWindowTheme(vm.theme)
                }
                .onChange(of: geo.size.width) { _, newWidth in
                    vm.windowContentWidth = newWidth
                    evaluateAutoHide(width: newWidth)
                    vm.normalizeFilledPanelWidths()
                }
                .onChange(of: vm.theme) { _, newTheme in
                    applyWindowTheme(newTheme)
                }
        }
        .preferredColorScheme(vm.theme.swiftUIScheme)
    }

    private func applyWindowTheme(_ theme: AppTheme) {
        NSApp.windows.forEach { win in
            win.backgroundColor = theme.windowNSColor
        }
    }

    /// Only the WINDOW's width hides the sidebar. Keying it off the room left for
    /// the note as well sounded right and was wrong: with a terminal and a
    /// browser open the note is always starved, so the sidebar hid itself on
    /// every launch. Panels give up their width instead — that is what
    /// `panelWidths()` reserves the sidebar and the editor floor for.
    private func evaluateAutoHide(width: CGFloat) {
        let shouldAutoHide = width < sidebarAutoHideThreshold
        if shouldAutoHide && !vm.isSidebarCollapsed {
            withAnimation(.easeInOut(duration: 0.18)) {
                vm.isSidebarAutoHidden = true
                vm.isSidebarCollapsed = true
            }
        } else if !shouldAutoHide && vm.isSidebarAutoHidden {
            withAnimation(.easeInOut(duration: 0.18)) {
                vm.isSidebarAutoHidden = false
                vm.isSidebarCollapsed = false
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // One bar, the width of the WINDOW, above every column — sidebar
            // included. Inside the editor column it was sized by whatever the
            // panels left over, so the narrower that column got the more of the
            // note's own controls vanished into the overflow chevron. The panels
            // keep their own tab rows: a terminal's chips and a browser's URL
            // field say WHICH conversation and WHICH page, and that only means
            // something directly above the thing it belongs to.
            FormatToolbar()
            Divider()
            if vm.isBrowserFullScreen && vm.isBrowserVisible {
                // Everything else stands down; the toolbar stays, so the way
                // back is where every other panel toggle already lives.
                BrowserPanel()
                    .environmentObject(vm)
            } else {
            HStack(spacing: 0) {
                if !vm.isSidebarCollapsed {
                    NotesSidebar()
                        // Priority 1: yields to the panels' 2, wins over the
                        // editor's 0. Enough to stop the sidebar being squeezed
                        // to a sliver, without the hard minimum that pushed the
                        // window off the screen.
                        .frame(width: vm.sidebarWidth)
                        .layoutPriority(1)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    SidebarResizeHandle()
                        .environmentObject(vm)
                }
                if vm.isEditorVisible {
                VStack(spacing: 0) {
                    if vm.isRecording && vm.activeTabId == vm.recordingTabId {
                        RecordingInProgressView(startTime: vm.recordingStartTime ?? Date())
                        Divider()
                    } else if vm.isSavingRecording {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Saving recording…")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(vm.theme.chromeBackground)
                        .task {
                            try? await Task.sleep(nanoseconds: 10_000_000_000)
                            vm.isSavingRecording = false
                        }
                        Divider()
                    } else if let tab = vm.activeTab, !tab.recordingPaths.isEmpty {
                        RecordingsListView(tab: tab)
                            .id(tab.id)
                        Divider()
                    }
                    // The board is a window of its own (see BoardWindowController);
                    // the editor column always shows the note's text.
                    RichTextEditor()
                        .environmentObject(vm)
                }
                // The editor is the flexible column and must be the one that
                // yields — in BOTH directions. `.frame(width:)` on a panel is
                // only a proposal, so without the priority the HStack honoured
                // the editor and squeezed the panels to a couple of wrapped
                // words each; and without `minWidth: 0` the editor's own
                // intrinsic minimum (its toolbar) pushed the browser panel past
                // the right edge of the window, which read as a clipped page.
                .frame(minWidth: 0, maxWidth: .infinity)
                .layoutPriority(0)
                .transition(.opacity)
                }
                if vm.isTerminalVisible && !vm.terminalTabs.isEmpty {
                    TerminalResizeHandle()
                        .environmentObject(vm)
                }
                if vm.isTerminalVisible && !vm.terminalTabs.isEmpty {
                    // Fully unmount the panel on hide. Shells are kept alive by
                    // `TerminalSessions` (not the view), so unmounting is safe and
                    // it cleanly removes the terminal view from the window —
                    // resigning first responder so input stays responsive. On show
                    // the persistent session view is re-attached.
                    TerminalPanel()
                        .environmentObject(vm)
                        // A PROPOSAL, not a minimum. A hard `minWidth` here
                        // propagates up as the window's minimum content size, so
                        // macOS grew the window to fit the panels — past the edge
                        // of the display — and because the wider window then
                        // satisfied the budget, it never shrank back. Priority is
                        // what makes the panels win against the editor; the
                        // budget in `panelWidths()` is what keeps them honest.
                        .frame(width: vm.panelWidths().terminal)
                        .layoutPriority(2)
                }
                if vm.isBrowserVisible {
                    BrowserResizeHandle()
                        .environmentObject(vm)
                    // Pages live in `BrowserSessions`, so unmounting the panel
                    // on hide costs nothing — same contract as the terminal.
                    BrowserPanel()
                        .environmentObject(vm)
                        .frame(width: vm.panelWidths().browser)
                        .layoutPriority(2)
                }
            }
            }
            Divider()
            StatusBar()
        }
        .frame(minWidth: 0, minHeight: 0)
    }
}

// MARK: - Sidebar Resize Handle

struct SidebarResizeHandle: View {
    @EnvironmentObject var vm: EditorViewModel
    @State private var isDragging = false
    @State private var startWidth: CGFloat = 0

    private let minWidth: CGFloat = 160
    private let maxWidth: CGFloat = 420
    private let hitWidth: CGFloat = 6

    var body: some View {
        ZStack {
            // Hairline divider line for visual continuity
            Rectangle()
                .fill(Color.primary.opacity(0.25))
                .frame(width: 1)
            // Wider invisible hit-area for easy grabbing
            Color.clear
                .frame(width: hitWidth)
                .contentShape(Rectangle())
        }
        .frame(width: hitWidth)
        .onHover { hovering in
            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        startWidth = vm.sidebarWidth
                    }
                    let proposed = startWidth + value.translation.width
                    let clamped = min(maxWidth, max(minWidth, proposed))
                    if abs(clamped - vm.sidebarWidth) > 0.5 {
                        vm.sidebarWidth = clamped
                    }
                }
                .onEnded { _ in isDragging = false }
        )
    }
}

// MARK: - Terminal Panel (right side)

/// The editor↔panel boundary handle. Dragging resizes the whole terminal panel
/// against the editor; capped so the panel never outgrows the window.
struct TerminalResizeHandle: View {
    @EnvironmentObject var vm: EditorViewModel

    @State private var isDragging = false
    @State private var isHovering = false
    @State private var startWidth: CGFloat = 0

    private let minWidth: CGFloat = EditorViewModel.minTerminalColumnWidth
    private let maxWidth: CGFloat = 1600
    private let hitWidth: CGFloat = 10

    var body: some View {
        ZStack {
            Rectangle()
                .fill(
                    isDragging ? Color.accentColor.opacity(0.7) :
                    isHovering ? Color.accentColor.opacity(0.4) :
                    Color.primary.opacity(0.35)
                )
                .frame(width: (isHovering || isDragging) ? 3 : 2)
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .animation(.easeOut(duration: 0.12), value: isDragging)
            Color.clear
                .frame(width: hitWidth)
                .contentShape(Rectangle())
        }
        .frame(width: hitWidth)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging { isDragging = true; startWidth = vm.terminalWidth }
                    // Drag-left → wider (subtract dx); cap to the window.
                    let dx = value.translation.width
                    vm.setTerminalWidth(min(maxWidth, max(minWidth, startWidth - dx)))
                }
                .onEnded { _ in isDragging = false }
        )
    }
}

struct TerminalPanel: View {
    @EnvironmentObject var vm: EditorViewModel
    @ObservedObject private var handsfree = HandsfreeManager.shared
    /// Bumped by `.floatnoteTerminalPaletteChanged` purely to re-evaluate the
    /// body — the palette lives in `TerminalSessions`, not in SwiftUI state.
    @State private var paletteGeneration = 0

    private var palette: TerminalPalette {
        _ = paletteGeneration
        return TerminalSessions.currentPalette()
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if handsfree.isEnabled {
                HandsfreeBar()
                Divider()
            }
            if let activeId = vm.activeTerminalId,
               let tab = vm.terminalTabs.first(where: { $0.id == activeId }) {
                // Transcript above, terminal below — the split is vertical
                // because a side-by-side one would drop the terminal under 80
                // columns and wreck Claude Code's own box drawing.
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        if vm.transcriptMode == .split {
                            TranscriptPane()
                                // One clamp, shared with the handle, so a stored
                                // fraction can never render a terminal without an
                                // output area — or a transcript too short to read.
                                .frame(height: TranscriptSplitHandle.transcriptHeight(
                                    in: geo.size.height, fraction: vm.transcriptSplitFraction))
                            TranscriptSplitHandle(totalHeight: geo.size.height)
                        }
                        terminalSurface(tab)
                    }
                }
            } else {
                palette.backgroundColor
            }
        }
        // Repaint when the palette changes under us (appearance menu, or the
        // app theme flipping): TerminalSessions owns the colors, not this view.
        .onReceive(NotificationCenter.default.publisher(for: .floatnoteTerminalPaletteChanged)) { _ in
            paletteGeneration &+= 1
        }
    }

    /// The terminal itself, unchanged — just lifted out so the split can place it.
    private func terminalSurface(_ tab: TerminalTab) -> some View {
        SwiftTermContainer(id: tab.id, cwd: tab.path, freshClaude: tab.freshClaude)
            .id(tab.id)
            .background(palette.backgroundColor)
            // Scrolled up? Say how far behind the live output we are.
            .overlay(alignment: .bottomTrailing) {
                TerminalScrollPill(terminalId: tab.id)
            }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(vm.terminalTabs) { tab in
                tabChip(tab)
                Divider().frame(height: 20)
            }
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) { vm.addTerminal() }
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .frame(width: 30, height: 28)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("New terminal at current route")
            Spacer(minLength: 0)
            transcriptModeControl
            if vm.transcriptMode == .split { transcriptSizeControls }
            // `terminalFontButton` is deliberately not in the bar: the palette
            // follows the app theme and SF Mono 13 is settled, so the menu was
            // only clutter. The menu itself still builds — put the button back
            // here to expose it again.
        }
        .background(vm.theme.chromeBackground)
    }

    /// Terminal / split / transcript. Three states, one button — cycling beats a
    /// segmented control here because the tab bar is already crowded and this is
    /// a view toggle, not a setting.
    private var transcriptModeControl: some View {
        Button(action: { vm.cycleTranscriptMode() }) {
            Image(systemName: vm.transcriptMode.symbol)
                .font(.system(size: 11))
                .frame(width: 28, height: 28)
                .foregroundColor(vm.transcriptMode == .terminal ? .secondary : .accentColor)
        }
        .buttonStyle(.plain)
        .help(vm.transcriptMode.help)
    }

    /// A−/A+ for the transcript, shown only while it is on screen. The Aa menu
    /// holds the same commands, but reading size is adjusted often enough that
    /// digging two levels into a popup for it is the wrong shape.
    private var transcriptSizeControls: some View {
        HStack(spacing: 0) {
            stepButton("textformat.size.smaller", help: "Smaller text — transcript and terminal (⌘−)") {
                TerminalFontMenuTarget.stepPanelText(-1)
            }
            stepButton("textformat.size.larger", help: "Bigger text — transcript and terminal (⌘+)") {
                TerminalFontMenuTarget.stepPanelText(1)
            }
        }
    }

    private func stepButton(_ symbol: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 24, height: 28)
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Font/size picker for every pane. Trailing edge of the tab bar, away from
    /// the chips so it can't be hit while switching terminals.
    private var terminalFontButton: some View {
        Button(action: {
            TerminalFontMenuTarget.shared.makeMenu()
                .popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }) {
            Image(systemName: "textformat.size")
                .font(.system(size: 11))
                .frame(width: 28, height: 28)
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help("Terminal font")
    }

    private func chipGlyph(isActive: Bool) -> some View {
        Image(systemName: "terminal")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(isActive ? .accentColor : .secondary)
    }

    private func tabChip(_ tab: TerminalTab) -> some View {
        let isActive = vm.activeTerminalId == tab.id
        // The active chip reads as the top edge of the terminal surface, so it
        // is painted in the *terminal's* palette — not a hardcoded black slab,
        // which under a light app theme left black-on-black label text.
        let onSurface = palette.foregroundColor
        return HStack(spacing: 6) {
            // A spinner in place of the glyph while that pane's Claude is
            // working — including panes you are not looking at, which is the
            // whole point: two agents running and you can see which one is busy.
            if let since = vm.paneActivity[tab.id] {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if vm.isPaneWorking(tab.id, now: context.date) {
                        TerminalChipSpinner(active: isActive)
                    } else {
                        chipGlyph(isActive: isActive)
                    }
                }
                .id(since)
            } else {
                chipGlyph(isActive: isActive)
            }
            Text(tab.label)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? onSurface : .secondary)
                .lineLimit(1)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) { vm.closeTerminal(tab.id) }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundColor(isActive ? onSurface.opacity(0.6) : .secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Close this terminal")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: 180)
        .background(isActive ? palette.backgroundColor : Color.clear)
        .overlay(alignment: .top) {
            if isActive { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .opacity(vm.draggingTerminalId == tab.id ? 0.4 : 1)
        .contentShape(Rectangle())
        .onTapGesture { vm.selectTerminal(tab.id) }
        .help(tab.path)
        .onDrag {
            vm.draggingTerminalId = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: TerminalTabDropDelegate(tab: tab, vm: vm))
    }
}

/// Reorders terminal chips as the drag passes over them, so the bar rearranges
/// under the cursor instead of waiting for the drop.
/// The chip's working indicator: the same rotating asterisk the transcript pill
/// uses, so "busy" looks the same wherever it appears.
struct TerminalChipSpinner: View {
    let active: Bool
    @State private var spin = false

    var body: some View {
        Image(systemName: "asterisk")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(active ? .accentColor : .secondary)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { spin = true }
            }
    }
}

struct TerminalTabDropDelegate: DropDelegate {
    let tab: TerminalTab
    let vm: EditorViewModel

    func dropEntered(info: DropInfo) {
        guard let dragId = vm.draggingTerminalId, dragId != tab.id else { return }
        vm.moveTerminal(from: dragId, to: tab.id)
    }

    func performDrop(info: DropInfo) -> Bool {
        vm.draggingTerminalId = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func validateDrop(info: DropInfo) -> Bool { true }
    func dropExited(info: DropInfo) {}
}

extension Notification.Name {
    static let floatnoteTerminalReset = Notification.Name("floatnote.terminal.reset")
    /// Posted (object = recording path String) when a recording row starts
    /// playing, so every other row pauses — one audio at a time.
    static let floatnoteRowPlaybackStarted = Notification.Name("floatnote.recording.rowPlaybackStarted")
}

// MARK: - Notes Sidebar

struct NotesSidebar: View {
    @EnvironmentObject var vm: EditorViewModel

    /// Notes that are not inside any folder (rendered at the root level).
    private var rootTabs: [NoteTab] { vm.tabs.filter { $0.folderId == nil } }
    /// Live (non-trashed) top-level folders. Subfolders are rendered recursively
    /// inside their parent by `SidebarFolderView`.
    private var liveRootFolders: [Folder] { vm.folders.filter { !$0.isTrashed && $0.parentId == nil } }
    /// Trashed folders that are the *root* of a trashed subtree (their parent is
    /// not itself trashed), so a cascade-trashed subtree shows as one entry.
    private var trashedRootFolders: [Folder] {
        vm.folders.filter { f in
            f.isTrashed && (f.parentId == nil
                || vm.folders.first(where: { $0.id == f.parentId })?.isTrashed != true)
        }
    }
    /// Notes that were trashed individually (loose) — not via their folder.
    private var looseTrashedTabs: [NoteTab] { vm.tabs.filter { $0.folderId == TRASH_FOLDER_ID } }
    private var trashItemCount: Int {
        let trashedFolderIds = Set(vm.folders.filter { $0.isTrashed }.map { $0.id })
        let inTrashedFolders = vm.tabs.filter {
            $0.folderId.map { trashedFolderIds.contains($0) } ?? false
        }.count
        return trashedFolderIds.count + looseTrashedTabs.count + inTrashedFolders
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text("NOTES")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .kerning(0.6)
                Spacer()
                Button(action: { vm.addFolder() }) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11))
                        .frame(width: 22, height: 22)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("New folder")
                Button(action: { vm.addTab() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .frame(width: 22, height: 22)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("New note")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    // Top-level folders first, each with its subfolders + notes nested inside.
                    ForEach(liveRootFolders) { folder in
                        SidebarFolderView(folder: folder)
                            .id(folder.id)
                    }

                    // Root-level notes (not in any folder).
                    ForEach(rootTabs) { tab in
                        SidebarNoteItemView(tab: tab)
                            .id(tab.id)
                    }

                    // Trash section (always pinned at the bottom).
                    SidebarTrashSection(
                        trashedFolders: trashedRootFolders,
                        looseTrashedTabs: looseTrashedTabs,
                        itemCount: trashItemCount
                    )
                    .padding(.top, 8)
                }
                .padding(4)
            }
            // Dropping a note onto the empty sidebar area moves it to root.
            .onDrop(of: [.text], delegate: FolderDropDelegate(folderId: nil, vm: vm))
        }
        .background(vm.theme.chromeBackground)
        .alert(
            "Permanently delete folder?",
            isPresented: Binding(
                get: { vm.folderPendingDeletion != nil },
                set: { if !$0 { vm.folderPendingDeletion = nil } }
            ),
            presenting: vm.folderPendingDeletion
        ) { folder in
            Button("Delete Permanently", role: .destructive) {
                vm.permanentlyDeleteFolder(folder.id)
                vm.folderPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { vm.folderPendingDeletion = nil }
        } message: { folder in
            Text("\"\(folder.name)\" and all notes inside will be permanently removed. This cannot be undone.")
        }
        .alert(
            "Empty Trash?",
            isPresented: $vm.emptyTrashConfirming
        ) {
            Button("Empty Trash", role: .destructive) { vm.emptyTrash() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All notes and folders in the Trash will be permanently deleted. This cannot be undone.")
        }
    }
}

// MARK: - Sidebar Folder Row

struct SidebarFolderView: View {
    @ObservedObject var folder: Folder
    @EnvironmentObject var vm: EditorViewModel
    @FocusState private var isFieldFocused: Bool
    /// Rename buffer. Editing must NOT write straight through to `folder.name`,
    /// or clearing the field destroys the old name before submit can fall back
    /// to it.
    @State private var draftName: String = ""

    private var tabsInFolder: [NoteTab] { vm.tabs.filter { $0.folderId == folder.id } }
    /// Live subfolders nested directly under this folder.
    private var subfolders: [Folder] { vm.folders.filter { !$0.isTrashed && $0.parentId == folder.id } }
    /// A folder row has no "selected" state — the only thing that fills it is an
    /// in-flight drag. The `isDragging` gate makes a leaked `dropTargetFolderId`
    /// unpaintable, so a forgotten reset can never look like a selection.
    private var isDropTarget: Bool { vm.dropTargetFolderId == folder.id && vm.isDragging }
    /// Measured height of the header row, used to split it into the
    /// above / inside / below drop zones.
    @State private var rowHeight: CGFloat = 0
    /// Edge to draw the sibling insertion line on, if this row is the target.
    private var insertEdge: Bool? {
        guard vm.isDragging, let ind = vm.folderInsertIndicator, ind.id == folder.id else { return nil }
        return ind.below
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Button(action: { vm.toggleFolderExpanded(folder.id) }) {
                    Image(systemName: folder.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 12)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                if vm.editingFolderId == folder.id {
                    TextField("", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .focused($isFieldFocused)
                        .onSubmit { vm.renameFolder(folder.id, to: draftName) }
                        .onAppear { draftName = folder.name; isFieldFocused = true }
                } else {
                    Text(folder.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                if let lp = folder.localPath {
                    Image(systemName: "link")
                        .font(.system(size: 9))
                        .foregroundColor(.accentColor)
                        .help((lp as NSString).abbreviatingWithTildeInPath)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isDropTarget ? Color.accentColor.opacity(0.22) : Color.clear)
            )
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear { rowHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in rowHeight = h }
                }
            )
            // Sibling drop target: a line on the edge the folder would land on.
            .overlay(alignment: insertEdge == true ? .bottom : .top) {
                if insertEdge != nil {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { vm.editingFolderId = folder.id }
            .onTapGesture(count: 1) {
                if vm.editingFolderId != folder.id { vm.toggleFolderExpanded(folder.id) }
            }
            .contextMenu {
                Button("Rename") { vm.editingFolderId = folder.id }
                Divider()
                if folder.localPath == nil {
                    Button("Link Local Folder…") { pickFolderForLink() }
                } else {
                    Button("Change Folder…") { pickFolderForLink() }
                    Button("Unlink Folder") { vm.unlinkFolder(folder.id) }
                }
                Divider()
                Button("Move Folder to Trash", role: .destructive) {
                    vm.trashFolder(folder.id)
                }
            }
            .onDrop(of: [.text], delegate: FolderDropDelegate(folderId: folder.id, vm: vm, rowHeight: rowHeight))
            .onDrag {
                vm.clearDragIndicators()
                vm.draggingFolderId = folder.id
                return NSItemProvider(object: folder.id.uuidString as NSString)
            }

            if folder.isExpanded {
                // Subfolders first (recursively), then this folder's own notes.
                ForEach(subfolders) { sub in
                    SidebarFolderView(folder: sub)
                        .padding(.leading, 24)
                        .id(sub.id)
                }
                ForEach(tabsInFolder) { tab in
                    SidebarNoteItemView(tab: tab)
                        .padding(.leading, 24)
                        .id(tab.id)
                }
            }
        }
        // Gap after an expanded folder's children so they don't visually bleed
        // into whatever renders next (root notes, sibling folders, parent notes).
        .padding(.bottom, folder.isExpanded && !(subfolders.isEmpty && tabsInFolder.isEmpty) ? 6 : 0)
    }

    /// Native folder picker → link (or re-link) this folder to a local directory.
    private func pickFolderForLink() {
        let panel = NSOpenPanel()
        panel.title = "Link a local folder to “\(folder.name)”"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let cur = folder.localPath { panel.directoryURL = URL(fileURLWithPath: cur) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.linkFolder(folder.id, to: url.path)
    }
}

// MARK: - Folder Drop Delegate

struct FolderDropDelegate: DropDelegate {
    let folderId: UUID?
    let vm: EditorViewModel
    /// Height of the folder header row this delegate is attached to, used to
    /// split it into above / inside / below zones. Zero (the sidebar's empty
    /// area, or a row that hasn't measured yet) disables zoning.
    var rowHeight: CGFloat = 0

    /// Fraction of the row height at each edge that means "drop as a sibling"
    /// rather than "nest inside".
    private static let edgeZone: CGFloat = 0.3

    /// Which of the three zones `location` falls in. Only a dragged *folder*
    /// gets zones — a dragged note always means "move into this folder", from
    /// any vertical position.
    private func siblingEdge(at location: CGPoint) -> Bool? {
        guard vm.draggingFolderId != nil, folderId != nil, rowHeight > 0 else { return nil }
        let edge = rowHeight * Self.edgeZone
        if location.y < edge { return false }        // above
        if location.y > rowHeight - edge { return true }  // below
        return nil                                   // inside
    }

    /// Paint either the nest-inside fill or the sibling insertion line — never both.
    private func updateIndicators(at location: CGPoint) {
        if let below = siblingEdge(at: location), let id = folderId {
            let indicator = EditorViewModel.FolderInsertIndicator(id: id, below: below)
            if vm.dropTargetFolderId != nil { vm.dropTargetFolderId = nil }
            if vm.folderInsertIndicator != indicator { vm.folderInsertIndicator = indicator }
        } else {
            if vm.dropTargetFolderId != folderId { vm.dropTargetFolderId = folderId }
            if vm.folderInsertIndicator != nil { vm.folderInsertIndicator = nil }
        }
    }

    private func clearIndicators() {
        if vm.dropTargetFolderId == folderId { vm.dropTargetFolderId = nil }
        if vm.folderInsertIndicator?.id == folderId { vm.folderInsertIndicator = nil }
    }

    func dropEntered(info: DropInfo) { updateIndicators(at: info.location) }
    func dropExited(info: DropInfo)  { clearIndicators() }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateIndicators(at: info.location)
        return DropProposal(operation: .move)
    }
    func validateDrop(info: DropInfo) -> Bool { true }

    func performDrop(info: DropInfo) -> Bool {
        let edge = siblingEdge(at: info.location)
        let dragFolderId = vm.draggingFolderId
        let dragTabId = vm.draggingTabId
        vm.clearDragIndicators()
        // Dragging a folder → reorder next to this one, or nest it under this
        // folder (root when folderId == nil).
        if let dragFolder = dragFolderId {
            if let below = edge, let targetId = folderId {
                vm.moveFolder(dragFolder, relativeTo: targetId, below: below)
            } else {
                vm.moveFolder(dragFolder, toParent: folderId)
            }
            return true
        }
        // Dragging a note → move it into this folder (or root).
        guard let draggingId = dragTabId else { return false }
        vm.moveTab(draggingId, toFolder: folderId)
        return true
    }
}

/// Red notification pill showing a note's unchecked-checklist-item count.
/// Counts above 99 render as "99+". Hidden by the caller when count is 0.
struct UncheckedBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .monospacedDigit()
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 16)
            .background(
                Capsule().fill(Color(red: 1.0, green: 0.231, blue: 0.188))
            )
    }
}

struct SidebarNoteItemView: View {
    @ObservedObject var tab: NoteTab
    @EnvironmentObject var vm: EditorViewModel
    @FocusState private var isFieldFocused: Bool

    var isActive: Bool { vm.activeTabId == tab.id }
    var isDragging: Bool { vm.draggingTabId == tab.id }
    var isRecordingHere: Bool { vm.isRecording && vm.recordingTabId == tab.id }
    var isJobRunningHere: Bool { !isRecordingHere && tab.isJobActive }

    var body: some View {
        HStack(spacing: 6) {
            if isRecordingHere {
                PulseDot(color: .red)
            } else if isJobRunningHere {
                PulseDot(color: .accentColor)
            } else if !tab.recordingPaths.isEmpty {
                Text("\u{1F3A4}")
                    .font(.system(size: 10))
            }
            if vm.editingTabId == tab.id {
                TextField("", text: $vm.editingTabTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isFieldFocused)
                    .onSubmit { vm.commitTabRename() }
                    .onAppear { isFieldFocused = true }
            } else {
                Text(tab.title)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundColor(
                        isRecordingHere ? .red :
                        (isJobRunningHere ? .accentColor : (isActive ? .primary : .secondary))
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(isJobRunningHere ? (tab.jobStatus ?? "") : "")
            }
            Spacer(minLength: 4)
            if vm.boardHasContent(tab.id) || vm.isBoardOpen(tab.id) {
                // Same grammar as the terminal glyph next to it: accent while
                // this note's board window is up, muted when the note simply
                // has a diagram waiting behind the toolbar button.
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(vm.isBoardOpen(tab.id)
                                     ? .accentColor : .secondary.opacity(0.55))
                    .help(vm.isBoardOpen(tab.id) ? "Diagram window is open" : "Has a diagram")
            }
            if let pane = vm.terminalTab(forNote: tab.id) {
                // Accent when it is the pane on screen, muted when it is one of
                // the others: the difference between "this note's terminal is
                // what you're looking at" and "it has one, somewhere behind".
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(vm.activeTerminalId == pane.id
                                     ? .accentColor : .secondary.opacity(0.55))
                    .help("Terminal: \(pane.label) · \(pane.path)")
            }
            if tab.uncheckedCount > 0 {
                UncheckedBadge(count: tab.uncheckedCount)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .opacity(isDragging ? 0.4 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { vm.beginTabRename(tab.id) }
        .onTapGesture(count: 1) {
            if vm.editingTabId != tab.id { vm.switchTab(tab.id) }
        }
        .onDrag {
            vm.commitTabRename()
            vm.clearDragIndicators()
            vm.draggingTabId = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(tab: tab, vm: vm))
        .contextMenu {
            Button("Rename") { vm.beginTabRename(tab.id) }
            Divider()
            Button("Move to Trash", role: .destructive) {
                vm.trashTab(tab.id)
            }
        }
    }
}

/// Pulsing dot shown in a sidebar note row while something live is happening
/// there (red = recording, accent = job running). Leaving the hierarchy
/// (recording/job ended) kills the animation.
struct PulseDot: View {
    let color: Color
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(dimmed ? 0.25 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

// MARK: - Sidebar Trash Section

/// Pinned section at the bottom of the sidebar that holds trashed folders and
/// loose-trashed notes. The Trash itself is virtual — items are tagged via
/// `Folder.isTrashed` and `NoteTab.folderId == TRASH_FOLDER_ID`.
struct SidebarTrashSection: View {
    @EnvironmentObject var vm: EditorViewModel
    let trashedFolders: [Folder]
    let looseTrashedTabs: [NoteTab]
    let itemCount: Int

    private var isEmpty: Bool { itemCount == 0 }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: vm.isTrashExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 12)
                    .foregroundColor(.secondary)
                Image(systemName: isEmpty ? "trash" : "trash.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("Trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isEmpty ? .secondary : .primary)
                if itemCount > 0 {
                    Text("\(itemCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color.secondary.opacity(0.18))
                        )
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { vm.isTrashExpanded.toggle() }
            .contextMenu {
                Button("Empty Trash…", role: .destructive) {
                    vm.emptyTrashConfirming = true
                }
                .disabled(isEmpty)
            }

            if vm.isTrashExpanded {
                if isEmpty {
                    Text("Trash is empty")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                        .padding(.leading, 26)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(trashedFolders) { folder in
                        SidebarTrashedFolderView(folder: folder)
                            .id(folder.id)
                    }
                    ForEach(looseTrashedTabs) { tab in
                        SidebarTrashedNoteView(tab: tab)
                            .padding(.leading, 16)
                            .id(tab.id)
                    }
                }
            }
        }
    }
}

/// A folder living inside Trash. Shows its (still-attached) notes nested under it.
struct SidebarTrashedFolderView: View {
    @ObservedObject var folder: Folder
    @EnvironmentObject var vm: EditorViewModel

    private var tabsInFolder: [NoteTab] { vm.tabs.filter { $0.folderId == folder.id } }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Button(action: { vm.toggleFolderExpanded(folder.id) }) {
                    Image(systemName: folder.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 12)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.8))
                Text(folder.name)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { vm.toggleFolderExpanded(folder.id) }
            .contextMenu {
                Button("Restore Folder") { vm.restoreFolder(folder.id) }
                Divider()
                Button("Delete Permanently…", role: .destructive) {
                    vm.folderPendingDeletion = folder
                }
            }

            if folder.isExpanded {
                ForEach(tabsInFolder) { tab in
                    SidebarTrashedNoteView(tab: tab, parentTrashedFolder: folder)
                        .padding(.leading, 32)
                        .id(tab.id)
                }
            }
        }
    }
}

/// A trashed note row. If it's a loose-trashed note, Restore lifts it to root;
/// if its parent folder is trashed, Restore lifts the folder back instead.
struct SidebarTrashedNoteView: View {
    @ObservedObject var tab: NoteTab
    var parentTrashedFolder: Folder? = nil
    @EnvironmentObject var vm: EditorViewModel

    var isActive: Bool { vm.activeTabId == tab.id }

    var body: some View {
        HStack(spacing: 6) {
            if !tab.recordingPaths.isEmpty {
                Text("\u{1F3A4}").font(.system(size: 10))
            }
            Text(tab.title)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { vm.switchTab(tab.id) }
        .contextMenu {
            if let parent = parentTrashedFolder {
                Button("Restore Folder \"\(parent.name)\"") {
                    vm.restoreFolder(parent.id)
                }
            } else {
                Button("Restore") { vm.restoreTab(tab.id) }
            }
            Divider()
            Button("Delete Permanently", role: .destructive) {
                vm.permanentlyDeleteTab(tab.id)
            }
        }
    }
}

// MARK: - Tab Bar

// Shared reference to allow programmatic scrolling
class TabScrollState: ObservableObject {
    weak var scrollView: NSScrollView?

    func scroll(by delta: CGFloat) {
        guard let sv = scrollView else { return }
        let current = sv.contentView.bounds.origin.x
        let maxOffset = (sv.documentView?.frame.width ?? 0) - sv.contentView.bounds.width
        let target = max(0, min(maxOffset, current + delta))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sv.contentView.animator().setBoundsOrigin(NSPoint(x: target, y: 0))
        }
    }
}

// NSScrollView wrapper for smooth native horizontal scrolling with momentum
/// NSScrollView that converts vertical mouse wheel to horizontal scrolling.
class HorizontalWheelScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.deltaY) > abs(event.deltaX) {
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)
            let current = contentView.bounds.origin.x
            let maxOffset = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
            let target = max(0, min(maxOffset, current + delta))
            contentView.setBoundsOrigin(NSPoint(x: target, y: 0))
        } else {
            super.scrollWheel(with: event)
        }
    }
}

struct NativeHScrollView<Content: View>: NSViewRepresentable {
    let scrollState: TabScrollState
    let onScroll: (CGFloat, CGFloat, CGFloat) -> Void // (offset, contentWidth, containerWidth)
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = HorizontalWheelScrollView()
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = .init()

        let hostView = NSHostingView(rootView: content)
        hostView.translatesAutoresizingMaskIntoConstraints = false

        let clipView = scrollView.contentView
        clipView.drawsBackground = false

        scrollView.documentView = hostView
        scrollState.scrollView = scrollView

        // Observe scroll changes
        clipView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak scrollView] _ in
            guard let sv = scrollView else { return }
            let offset = sv.contentView.bounds.origin.x
            let contentW = sv.documentView?.frame.width ?? 0
            let containerW = sv.contentView.bounds.width
            onScroll(offset, contentW, containerW)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if let hostView = scrollView.documentView as? NSHostingView<Content> {
            hostView.rootView = content
        }
        scrollState.scrollView = scrollView
        DispatchQueue.main.async {
            if let docView = scrollView.documentView {
                let fitting = docView.fittingSize
                docView.frame.size = NSSize(width: max(fitting.width, scrollView.contentView.bounds.width), height: scrollView.contentView.bounds.height)
            }
            let offset = scrollView.contentView.bounds.origin.x
            let contentW = scrollView.documentView?.frame.width ?? 0
            let containerW = scrollView.contentView.bounds.width
            onScroll(offset, contentW, containerW)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var observer: Any?
        deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }
    }
}

struct TabBar: View {
    @EnvironmentObject var vm: EditorViewModel
    @StateObject private var scrollState = TabScrollState()
    @State private var scrollOffset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private var overflows: Bool { contentWidth > containerWidth + 1 }
    private var clippedLeft: Bool { overflows && scrollOffset > 1 }
    private var clippedRight: Bool { overflows && (scrollOffset + containerWidth) < contentWidth - 1 }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if overflows {
                Button(action: { scrollState.scroll(by: -100) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundColor(clippedLeft ? .secondary : .secondary.opacity(0.2))
            }

            NativeHScrollView(scrollState: scrollState, onScroll: { offset, cw, vw in
                scrollOffset = offset
                contentWidth = cw
                containerWidth = vw
            }) {
                HStack(spacing: 0) {
                    ForEach(vm.visibleTabs) { tab in
                        TabItemView(tab: tab)
                            .id(tab.id)
                    }
                }
            }
            .frame(height: 30)

            if overflows {
                Button(action: { scrollState.scroll(by: 100) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundColor(clippedRight ? .secondary : .secondary.opacity(0.2))
            }

            Button(action: { vm.addTab() }) {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .frame(width: 24, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .background(vm.theme.chromeBackground)
    }
}



struct TabItemView: View {
    @ObservedObject var tab: NoteTab
    @EnvironmentObject var vm: EditorViewModel
    @FocusState private var isFieldFocused: Bool

    var isActive: Bool { vm.activeTabId == tab.id }
    var isDragging: Bool { vm.draggingTabId == tab.id }

    var body: some View {
        HStack(spacing: 4) {
            if vm.editingTabId == tab.id {
                TextField("", text: $vm.editingTabTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(minWidth: 40, maxWidth: 140)
                    .focused($isFieldFocused)
                    .onSubmit { vm.commitTabRename() }
                    .onAppear { isFieldFocused = true }
            } else {
                HStack(spacing: 3) {
                    if !tab.recordingPaths.isEmpty {
                        Text("\u{1F3A4}")
                            .font(.system(size: 9))
                    }
                    Text(tab.title)
                        .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                        .foregroundColor(isActive ? .primary : .secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .padding(.top, 1)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .opacity(isDragging ? 0.4 : 1.0)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.arrow.push() } else { NSCursor.pop() }
        }
        .onTapGesture(count: 2) {
            vm.beginTabRename(tab.id)
        }
        .onTapGesture(count: 1) {
            if vm.editingTabId != tab.id {
                vm.switchTab(tab.id)
            }
        }
        .onDrag {
            vm.commitTabRename()
            vm.clearDragIndicators()
            vm.draggingTabId = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(tab: tab, vm: vm))
    }
}

struct TabDropDelegate: DropDelegate {
    let tab: NoteTab
    let vm: EditorViewModel

    func performDrop(info: DropInfo) -> Bool {
        let dragId = vm.draggingTabId
        // Clears the folder indicators too: the drag may have passed over a
        // folder header on its way here, which would otherwise stay filled.
        vm.clearDragIndicators()
        guard let dragId, dragId != tab.id else { return dragId != nil }
        vm.moveTab(from: dragId, to: tab.id)
        return true
    }

    // Reordering on hover caused a full save and animated sidebar rebuild for
    // every row crossed. Apply the move once, only after the user drops.
    func dropEntered(info: DropInfo) {}

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {}

    func validateDrop(info: DropInfo) -> Bool { true }
}

// MARK: - Status Bar

struct StatusBar: View {
    @EnvironmentObject var vm: EditorViewModel

    var body: some View {
        HStack {
            if vm.isSaving {
                ProgressView().controlSize(.small)
            }
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(vm.status)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            // No trash button here — trashing a note belongs to its sidebar row
            // context menu, not to a status line you brush past with the cursor.
            Text("\(vm.charCount) chars")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
            Text(APP_VERSION)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(vm.theme.chromeBackground)
    }

    var statusColor: Color {
        if vm.status == "Saved" || vm.status == "Loaded" { return .green }
        if vm.status.starts(with: "Edit") || vm.status.starts(with: "Saving") { return .orange }
        if vm.status.starts(with: "Error") || vm.status.starts(with: "Save f") { return .red }
        return .secondary
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight + (i > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width + spacing > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(subview)
            currentWidth += size.width + spacing
        }
        return rows
    }
}

// MARK: - Body Size Picker

struct FontPicker: View {
    @EnvironmentObject var vm: EditorViewModel
    /// Bound to the defaults key rather than held as `@State` so the label also
    /// follows changes made from the toolbar's overflow menu.
    @AppStorage(Tokens.fontFamilyKey) private var current: String = Tokens.systemFontName

    var body: some View {
        Menu {
            ForEach(Tokens.fontOptions, id: \.self) { name in
                Button {
                    Tokens.setFontFamily(name)
                    vm.reloadActive()  // re-render the document in the new font, live
                } label: {
                    HStack {
                        // Preview each option rendered in its own font.
                        if name == Tokens.systemFontName {
                            Text(name).font(.system(size: 13))
                        } else {
                            Text(name).font(.custom(name, size: 13))
                        }
                        if current == name {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(current == Tokens.systemFontName ? "System" : current)
                .font(current == Tokens.systemFontName ? .system(size: 11) : .custom(current, size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(height: 22)
                .padding(.horizontal, 6)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Editor font: \(current)")
    }
}

struct BodySizePicker: View {
    @EnvironmentObject var vm: EditorViewModel
    /// See `FontPicker.current` — bound to defaults so the overflow menu's
    /// "Text Size" submenu updates this label too.
    @AppStorage(Tokens.bodySizeKey) private var currentSize: Double = 14

    var body: some View {
        Menu {
            ForEach(Tokens.bodySizeOptions, id: \.self) { size in
                Button("\(Int(size)) pt") {
                    Tokens.setBodySize(size)
                    vm.reloadActive()
                }
            }
        } label: {
            Text("\(Int(currentSize))pt")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
                .frame(height: 22)
                .padding(.horizontal, 6)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Body font size")
    }
}

// MARK: - Toolbar Overflow

/// One control of the toolbar's scrollable middle zone. Declaration order is
/// toolbar order, and both the inline buttons and the overflow menu are keyed
/// off these cases so a control can never exist in one and be missing from the
/// other.
enum ToolItem: String, CaseIterable, Identifiable {
    case h1, h2, h3, body, font, size
    case bold, italic, underline
    case bullet, check, link, image, divider
    case mic, record

    var id: String { rawValue }
}

/// Frames of the middle-zone controls, measured in the scroll view's own
/// coordinate space — origin is the viewport's left edge, so the values shift
/// as the user scrolls and a control is off-screen exactly when its frame
/// leaves `0..<viewportWidth`.
struct ToolItemFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Width of the visible part of the scroll zone.
struct ToolViewportKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Report this control's frame so `FormatToolbar` can tell whether it is
    /// still inside the visible part of the scroll zone.
    func overflowTracked(_ item: ToolItem, space: String) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ToolItemFramesKey.self,
                    value: [item.rawValue: geo.frame(in: .named(space))]
                )
            }
        )
    }
}

// MARK: - Format Toolbar

struct FormatToolbar: View {
    @EnvironmentObject var vm: EditorViewModel
    @ObservedObject private var handsfree = HandsfreeManager.shared
    @AppStorage("FloatNoteAgent") private var terminalAgent = "codex"
    @State private var hoveredButton: String?

    /// Controls currently scrolled/clipped out of the middle zone. Drives the
    /// `chevron.down` overflow menu; empty = no caret.
    @State private var hiddenItems: [ToolItem] = []
    @State private var itemFrames: [String: CGRect] = [:]
    @State private var viewportWidth: CGFloat = 0

    private let scrollSpace = "fn.toolbarScroll"

    var body: some View {
        HStack(spacing: 0) {
            // Leading: the column toggles and the note's working directory
            // (fixed, always visible). The folder chip belongs here, at the
            // start: it says WHERE this note works, which is context for
            // everything to its right, not another action at the end of the row.
            sidebarToggle
            editorToggle
            folderChip

            thinDivider()

            // Flexible middle zone — takes whatever width the fixed trailing
            // controls leave over, and scrolls whatever doesn't fit.
            middleZone

            // Trailing: overflow caret + board toggle + terminal toggle
            // (+ new terminal) + hands-free + theme + pin + folder chip.
            trailingControls
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(vm.theme.chromeBackground)
    }

    /// The scrollable format groups. Every control reports its frame through
    /// `overflowTracked` so `recomputeHidden()` knows what fell out of view.
    private var middleZone: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                Group {
                    toolBtn("H1", id: "h1") { vm.performFormat(.heading1) }
                        .overflowTracked(.h1, space: scrollSpace)
                    toolBtn("H2", id: "h2") { vm.performFormat(.heading2) }
                        .overflowTracked(.h2, space: scrollSpace)
                    toolBtn("H3", id: "h3") { vm.performFormat(.heading3) }
                        .overflowTracked(.h3, space: scrollSpace)
                    toolBtn("Body", id: "body") { vm.performFormat(.body) }
                        .overflowTracked(.body, space: scrollSpace)
                    FontPicker().environmentObject(vm)
                        .overflowTracked(.font, space: scrollSpace)
                    BodySizePicker().environmentObject(vm)
                        .overflowTracked(.size, space: scrollSpace)
                }

                thinDivider()

                Group {
                    iconBtn("bold", id: "bold") { vm.performFormat(.bold) }
                        .overflowTracked(.bold, space: scrollSpace)
                    iconBtn("italic", id: "italic") { vm.performFormat(.italic) }
                        .overflowTracked(.italic, space: scrollSpace)
                    iconBtn("underline", id: "underline") { vm.performFormat(.underline) }
                        .overflowTracked(.underline, space: scrollSpace)
                }

                thinDivider()

                Group {
                    iconBtn("list.bullet", id: "bullet") { vm.performFormat(.bulletList) }
                        .overflowTracked(.bullet, space: scrollSpace)
                    iconBtn("checklist", id: "check") { vm.performFormat(.checklist) }
                        .overflowTracked(.check, space: scrollSpace)
                    iconBtn("link", id: "link") { vm.performFormat(.link) }
                        .overflowTracked(.link, space: scrollSpace)
                    iconBtn("photo", id: "image") { vm.attachImage() }
                        .overflowTracked(.image, space: scrollSpace)
                    iconBtn("minus", id: "divider") { vm.performFormat(.divider) }
                        .overflowTracked(.divider, space: scrollSpace)
                }

                thinDivider()

                Group {
                    micButton.overflowTracked(.mic, space: scrollSpace)
                    recordButton.overflowTracked(.record, space: scrollSpace)
                }
            }
        }
        .coordinateSpace(name: scrollSpace)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ToolViewportKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(ToolItemFramesKey.self) { frames in
            itemFrames = frames
            recomputeHidden()
        }
        .onPreferenceChange(ToolViewportKey.self) { width in
            viewportWidth = width
            recomputeHidden()
        }
    }

    /// Fixed controls. Higher layout priority than the (greedy) scroll zone so
    /// these are never the ones squeezed off the edge — the caret in particular
    /// has to stay reachable, since it's the only way back to what got clipped.
    private var trailingControls: some View {
        HStack(spacing: 0) {
            overflowMenu
            boardButton
            terminalButton
            newTerminalButton
            browserButton
            agentMenu
            handsfreeButton
            themeButton
            pinButton
        }
        .layoutPriority(1)
    }

    /// Recompute which middle-zone controls sit outside the visible viewport.
    ///
    /// Showing the caret shrinks that viewport, which can push one more control
    /// out — that converges rather than oscillating, because a viewport wide
    /// enough to hide nothing *with* the caret hides nothing without it either.
    /// Caret exposing whatever the middle zone clipped, so a narrow window
    /// hides controls rather than losing them. Absent entirely while everything
    /// fits — an always-on caret would be a permanent dead affordance.
    @ViewBuilder
    private var overflowMenu: some View {
        if !hiddenItems.isEmpty {
            Menu {
                ForEach(hiddenItems) { item in
                    overflowEntry(item)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11))
                    .frame(width: 22, height: 22)
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More controls")
        }
    }

    /// One overflow row per clipped control, mirroring what the control itself
    /// does. The two pickers keep their nested shape as submenus; everything
    /// else is a single action.
    @ViewBuilder
    private func overflowEntry(_ item: ToolItem) -> some View {
        switch item {
        case .h1:
            Button("Heading 1") { vm.performFormat(.heading1) }
        case .h2:
            Button("Heading 2") { vm.performFormat(.heading2) }
        case .h3:
            Button("Heading 3") { vm.performFormat(.heading3) }
        case .body:
            Button("Body") { vm.performFormat(.body) }
        case .font:
            Menu("Font") {
                ForEach(Tokens.fontOptions, id: \.self) { name in
                    Button(name) {
                        Tokens.setFontFamily(name)
                        vm.reloadActive()
                    }
                }
            }
        case .size:
            Menu("Text Size") {
                ForEach(Tokens.bodySizeOptions, id: \.self) { size in
                    Button("\(Int(size)) pt") {
                        Tokens.setBodySize(size)
                        vm.reloadActive()
                    }
                }
            }
        case .bold:
            Button { vm.performFormat(.bold) } label: { Label("Bold", systemImage: "bold") }
        case .italic:
            Button { vm.performFormat(.italic) } label: { Label("Italic", systemImage: "italic") }
        case .underline:
            Button { vm.performFormat(.underline) } label: { Label("Underline", systemImage: "underline") }
        case .bullet:
            Button { vm.performFormat(.bulletList) } label: { Label("Bullet List", systemImage: "list.bullet") }
        case .check:
            Button { vm.performFormat(.checklist) } label: { Label("Checklist", systemImage: "checklist") }
        case .link:
            Button { vm.performFormat(.link) } label: { Label("Link", systemImage: "link") }
        case .image:
            Button { vm.attachImage() } label: { Label("Insert Image", systemImage: "photo") }
        case .divider:
            Button { vm.performFormat(.divider) } label: { Label("Divider", systemImage: "minus") }
        case .mic:
            Button {
                toggleDictation()
            } label: {
                Label(vm.isDictating ? "Stop Dictation" : "Start Dictation",
                      systemImage: vm.isDictating ? "mic.fill" : "mic")
            }
        case .record:
            Button {
                if vm.recordPermissionDenied {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                } else if vm.isRecording {
                    Task { await vm.stopRecording() }
                } else {
                    Task { await vm.startRecording() }
                }
            } label: {
                Label(vm.recordPermissionDenied ? "Microphone Settings…"
                        : (vm.isRecording ? "Stop Recording" : "Record"),
                      systemImage: vm.isRecording ? "stop.circle.fill" : "record.circle")
            }
        }
    }

    private func recomputeHidden() {
        guard viewportWidth > 0, !itemFrames.isEmpty else { return }
        let next = ToolItem.allCases.filter { item in
            guard let f = itemFrames[item.rawValue] else { return false }
            return f.minX < -0.5 || f.maxX > viewportWidth + 0.5
        }
        if next != hiddenItems { hiddenItems = next }
    }

    private var sidebarToggle: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) { vm.isSidebarCollapsed.toggle() }
        }) {
            Image(systemName: vm.isSidebarCollapsed ? "sidebar.left" : "sidebar.leading")
                .font(.system(size: 11))
                .frame(width: 26, height: 22)
                .foregroundColor(.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hoveredButton == "sidebar" ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hoveredButton = $0 ? "sidebar" : nil }
        .help(vm.isSidebarCollapsed ? "Show notes sidebar" : "Hide notes sidebar")
    }

    /// Hide the note column itself. Disabled while it is the only thing left —
    /// a window showing nothing but a sidebar is a dead end you would have to
    /// hunt for the way out of.
    private var editorToggle: some View {
        let canToggle = vm.canHideEditor || !vm.isEditorVisible
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) { vm.toggleEditor() }
        }) {
            Image(systemName: vm.isEditorVisible ? "note.text" : "note")
                .font(.system(size: 11))
                .frame(width: 26, height: 22)
                .foregroundColor(canToggle ? (vm.isEditorVisible ? .secondary : .accentColor)
                                           : Color.secondary.opacity(0.35))
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hoveredButton == "editorColumn" ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canToggle)
        .onHover { hoveredButton = $0 ? "editorColumn" : nil }
        .help(canToggle
              ? (vm.isEditorVisible ? "Hide the note" : "Show the note")
              : "Open the terminal or the browser first")
    }

    private var micButton: some View {
        Button(action: { toggleDictation() }) {
            Image(systemName: vm.isDictating ? "mic.fill" : "mic")
                .font(.system(size: 11))
                .frame(width: 26, height: 22)
                .foregroundColor(vm.isDictating ? .red : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hoveredButton == "mic" ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hoveredButton = $0 ? "mic" : nil }
        .help(vm.isDictating ? "Stop Dictation" : "Start Dictation")
    }

    private var recordButton: some View {
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
                .frame(width: 26, height: 22)
                .foregroundColor(
                    vm.recordPermissionDenied ? .secondary.opacity(0.4) :
                    vm.isRecording ? .red : .secondary
                )
                .background(
                    RoundedRectangle(cornerRadius: 3)
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
    }

    private var themeButton: some View {
        Menu {
            ForEach(AppTheme.allCases) { t in
                Button {
                    vm.theme = t
                } label: {
                    HStack {
                        Image(systemName: t.iconName)
                        Text(t.displayName)
                        if vm.theme == t {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: vm.theme.iconName)
                .font(.system(size: 11))
                .frame(width: 26, height: 22)
                .foregroundColor(.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hoveredButton == "theme" ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hoveredButton = $0 ? "theme" : nil }
        .help("Theme: \(vm.theme.displayName)")
    }

    /// Per-note Excalidraw board toggle. Three states:
    /// • passive (gray) — note has no diagram yet
    /// • has content (green) — a board with drawings exists, its window closed
    /// • open (blue/accent + filled background) — the board window is up
    private var boardButton: some View {
        let isOpen = vm.isBoardOpen(vm.activeTabId)
        let hasContent = vm.boardHasContent(vm.activeTabId)
        let tint: Color = isOpen ? .accentColor : (hasContent ? Tokens.SUI.boardHasContent : .secondary)
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) { vm.toggleBoard() }
        }) {
            Image(systemName: "pencil.and.outline")
                .font(.system(size: 11))
                .frame(width: 26, height: 22)
                .foregroundColor(tint)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isOpen ? Color.accentColor.opacity(0.14)
                              : (hoveredButton == "board" ? Color.primary.opacity(0.08) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { hoveredButton = $0 ? "board" : nil }
        .help(isOpen ? "Close diagram window" : (hasContent ? "Open diagram" : "Add a diagram"))
    }

    private var terminalButton: some View {
        let hasRoute = vm.terminalRoute(for: vm.activeTab) != nil
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) { vm.toggleTerminal() }
        }) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .frame(width: 26, height: 22)
                .foregroundColor(hasRoute ? (vm.isTerminalVisible ? .accentColor : .secondary) : Color.secondary.opacity(0.4))
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hoveredButton == "terminal" ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(!hasRoute)
        .onHover { hoveredButton = $0 ? "terminal" : nil }
        .help(hasRoute ? (vm.isTerminalVisible ? "Hide terminal" : "Show terminal") : "Link a folder to use the terminal")
    }

    /// Browser panel toggle. NOT route-gated: a page has nothing to do with a
    /// project folder, and looking something up is useful from any note.
    private var browserButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) { vm.toggleBrowser() }
        }) {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .frame(width: 26, height: 22)
                .foregroundColor(vm.isBrowserVisible ? .accentColor : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hoveredButton == "browser" ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hoveredButton = $0 ? "browser" : nil }
        .help(vm.isBrowserVisible ? "Hide browser (⌘⇧B)" : "Show browser (⌘⇧B)")
    }

    /// Agent used by FloatNote's terminal tabs. Changing it restarts every live
    /// pane in place so its route and note binding stay intact.
    private var agentMenu: some View {
        Menu {
            agentMenuItem("Codex", value: "codex")
            agentMenuItem("Claude", value: "claude")
        } label: {
            HStack(spacing: 3) {
                Text(terminalAgent == "claude" ? "Claude" : "Codex")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(hoveredButton == "agent" ? Color.primary.opacity(0.08) : Color.clear)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hoveredButton = $0 ? "agent" : nil }
        .help("Terminal agent: \(terminalAgent == "claude" ? "Claude" : "Codex"). Changing it restarts open terminal tabs.")
    }

    private func agentMenuItem(_ title: String, value: String) -> some View {
        Button {
            guard terminalAgent != value else { return }
            terminalAgent = value
            vm.restartTerminalsForAgentChange()
        } label: {
            HStack {
                Text(title)
                if terminalAgent == value {
                    Spacer()
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    /// Hands-free voice toggle. Route-gated exactly like `terminalButton` —
    /// with no terminal there is nothing for Claude to talk to.
    private var handsfreeButton: some View {
        let hasRoute = vm.terminalRoute(for: vm.activeTab) != nil
        let on = handsfree.isEnabled
        return Button(action: { vm.toggleHandsfree() }) {
            // NOT a plain mic: the editor's dictation button next door already
            // owns `mic`/`mic.fill`, and two identical mic icons in one toolbar
            // is how this got pressed instead of that one.
            Image(systemName: on ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 11))
                .frame(width: 26, height: 22)
                .foregroundColor(hasRoute ? (on ? .accentColor : .secondary)
                                          : Color.secondary.opacity(0.4))
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(on ? Color.accentColor.opacity(0.14)
                              : (hoveredButton == "handsfree" ? Color.primary.opacity(0.08) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .disabled(!hasRoute)
        .onHover { hoveredButton = $0 ? "handsfree" : nil }
        .help(hasRoute ? (on ? "Turn off hands-free voice" : "Hands-free voice")
                       : "Link a folder to use the terminal")
    }

    /// Second terminal for the same note. Only appears once the panel is
    /// already showing a terminal — before that, the plain terminal toggle is
    /// the way in, and a second button would just be noise.
    @ViewBuilder
    private var newTerminalButton: some View {
        if vm.isTerminalVisible && !vm.terminalTabs.isEmpty {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) { vm.addTerminal() }
            }) {
                Image(systemName: "plus.rectangle")
                    .font(.system(size: 11))
                    .frame(width: 26, height: 22)
                    .foregroundColor(.secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(hoveredButton == "newTerminal" ? Color.primary.opacity(0.08) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { hoveredButton = $0 ? "newTerminal" : nil }
            .help("New terminal")
        }
    }

    private var pinButton: some View {
        Button(action: { vm.togglePin() }) {
            Image(systemName: vm.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 11))
                .frame(width: 26, height: 22)
                .foregroundColor(vm.isPinned ? .accentColor : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hoveredButton == "pin" ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hoveredButton = $0 ? "pin" : nil }
        .help(vm.isPinned ? "Unpin from top" : "Pin to top")
    }

    /// The note's terminal-folder chip. Shows the effective directory's name
    /// (accent = inherited from a project folder, amber = this note's own
    /// override, gray "Set folder…" = none). Click → native folder picker sets
    /// the note's own path; the ✕ (override only) clears it back to inheriting.
    private var folderChip: some View {
        let route = vm.activeRoute
        let dirName = route.path.isEmpty ? "" : (route.path as NSString).lastPathComponent
        return HStack(spacing: 1) {
            Button(action: { pickNoteFolder() }) {
                HStack(spacing: 4) {
                    Image(systemName: route.source == .none ? "folder.badge.plus" : "link")
                        .font(.system(size: 10))
                    Text(route.source == .none ? "Set folder…" : dirName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(chipColor(route.source))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hoveredButton == "folder" ? Color.primary.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { hoveredButton = $0 ? "folder" : nil }
            .help(chipHelp(route))
            .contextMenu {
                Button(route.source == .none ? "Link Folder…" : "Change Folder…") { pickNoteFolder() }
                if route.source == .own {
                    Button("Unlink — inherit folder's directory") { vm.clearNoteFolderOverride() }
                } else if route.source == .inherited {
                    Button("Unlink Folder “\(route.label)”") { vm.unlinkActiveRoute() }
                }
            }

            if route.source == .own {
                Button(action: { vm.clearNoteFolderOverride() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Tokens.SUI.overrideTint)
                        .frame(width: 15, height: 22)
                }
                .buttonStyle(.plain)
                .help("Clear override — inherit the folder's directory")
            }
        }
        .fixedSize()
    }

    private func chipColor(_ source: EditorViewModel.RouteSource) -> Color {
        switch source {
        case .own:       return Tokens.SUI.overrideTint
        case .inherited: return .accentColor
        case .none:      return .secondary
        }
    }

    private func chipHelp(_ route: (path: String, label: String, source: EditorViewModel.RouteSource)) -> String {
        let tilde = route.path.isEmpty ? "" : (route.path as NSString).abbreviatingWithTildeInPath
        switch route.source {
        case .own:       return "This note's folder: \(tilde)  ·  ✕ to inherit"
        case .inherited: return "Terminal folder (from “\(route.label)”): \(tilde)"
        case .none:      return "Link a local folder to this note"
        }
    }

    private func pickNoteFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for this note"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let cur = vm.activeRoute.path
        if !cur.isEmpty { panel.directoryURL = URL(fileURLWithPath: cur) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.setNoteFolderOverride(url.path)
    }

    func thinDivider() -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 4)
    }

    func toolBtn(_ title: String, id: String, isSelected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .fixedSize()                       // never truncate the label
                .padding(.horizontal, 6)
                .frame(height: 22)
                .frame(minWidth: 26)               // short labels (H1) stay uniform; longer ones (Body) grow
                .foregroundColor(isSelected ? Color.accentColor : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : (hoveredButton == id ? Color.primary.opacity(0.08) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { hoveredButton = $0 ? id : nil }
    }

    func toggleDictation() {
        vm.wantsDictation.toggle()
        if vm.wantsDictation {
            startDictation()
            // Remove any stale observers before re-registering so toggling on
            // never accumulates duplicates.
            if let t = vm.dictationEndToken { NotificationCenter.default.removeObserver(t); vm.dictationEndToken = nil }
            if let t = vm.appActiveToken { NotificationCenter.default.removeObserver(t); vm.appActiveToken = nil }
            // Watch for dictation stopping (system timeout, user switched away, etc.)
            vm.dictationEndToken = NotificationCenter.default.addObserver(forName: NSNotification.Name("NSTextInputContextDictationDidEnd"), object: nil, queue: .main) { [weak vm] _ in
                MainActor.assumeIsolated {
                    vm?.isDictating = false
                    // Auto-restart after a short delay if user still wants dictation
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        MainActor.assumeIsolated {
                            guard let vm = vm, vm.wantsDictation, NSApp.isActive else { return }
                            vm.isDictating = true
                            let sel = NSSelectorFromString("startDictation:")
                            NSApp.sendAction(sel, to: nil, from: nil)
                        }
                    }
                }
            }
            // Watch for app becoming active again → restart dictation
            vm.appActiveToken = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak vm] _ in
                MainActor.assumeIsolated {
                    guard let vm = vm, vm.wantsDictation, !vm.isDictating else { return }
                    vm.isDictating = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        MainActor.assumeIsolated {
                            let sel = NSSelectorFromString("startDictation:")
                            NSApp.sendAction(sel, to: nil, from: nil)
                        }
                    }
                }
            }
        } else {
            stopDictation()
            if let t = vm.dictationEndToken { NotificationCenter.default.removeObserver(t); vm.dictationEndToken = nil }
            if let t = vm.appActiveToken { NotificationCenter.default.removeObserver(t); vm.appActiveToken = nil }
        }
    }

    private func startDictation() {
        vm.isDictating = true
        let sel = NSSelectorFromString("startDictation:")
        NSApp.sendAction(sel, to: nil, from: nil)
    }

    private func stopDictation() {
        vm.isDictating = false
        let src = CGEventSource(stateID: .hidSystemState)
        if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false) {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    func iconBtn(_ icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 26, height: 22)
                .foregroundColor(.primary)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hoveredButton == id ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hoveredButton = $0 ? id : nil }
    }
}

// MARK: - Recording In Progress View

struct RecordingInProgressView: View {
    let startTime: Date
    @EnvironmentObject var vm: EditorViewModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text("Recording in progress")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TimelineView(.periodic(from: startTime, by: 1.0)) { context in
                let elapsed = context.date.timeIntervalSince(startTime)
                Text(timeString(elapsed))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { Task { await vm.stopRecording() } }) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(vm.theme.chromeBackground)
    }

    private func timeString(_ s: TimeInterval) -> String {
        let t = Int(max(0, s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Recording Player View

/// Stacked per-recording rows above the editor — one slim row per recording of
/// the active note. A row can expand into the full waveform player
/// (`RecordingPlayerView`) for scrub/cut editing; only one row expands at a time.
struct RecordingsListView: View {
    @ObservedObject var tab: NoteTab
    @EnvironmentObject var vm: EditorViewModel
    @State private var expandedPath: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            ForEach(tab.recordingPaths, id: \.self) { path in
                RecordingRowView(
                    path: path,
                    tabId: tab.id,
                    isExpanded: expandedPath == path,
                    onToggleExpand: {
                        expandedPath = (expandedPath == path) ? nil : path
                    }
                )
                if expandedPath == path {
                    RecordingPlayerView(fileURL: URL(fileURLWithPath: path))
                        .id(path)
                }
                if path != tab.recordingPaths.last {
                    Divider().opacity(0.5)
                }
            }
        }
        .background(vm.theme.chromeBackground)
    }
}

/// One slim recording row: play/pause + seek + timestamp label (derived from
/// the filename), per-row Transcript/Summary, and a confirmed delete. While the
/// row is expanded into the full player its own controls hide (the full player
/// takes over) leaving just the label + collapse + delete.
struct RecordingRowView: View {
    let path: String
    let tabId: UUID
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    @EnvironmentObject var vm: EditorViewModel
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var timeObserver: Any?
    @State private var endObserver: Any?
    @State private var pauseObserver: Any?
    @State private var confirmingDelete = false

    /// "16.07-11.26-2.m4a" → "16.07 11:26 (2)"
    private var label: String {
        let name = (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".m4a", with: "")
        let parts = name.split(separator: "-").map(String.init)
        guard parts.count >= 2 else { return name }
        let time = parts[1].replacingOccurrences(of: ".", with: ":")
        let suffix = parts.count > 2 ? " (\(parts[2]))" : ""
        return "\(parts[0]) \(time)\(suffix)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide waveform editor" : "Show waveform editor")

            Text("\u{1F3A4}").font(.system(size: 10))
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)

            if !isExpanded {
                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)

                Slider(value: Binding(get: { currentTime }, set: { seek(to: $0) }),
                       in: 0...max(duration, 1))
                    .controlSize(.mini)
                    .frame(maxWidth: 180)

                Text("\(timeString(currentTime)) / \(timeString(duration))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer(minLength: 4)

                if vm.deepgramClient != nil {
                    Button {
                        Task { await vm.transcribeRecording(path: path) }
                    } label: {
                        Text("Transcript")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(vm.isTranscribing ? .secondary : .accentColor)
                    .disabled(vm.isTranscribing || vm.isSummarizing)
                    .help("Transcribe this recording")

                    Button {
                        Task { await vm.summarizeRecording(path: path) }
                    } label: {
                        Text("Summary")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(vm.isSummarizing ? .secondary : .accentColor)
                    .disabled(vm.isTranscribing || vm.isSummarizing)
                    .help("Transcribe & summarize this recording with AI")
                }
            } else {
                Spacer(minLength: 4)
            }

            Button { confirmingDelete = true } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete this recording")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .alert("Delete this recording?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                cleanup()
                vm.deleteRecording(path: path, from: tabId)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(label) will be removed from disk permanently.")
        }
        .onAppear { setupPlayer() }
        .onDisappear { cleanup() }
        .onChange(of: isExpanded) { expanded in
            // The full player takes over while expanded — stop the row's audio.
            if expanded { player?.pause(); isPlaying = false }
        }
    }

    private func togglePlay() {
        guard let p = player else { return }
        if isPlaying {
            p.pause()
            isPlaying = false
        } else {
            NotificationCenter.default.post(name: .floatnoteRowPlaybackStarted, object: path)
            if currentTime >= duration - 0.05 { p.seek(to: .zero) }
            p.play()
            isPlaying = true
        }
    }

    private func seek(to t: Double) {
        currentTime = t
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600))
    }

    private func timeString(_ t: Double) -> String {
        let s = Int(max(t, 0))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func setupPlayer() {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        let p = AVPlayer(playerItem: item)
        player = p
        Task {
            if let dur = try? await item.asset.load(.duration), dur.isNumeric {
                duration = max(dur.seconds, 1)
            }
        }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { t in
            currentTime = t.seconds
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { _ in
            isPlaying = false
            currentTime = 0
            p.seek(to: .zero)
        }
        pauseObserver = NotificationCenter.default.addObserver(
            forName: .floatnoteRowPlaybackStarted, object: nil, queue: .main
        ) { note in
            if (note.object as? String) != path {
                p.pause()
                isPlaying = false
            }
        }
    }

    private func cleanup() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        timeObserver = nil
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        endObserver = nil
        if let obs = pauseObserver { NotificationCenter.default.removeObserver(obs) }
        pauseObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
    }
}

struct RecordingPlayerView: View {
    let fileURL: URL
    @EnvironmentObject var vm: EditorViewModel
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var timeObserver: Any?
    @State private var endObserver: Any?
    @State private var fileExists = false
    @State private var samples: [Float] = []
    @State private var selStart: Double? = nil
    @State private var selEnd: Double? = nil
    @State private var isCutting = false

    private var hasSelection: Bool {
        if let s = selStart, let e = selEnd, e - s > 0.05 { return true }
        return false
    }

    var body: some View {
        Group {
        if !fileExists {
            Text("Recording file not found")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 0) {
                // Waveform row
                WaveformView(samples: samples,
                             duration: duration,
                             currentTime: currentTime,
                             selStart: $selStart,
                             selEnd: $selEnd,
                             onSeek: { t in seek(to: t) })
                    .frame(height: 44)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)

                // Player controls row
                HStack(spacing: 8) {
                    Button { togglePlay() } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)

                    Button { stopPlay() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)

                    Slider(value: Binding(get: { currentTime }, set: { seek(to: $0) }),
                           in: 0...max(duration, 1))
                        .controlSize(.small)

                    Text("\(timeString(currentTime)) / \(timeString(duration))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(minWidth: 70, alignment: .trailing)

                    if hasSelection {
                        Button {
                            Task { await performCut() }
                        } label: {
                            HStack(spacing: 3) {
                                if isCutting {
                                    ProgressView().controlSize(.small).scaleEffect(0.6)
                                } else {
                                    Image(systemName: "scissors")
                                        .font(.system(size: 10))
                                }
                                Text(isCutting ? "Cutting…" : "Cut")
                                    .font(.system(size: 10, weight: .medium))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(isCutting ? .secondary : .accentColor)
                        .disabled(isCutting)
                        .help("Remove selected region")

                        Button {
                            selStart = nil; selEnd = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .disabled(isCutting)
                        .help("Clear selection")
                    }

                    Button("Open Folder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: RecordingManager.recordingsDir))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                // Deepgram transcription row
                if vm.deepgramClient != nil {
                    Divider()
                    HStack(spacing: 8) {
                        Picker("", selection: $vm.selectedLanguage) {
                            ForEach(TranscriptLanguage.allCases, id: \.self) { lang in
                                Text(lang.label).tag(lang)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 80)
                        .controlSize(.small)

                        Button {
                            dbg("TRANSCRIPT BUTTON TAPPED")
                            Task { await vm.transcribeRecording(path: fileURL.path) }
                        } label: {
                            HStack(spacing: 4) {
                                if vm.isTranscribing {
                                    ProgressView()
                                        .controlSize(.small)
                                        .scaleEffect(0.6)
                                }
                                Text(vm.isTranscribing ? "Transcribing..." : "Transcript")
                            }
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(vm.isTranscribing ? .secondary : .accentColor)
                        .disabled(vm.isTranscribing || vm.isSummarizing)

                        Button {
                            Task { await vm.summarizeRecording(path: fileURL.path) }
                        } label: {
                            HStack(spacing: 4) {
                                if vm.isSummarizing {
                                    ProgressView()
                                        .controlSize(.small)
                                        .scaleEffect(0.6)
                                }
                                Text(vm.isSummarizing ? "Summarizing..." : "Summary")
                            }
                            .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(vm.isSummarizing ? .secondary : .accentColor)
                        .disabled(vm.isTranscribing || vm.isSummarizing)
                        .help("Transcribe & summarize with AI")

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
            }
            .background(vm.theme.chromeBackground)
        }
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
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { t in
            currentTime = t.seconds
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            isPlaying = false
            currentTime = 0
            p.seek(to: .zero)
        }
        loadWaveform()
    }

    private func loadWaveform() {
        let url = fileURL
        Task.detached(priority: .utility) {
            let peaks = Self.computePeaks(url: url, targetBars: 240)
            await MainActor.run { self.samples = peaks }
        }
    }

    private static func computePeaks(url: URL, targetBars: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else { return [] }
        do { try file.read(into: buf) } catch { return [] }
        guard let data = buf.floatChannelData else { return [] }
        let channels = Int(buf.format.channelCount)
        let total = Int(buf.frameLength)
        let perBar = max(1, total / targetBars)
        var result: [Float] = []
        result.reserveCapacity(targetBars)
        var i = 0
        while i < total {
            let end = min(i + perBar, total)
            var peak: Float = 0
            for c in 0..<channels {
                let ch = data[c]
                for j in i..<end {
                    let v = abs(ch[j])
                    if v > peak { peak = v }
                }
            }
            result.append(peak)
            i = end
        }
        // Normalize
        if let maxV = result.max(), maxV > 0 {
            result = result.map { $0 / maxV }
        }
        return result
    }

    private func performCut() async {
        guard let s = selStart, let e = selEnd, e > s else { return }
        isCutting = true
        defer { isCutting = false }

        // Pause playback before mutating file
        player?.pause()
        isPlaying = false

        let src = fileURL
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fn_cut_\(UUID().uuidString).m4a")

        let asset = AVURLAsset(url: src)
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .audio,
                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
            dbg("CUT: failed to add track"); return
        }

        do {
            let srcTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let srcTrack = srcTracks.first else { dbg("CUT: no audio track"); return }
            let totalDur = try await asset.load(.duration)
            let totalSec = totalDur.seconds
            let clampedS = max(0, min(s, totalSec))
            let clampedE = max(clampedS, min(e, totalSec))
            let startCM = CMTime(seconds: clampedS, preferredTimescale: 600)
            let endCM = CMTime(seconds: clampedE, preferredTimescale: 600)

            if clampedS > 0 {
                let r1 = CMTimeRange(start: .zero, end: startCM)
                try track.insertTimeRange(r1, of: srcTrack, at: .zero)
            }
            if clampedE < totalSec {
                let r2 = CMTimeRange(start: endCM, end: totalDur)
                try track.insertTimeRange(r2, of: srcTrack, at: startCM)
            }
        } catch {
            dbg("CUT: composition failed: \(error)"); return
        }

        guard let exporter = AVAssetExportSession(asset: comp,
                                                  presetName: AVAssetExportPresetAppleM4A) else {
            dbg("CUT: exporter init failed"); return
        }
        exporter.outputURL = tempURL
        exporter.outputFileType = .m4a

        await exporter.export()
        guard exporter.status == .completed else {
            dbg("CUT: export failed status=\(exporter.status.rawValue) err=\(String(describing: exporter.error))")
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        // Replace original atomically
        do {
            _ = try FileManager.default.replaceItemAt(src, withItemAt: tempURL)
        } catch {
            dbg("CUT: replace failed: \(error)")
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        // Reload player + waveform
        cleanup()
        selStart = nil
        selEnd = nil
        currentTime = 0
        samples = []
        setupPlayer()
    }

    private func cleanup() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
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

// MARK: - Waveform View

struct WaveformView: View {
    let samples: [Float]
    let duration: Double
    let currentTime: Double
    @Binding var selStart: Double?
    @Binding var selEnd: Double?
    let onSeek: (Double) -> Void

    @State private var dragAnchor: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                // Background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.04))

                // Bars
                Canvas { ctx, size in
                    guard !samples.isEmpty else { return }
                    let n = samples.count
                    let barW = size.width / CGFloat(n)
                    let midY = size.height / 2
                    for (i, s) in samples.enumerated() {
                        let x = CGFloat(i) * barW
                        let bh = max(1, CGFloat(s) * size.height * 0.9)
                        let rect = CGRect(x: x,
                                          y: midY - bh/2,
                                          width: max(1, barW - 1),
                                          height: bh)
                        ctx.fill(Path(rect),
                                 with: .color(Color.secondary.opacity(0.7)))
                    }
                }

                // Selection overlay
                if let s = selStart, let e = selEnd, duration > 0 {
                    let sx = CGFloat(max(0, min(s, duration)) / duration) * w
                    let ex = CGFloat(max(0, min(e, duration)) / duration) * w
                    let width = max(0, ex - sx)
                    ZStack {
                        Rectangle()
                            .fill(Color.yellow.opacity(0.28))
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.yellow, lineWidth: 1.5)
                    }
                    .frame(width: width, height: h)
                    .offset(x: sx)
                }

                // Playhead
                if duration > 0 {
                    let px = CGFloat(max(0, min(currentTime, duration)) / duration) * w
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 1.5, height: h)
                        .offset(x: px)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard duration > 0, w > 0 else { return }
                        let px = min(max(g.location.x, 0), w)
                        let t = Double(px / w) * duration
                        if dragAnchor == nil {
                            let anchorPx = min(max(g.startLocation.x, 0), w)
                            dragAnchor = Double(anchorPx / w) * duration
                        }
                        if let a = dragAnchor {
                            let lo = min(a, t)
                            let hi = max(a, t)
                            if hi - lo < 0.05 {
                                selStart = nil
                                selEnd = nil
                            } else {
                                selStart = lo
                                selEnd = hi
                            }
                        }
                    }
                    .onEnded { g in
                        defer { dragAnchor = nil }
                        guard duration > 0, w > 0 else { return }
                        let dx = abs(g.translation.width)
                        if dx < 3 {
                            // Treat as a tap: clear selection & seek
                            selStart = nil
                            selEnd = nil
                            let px = min(max(g.location.x, 0), w)
                            onSeek(Double(px / w) * duration)
                        }
                    }
            )
        }
    }
}

// MARK: - Block Caret NSTextView

class BlockCaretTextView: NSTextView {
    /// Weak view-model ref so keyboard shortcuts (Cmd+B/I/U) can dispatch
    /// through the same format pipeline as the toolbar buttons.
    weak var editorViewModel: EditorViewModel?

    private let caretView: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        return v
    }()

    /// Recolor the custom block caret to match the current theme.
    func setCaretColor(_ color: NSColor) {
        caretView.layer?.backgroundColor = color.withAlphaComponent(0.85).cgColor
    }

    // MARK: - Drag-to-reorder state
    private var isDraggingLine = false
    private var dragStartLineIndex: Int = 0  // character index of dragged line start
    private var dragInsertIndex: Int = -1     // character index where line will be inserted
    private var dragDidMove = false
    /// Where the press started, so a click isn't mistaken for a drag. AppKit
    /// sends `mouseDragged` for sub-pixel trackpad movement, and treating the
    /// first one as a real drag made checkbox toggles fail at random — the
    /// press became a line-reorder and `mouseUp` skipped the toggle.
    private var dragStartPoint: NSPoint = .zero
    /// Movement (points) before a press on a list prefix counts as a drag.
    private static let dragSlop: CGFloat = 3
    private var dragNestIndent: String = ""   // indentation to apply on drop
    private let dragInsertionLine: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
        v.layer?.cornerRadius = 1
        v.isHidden = true
        return v
    }()
    private let dragSourceDim: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        v.isHidden = true
        return v
    }()

    // MARK: - Image selection / resize state
    private var selectedImageRange: NSRange?
    private var isResizingImage = false
    private var resizeStartX: CGFloat = 0
    private var resizeStartWidth: CGFloat = 0
    private let imageBorderView: NSView = {
        let v = PassthroughView()
        v.wantsLayer = true
        v.layer?.borderColor = NSColor.controlAccentColor.cgColor
        v.layer?.borderWidth = 1.5
        v.layer?.cornerRadius = 2
        v.isHidden = true
        return v
    }()
    private let imageHandleView: NSView = {
        let v = PassthroughView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        v.layer?.cornerRadius = 6
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        v.layer?.borderWidth = 1.5
        v.isHidden = true
        return v
    }()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        addSubview(caretView)
        addSubview(dragSourceDim)
        addSubview(dragInsertionLine)
        addSubview(imageBorderView)
        addSubview(imageHandleView)
        DispatchQueue.main.async { self.updateCaretPosition() }

        // The caret also hides while the window isn't key (app in background):
        // re-evaluate visibility on key-status changes of our own window.
        windowKeyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowKeyObservers = []
        if let win = window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                windowKeyObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: win, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateCaretPosition() }
                })
            }
        }

        // Track mouse movement for cursor changes over list prefixes
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
    }

    override func mouseMoved(with event: NSEvent) {
        // Resize handle of a selected image: horizontal drag is what scales it,
        // so show the left-right resize cursor as the affordance.
        let rawPoint = convert(event.locationInWindow, from: nil)
        if !imageHandleView.isHidden,
           imageHandleView.frame.insetBy(dx: -6, dy: -6).contains(rawPoint) {
            NSCursor.resizeLeftRight.set()
            return
        }
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage else {
            super.mouseMoved(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let adjusted = NSPoint(x: point.x - textContainerInset.width, y: point.y - textContainerInset.height)
        var fraction: CGFloat = 0
        let charIndex = lm.characterIndex(for: adjusted, in: tc, fractionOfDistanceBetweenInsertionPoints: &fraction)
        // Over an inline image: it's an object, not text — no I-beam.
        if imageAttachment(at: charIndex) != nil {
            NSCursor.arrow.set()
            return
        }
        if charIndex < ts.length {
            let (lineRange, prefixLen) = listPrefixLen(at: charIndex)
            if prefixLen > 0 && charIndex < lineRange.location + prefixLen {
                NSCursor.pointingHand.set()
                return
            }
            if ts.attribute(.link, at: charIndex, effectiveRange: nil) != nil {
                NSCursor.pointingHand.set()
                return
            }
        }
        NSCursor.iBeam.set()
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // Hide system caret
    }

    /// The block caret is a custom always-on subview, so unlike the system
    /// insertion point it must be hidden explicitly while keyboard focus is
    /// elsewhere (e.g. the terminal panel) — a visible caret there reads as
    /// "typing goes here" when it doesn't.
    private var isEditorFocused = false
    private var windowKeyObservers: [NSObjectProtocol] = []

    deinit {
        windowKeyObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { isEditorFocused = true; updateCaretPosition() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { isEditorFocused = false; updateCaretPosition() }
        return ok
    }

    override func didChangeText() {
        super.didChangeText()
        // Any text mutation invalidates the image-selection geometry.
        deselectImage()
        updateCaretPosition()
        // Placeholder covers the whole first lines, not just the edited glyph
        // range — force a full redraw when emptiness flips either way.
        if string.isEmpty != placeholderWasVisible {
            placeholderWasVisible = string.isEmpty
            needsDisplay = true
        }
        // AppKit resets typing attributes to its stock defaults when the
        // document is cleared — re-pin the body style so the next character
        // types with the chosen editor font, not the fallback.
        if string.isEmpty {
            typingAttributes = bodyLineTypingAttributes()
            updateCaretPosition()
        }
    }

    // MARK: - Empty-note placeholder

    private var placeholderWasVisible = false

    func bodyLineTypingAttributes() -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.baseWritingDirection = .leftToRight
        p.alignment = .left
        p.applyReadableBodySpacing()
        return [
            .font: Tokens.Typography.body(),
            .foregroundColor: editorViewModel?.theme.editorTextNS ?? NSColor.textColor,
            .paragraphStyle: p
        ]
    }

    /// The insertion line of an EMPTY document, in text-container coordinates.
    /// AppKit sizes this extra line fragment from typingAttributes; the ghost
    /// prompt and the caret must both center within it or they drift apart
    /// vertically.
    private func emptyDocLineRect() -> NSRect {
        if let lm = layoutManager, lm.extraLineFragmentRect.height > 0 {
            return lm.extraLineFragmentRect
        }
        let f = (typingAttributes[.font] as? NSFont) ?? Tokens.Typography.body()
        let h = layoutManager?.defaultLineHeight(for: f) ?? ceil(f.ascender - f.descender)
        return NSRect(x: 0, y: 0, width: 0, height: h)
    }

    /// Evernote-style ghost text on an empty note: a writing prompt.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5)
        // Derive from the theme's text color (not a dynamic system color) so
        // the ghost text always contrasts with the themed editor background.
        let ghost = editorViewModel?.theme.editorTextNS.withAlphaComponent(0.3) ?? NSColor.tertiaryLabelColor
        let promptLine = NSAttributedString(
            string: "Start writing…",
            attributes: [.font: Tokens.Typography.body(), .foregroundColor: ghost])
        let lineRect = emptyDocLineRect()
        let y = textContainerInset.height + lineRect.minY
            + (lineRect.height - promptLine.size().height) / 2
        promptLine.draw(at: NSPoint(x: x, y: y))
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
        // Moving the selection away from a selected image deselects it.
        if let ir = selectedImageRange, charRange != ir { deselectImage() }
        updateCaretPosition()
        // If the caret has moved out of a link span, strip link styling from
        // typing attributes so further typing isn't a link.
        if !stillSelectingFlag && charRange.length == 0 {
            stripLinkTypingAttrsIfOutsideLink(at: charRange.location)
        }
    }

    /// Clears `.link`, `.underlineStyle` and the blue color from typingAttributes
    /// when the caret is no longer inside a link run.
    private func stripLinkTypingAttrsIfOutsideLink(at pos: Int) {
        guard let storage = textStorage else { return }
        // The character STRICTLY inside the link is the one at index pos-1 (left of caret) AND pos (right of caret).
        // We strip if neither side has a link attribute.
        let leftHasLink = pos > 0 && storage.attribute(.link, at: pos - 1, effectiveRange: nil) != nil
        let rightHasLink = pos < storage.length && storage.attribute(.link, at: pos, effectiveRange: nil) != nil
        if !leftHasLink && !rightHasLink {
            var attrs = typingAttributes
            let hadLinkStyle = attrs[.link] != nil || attrs[.underlineStyle] != nil
            // Detect link-blue foreground robustly across color spaces.
            var hadLinkColor = false
            if let fg = attrs[.foregroundColor] as? NSColor,
               let rgb = fg.usingColorSpace(.sRGB) {
                if abs(rgb.redComponent - 0.42) < 0.08,
                   abs(rgb.greenComponent - 0.68) < 0.08,
                   abs(rgb.blueComponent - 1.0)  < 0.08 {
                    hadLinkColor = true
                }
            }
            if hadLinkStyle || hadLinkColor {
                attrs.removeValue(forKey: .link)
                attrs.removeValue(forKey: .underlineStyle)
                attrs[.foregroundColor] = editorViewModel?.theme.editorTextNS ?? NSColor.textColor
                typingAttributes = attrs
            }
        }
    }

    /// Returns the full prefix length (leading spaces + "• "/"☐ "/"☑ ") for the line at the given position, or 0.
    private func listPrefixLen(at pos: Int) -> (lineRange: NSRange, prefixLen: Int) {
        guard let str = textStorage?.string as NSString? else { return (NSRange(), 0) }
        let lineRange = str.lineRange(for: NSRange(location: pos, length: 0))
        let lineStr = str.substring(with: lineRange)
        let leadingSpaces = lineStr.prefix(while: { $0 == " " || $0 == "\u{00a0}" }).count
        let afterIndent = String(lineStr.dropFirst(leadingSpaces))
        for prefix in ["• ", "☐ ", "☑ "] {
            if afterIndent.hasPrefix(prefix) { return (lineRange, leadingSpaces + prefix.count) }
        }
        return (lineRange, 0)
    }

    // MARK: - Smart Home (Cmd+Left)
    override func moveToBeginningOfLine(_ sender: Any?) {
        let pos = selectedRange().location
        let (lineRange, prefixLen) = listPrefixLen(at: pos)
        guard prefixLen > 0 else { super.moveToBeginningOfLine(sender); return }

        let afterPrefix = lineRange.location + prefixLen
        if pos != afterPrefix {
            setSelectedRange(NSRange(location: afterPrefix, length: 0))
        } else {
            setSelectedRange(NSRange(location: lineRange.location, length: 0))
        }
        updateCaretPosition()
    }

    // MARK: - Smart Home with Selection (Cmd+Shift+Left)
    override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) {
        let sel = selectedRange()
        let pos = sel.location
        let (lineRange, prefixLen) = listPrefixLen(at: pos)
        guard prefixLen > 0 else { super.moveToBeginningOfLineAndModifySelection(sender); return }

        let afterPrefix = lineRange.location + prefixLen
        if pos != afterPrefix && pos > afterPrefix {
            // Extend selection back to after prefix
            let newLen = sel.length + (pos - afterPrefix)
            setSelectedRange(NSRange(location: afterPrefix, length: newLen))
        } else {
            // Extend selection to absolute line start
            let newLen = sel.length + (pos - lineRange.location)
            setSelectedRange(NSRange(location: lineRange.location, length: newLen))
        }
        updateCaretPosition()
    }

    // MARK: - Copy: emit full URL for shortened links instead of the display text
    override func copy(_ sender: Any?) {
        guard let storage = textStorage else { super.copy(sender); return }
        let sel = selectedRange()
        guard sel.length > 0, sel.location >= 0, NSMaxRange(sel) <= storage.length else {
            super.copy(sender); return
        }
        let attributed = storage.attributedSubstring(from: sel)
        let mutable = NSMutableAttributedString(attributedString: attributed)
        var hadLink = false
        mutable.enumerateAttribute(.link, in: NSRange(location: 0, length: mutable.length), options: []) { value, range, _ in
            guard let url = value as? URL else { return }
            let runText = (mutable.string as NSString).substring(with: range)
            let full = url.absoluteString
            if runText != full {
                hadLink = true
                let attrs = mutable.attributes(at: range.location, effectiveRange: nil)
                mutable.replaceCharacters(in: range, with: NSAttributedString(string: full, attributes: attrs))
            }
        }
        if !hadLink { super.copy(sender); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if let rtf = try? mutable.data(from: NSRange(location: 0, length: mutable.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pb.setData(rtf, forType: .rtf)
        }
        pb.setString(mutable.string, forType: .string)
    }

    // MARK: - Backspace removes full prefix
    // MARK: - Paste: strip external formatting, apply FloatNote body style, auto-link URLs
    override func paste(_ sender: Any?) {
        // Images first (screenshots, copied image files) — they'd otherwise
        // paste as a file path string or an unmanaged native attachment.
        if pasteImageIfPresent() { return }
        guard var pb = NSPasteboard.general.string(forType: .string), !pb.isEmpty else {
            super.paste(sender)
            return
        }
        guard let storage = textStorage else { return }

        recordUndoSnapshot()

        // Strip a redundant leading list prefix if the destination line already has one.
        let cursorPos = selectedRange().location
        let (_, destPrefixLen) = listPrefixLen(at: cursorPos)
        if destPrefixLen > 0 {
            let leading = pb.prefix(while: { $0 == " " || $0 == "\u{00a0}" })
            let afterIndent = String(pb.dropFirst(leading.count))
            for prefix in ["• ", "☐ ", "☑ "] {
                if afterIndent.hasPrefix(prefix) {
                    pb = String(afterIndent.dropFirst(prefix.count))
                    break
                }
            }
        }

        let bodyFont = Tokens.Typography.body()
        let ps = NSMutableParagraphStyle()
        ps.baseWritingDirection = .leftToRight
        ps.alignment = .left
        ps.applyReadableBodySpacing()
        let themeBody = editorViewModel?.theme.editorTextNS ?? NSColor.textColor
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: themeBody,
            .paragraphStyle: ps
        ]
        let linkColor = NSColor(calibratedRed: 0.42, green: 0.68, blue: 1.0, alpha: 1.0)

        // Build attributed string with URLs auto-linked; shorten the visible text for long URLs.
        let result = NSMutableAttributedString()
        let nsText = pb as NSString
        let urlPattern = try? NSRegularExpression(pattern: #"https?://[^\s<>\"\)\]]+"#, options: [])
        let matches = urlPattern?.matches(in: pb, range: NSRange(location: 0, length: nsText.length)) ?? []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let pre = nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                result.append(NSAttributedString(string: pre, attributes: bodyAttrs))
            }
            let urlStr = nsText.substring(with: match.range)
            if let url = URL(string: urlStr) {
                var linkAttrs = bodyAttrs
                linkAttrs[.link] = url
                linkAttrs[.foregroundColor] = linkColor
                linkAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                let display = Self.shortenURLForDisplay(urlStr)
                if display != urlStr {
                    linkAttrs[.toolTip] = urlStr
                }
                result.append(NSAttributedString(string: display, attributes: linkAttrs))
            } else {
                result.append(NSAttributedString(string: urlStr, attributes: bodyAttrs))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < nsText.length {
            let tail = nsText.substring(with: NSRange(location: cursor, length: nsText.length - cursor))
            result.append(NSAttributedString(string: tail, attributes: bodyAttrs))
        }

        let range = selectedRange()
        storage.replaceCharacters(in: range, with: result)

        // Re-apply checkbox glyph styling to any pasted ☐/☑ list prefixes.
        // Formatting was stripped above, so the boxes arrived as plain body-font
        // characters. Without this an unchecked ☐ falls back to Apple Symbols'
        // thin, square box (wrong style) at body size (wrong size) instead of
        // SF Rounded's matching box at checkboxSize. Mirrors the document-load
        // loop — walk the affected lines and style any line-leading box.
        let insertedEnd = min(range.location + result.length, (storage.string as NSString).length)
        let bodyText = editorViewModel?.theme.editorTextNS ?? NSColor.textColor
        var scan = (storage.string as NSString).lineRange(for: NSRange(location: range.location, length: 0)).location
        while scan < insertedEnd {
            let ns = storage.string as NSString
            let lr = ns.lineRange(for: NSRange(location: scan, length: 0))
            let ls = ns.substring(with: lr)
            let leading = ls.prefix(while: { $0 == " " || $0 == "\u{00a0}" })
            let afterIndent = String(ls.dropFirst(leading.count))
            if afterIndent.hasPrefix("☐") || afterIndent.hasPrefix("☑") {
                let checked = afterIndent.hasPrefix("☑")
                let boxStart = lr.location + leading.count
                if boxStart < ns.length {
                    Tokens.Typography.styleCheckboxGlyph(storage, range: NSRange(location: boxStart, length: 1), checked: checked)
                    // Checked items get struck-through, muted content — match load.
                    if checked {
                        let cStart = boxStart + 2
                        var lEnd = lr.location + lr.length
                        if lEnd > cStart && ns.substring(with: NSRange(location: lEnd - 1, length: 1)) == "\n" { lEnd -= 1 }
                        let cRange = NSRange(location: cStart, length: max(0, lEnd - cStart))
                        if cRange.length > 0 {
                            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: cRange)
                            storage.addAttribute(.foregroundColor, value: bodyText.withAlphaComponent(0.55), range: cRange)
                        }
                    }
                }
            }
            let next = lr.location + lr.length
            if next <= scan { break }
            scan = next
        }

        setSelectedRange(NSRange(location: range.location + result.length, length: 0))
        typingAttributes = bodyAttrs
        didChangeText()
    }

    static func shortenURLForDisplay(_ s: String) -> String {
        guard let u = URL(string: s), let host = u.host else { return s }
        let last = u.pathComponents.last ?? ""
        let decoded = (last.removingPercentEncoding ?? last)
        let cleaned = (decoded == "/" || decoded == host) ? "" : decoded
        let candidate: String = {
            if cleaned.isEmpty { return host }
            let fileName = cleaned.count > 40 ? String(cleaned.prefix(40)) + "…" : cleaned
            return "\(host)/…/\(fileName)"
        }()
        // Don't bother shortening if the result isn't actually shorter.
        return candidate.count < s.count ? candidate : s
    }

    override func deleteBackward(_ sender: Any?) {
        guard let storage = textStorage else { super.deleteBackward(sender); return }
        let pos = selectedRange().location
        let sel = selectedRange()

        // Only handle when no selection (just caret)
        if sel.length == 0 && pos > 0 {
            let str = storage.string as NSString
            let lineRange = str.lineRange(for: NSRange(location: min(pos, max(0, str.length - 1)), length: 0))
            let lineStr = str.substring(with: lineRange)

            // Divider line: delete the entire divider (including surrounding newlines)
            let trimmedLine = lineStr.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasListPrefix = trimmedLine.hasPrefix("• ") || trimmedLine.hasPrefix("☐ ") || trimmedLine.hasPrefix("☑ ")
            if !hasListPrefix && !trimmedLine.isEmpty && trimmedLine.allSatisfy({ $0 == "─" }) {
                recordUndoSnapshot()
                // Include the newline before the divider if present
                var deleteStart = lineRange.location
                if deleteStart > 0 && str.substring(with: NSRange(location: deleteStart - 1, length: 1)) == "\n" {
                    deleteStart -= 1
                }
                let deleteRange = NSRange(location: deleteStart, length: NSMaxRange(lineRange) - deleteStart)
                storage.deleteCharacters(in: deleteRange)
                setSelectedRange(NSRange(location: min(deleteStart, storage.length), length: 0))
                didChangeText()
                return
            }

            let (pfxLineRange, prefixLen) = listPrefixLen(at: pos)
            if prefixLen > 0 {
                let afterPrefix = pfxLineRange.location + prefixLen
                // Caret is at or inside the prefix — remove entire prefix
                if pos <= afterPrefix && pos > pfxLineRange.location {
                    recordUndoSnapshot()
                    storage.deleteCharacters(in: NSRange(location: pfxLineRange.location, length: prefixLen))
                    setSelectedRange(NSRange(location: pfxLineRange.location, length: 0))
                    didChangeText()
                    return
                }
            }
        }
        super.deleteBackward(sender)
    }

    // MARK: - Cmd+Backspace stops at prefix
    override func deleteToBeginningOfLine(_ sender: Any?) {
        guard let storage = textStorage else { super.deleteToBeginningOfLine(sender); return }
        let pos = selectedRange().location
        let (lineRange, prefixLen) = listPrefixLen(at: pos)

        if prefixLen > 0 {
            let afterPrefix = lineRange.location + prefixLen
            if pos > afterPrefix {
                // Delete from caret back to after prefix (preserve prefix)
                recordUndoSnapshot()
                let deleteRange = NSRange(location: afterPrefix, length: pos - afterPrefix)
                storage.deleteCharacters(in: deleteRange)
                setSelectedRange(NSRange(location: afterPrefix, length: 0))
                didChangeText()
                return
            } else if pos == afterPrefix {
                // Already at prefix boundary — delete the prefix itself
                recordUndoSnapshot()
                storage.deleteCharacters(in: NSRange(location: lineRange.location, length: prefixLen))
                setSelectedRange(NSRange(location: lineRange.location, length: 0))
                didChangeText()
                return
            }
        }
        super.deleteToBeginningOfLine(sender)
    }

    // MARK: - Arrow key overrides
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Cmd+B/I/U → dispatch to the same format pipeline the toolbar uses.
        if flags == .command, let chars = event.charactersIgnoringModifiers?.lowercased(), let vm = editorViewModel {
            switch chars {
            case "b": vm.performFormat(.bold);      updateCaretPosition(); return
            case "i": vm.performFormat(.italic);    updateCaretPosition(); return
            case "u": vm.performFormat(.underline); updateCaretPosition(); return
            default: break
            }
        }
        // Option+Up or Option+Down to move lines (with children)
        if flags.contains(.option) && !flags.contains(.command) {
            if event.keyCode == 126 { // Up arrow
                moveLineUp()
                return
            } else if event.keyCode == 125 { // Down arrow
                moveLineDown()
                return
            }
        }
        super.keyDown(with: event)
        updateCaretPosition()
    }

    /// Returns the range covering a line and all its indented children.
    private func blockRange(for lineRange: NSRange) -> NSRange {
        guard let str = textStorage?.string as NSString? else { return lineRange }
        let lineStr = str.substring(with: lineRange)
        let parentIndent = lineStr.prefix(while: { $0 == " " || $0 == "\u{00a0}" }).count

        var blockEnd = NSMaxRange(lineRange)
        while blockEnd < str.length {
            let nextLR = str.lineRange(for: NSRange(location: blockEnd, length: 0))
            let nextStr = str.substring(with: nextLR)
            let nextIndent = nextStr.prefix(while: { $0 == " " || $0 == "\u{00a0}" }).count
            let nextTrimmed = nextStr.trimmingCharacters(in: .whitespacesAndNewlines)
            // Child if indented deeper and non-empty
            if nextIndent > parentIndent && !nextTrimmed.isEmpty {
                blockEnd = NSMaxRange(nextLR)
            } else {
                break
            }
        }
        return NSRange(location: lineRange.location, length: blockEnd - lineRange.location)
    }

    private func moveLineUp() {
        guard let storage = textStorage else { return }
        let str = storage.string as NSString
        let sel = selectedRange()
        let lineRange = str.lineRange(for: sel)
        let block = blockRange(for: lineRange)

        guard block.location > 0 else { return }

        // Find the line above — get its block too (in case it's also a parent)
        let prevLineRange = str.lineRange(for: NSRange(location: block.location - 1, length: 0))
        let prevBlock = blockRange(for: prevLineRange)

        recordUndoSnapshot()

        let currentBlock = storage.attributedSubstring(from: block)
        let prevBlockContent = storage.attributedSubstring(from: prevBlock)

        let combinedRange = NSRange(location: prevBlock.location, length: prevBlock.length + block.length)
        let swapped = NSMutableAttributedString()
        swapped.append(currentBlock)
        if !currentBlock.string.hasSuffix("\n") && prevBlockContent.string.hasSuffix("\n") {
            swapped.append(NSAttributedString(string: "\n"))
            let trimmed = NSMutableAttributedString(attributedString: prevBlockContent)
            trimmed.deleteCharacters(in: NSRange(location: trimmed.length - 1, length: 1))
            swapped.append(trimmed)
        } else {
            swapped.append(prevBlockContent)
        }

        storage.replaceCharacters(in: combinedRange, with: swapped)

        let newLineStart = prevBlock.location
        let (_, movedPrefixLen) = listPrefixLen(at: newLineStart)
        setSelectedRange(NSRange(location: newLineStart + movedPrefixLen, length: 0))
        didChangeText()
    }

    private func moveLineDown() {
        guard let storage = textStorage else { return }
        let str = storage.string as NSString
        let sel = selectedRange()
        let lineRange = str.lineRange(for: sel)
        let block = blockRange(for: lineRange)

        let blockEnd = NSMaxRange(block)
        guard blockEnd < str.length else { return }

        // Find the line below — get its block too
        let nextLineRange = str.lineRange(for: NSRange(location: blockEnd, length: 0))
        let nextBlock = blockRange(for: nextLineRange)

        recordUndoSnapshot()

        let currentBlock = storage.attributedSubstring(from: block)
        let nextBlockContent = storage.attributedSubstring(from: nextBlock)

        let combinedRange = NSRange(location: block.location, length: block.length + nextBlock.length)
        let swapped = NSMutableAttributedString()
        swapped.append(nextBlockContent)
        if !nextBlockContent.string.hasSuffix("\n") && currentBlock.string.hasSuffix("\n") {
            swapped.append(NSAttributedString(string: "\n"))
            let trimmed = NSMutableAttributedString(attributedString: currentBlock)
            trimmed.deleteCharacters(in: NSRange(location: trimmed.length - 1, length: 1))
            swapped.append(trimmed)
        } else {
            swapped.append(currentBlock)
        }

        storage.replaceCharacters(in: combinedRange, with: swapped)

        let newLineStart = block.location + nextBlock.length
        let (_, movedPrefixLen) = listPrefixLen(at: newLineStart)
        setSelectedRange(NSRange(location: newLineStart + movedPrefixLen, length: 0))
        didChangeText()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let adjustedPoint = NSPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )
        // Resize handle of a selected image — grab it before anything else.
        if !imageHandleView.isHidden {
            let hitBox = imageHandleView.frame.insetBy(dx: -8, dy: -8)
            dbg("imgMouseDown: pt=\(point) handle=\(imageHandleView.frame) hit=\(hitBox.contains(point))")
            if hitBox.contains(point),
               let r = selectedImageRange, let att = imageAttachment(at: r.location) {
                isResizingImage = true
                resizeStartX = point.x
                resizeStartWidth = att.displayWidth
                return
            }
        }
        if let lm = layoutManager, let tc = textContainer, let ts = textStorage {
            var fraction: CGFloat = 0
            let charIndex = lm.characterIndex(for: adjustedPoint, in: tc, fractionOfDistanceBetweenInsertionPoints: &fraction)
            // Click directly on an inline image → select it (border + handle).
            if imageAttachment(at: charIndex) != nil,
               let rect = imageRect(for: NSRange(location: charIndex, length: 1)),
               rect.contains(point) {
                deselectImage()
                selectImage(at: charIndex)
                return
            }
            deselectImage()
            if charIndex < ts.length {
                let (lineRange, prefixLen) = listPrefixLen(at: charIndex)
                if prefixLen > 0 && charIndex < lineRange.location + prefixLen {
                    // Clicked on a list prefix — prepare for possible drag
                    isDraggingLine = true
                    dragDidMove = false
                    dragStartPoint = point
                    dragStartLineIndex = lineRange.location
                    dragInsertIndex = -1

                    // Place caret at end of line (not beginning) to avoid visible jump
                    let str = ts.string as NSString
                    var lineEnd = lineRange.location + lineRange.length
                    if lineEnd > 0 && str.substring(with: NSRange(location: lineEnd - 1, length: 1)) == "\n" {
                        lineEnd -= 1
                    }
                    setSelectedRange(NSRange(location: lineEnd, length: 0))

                    // Dim the source line
                    let glyphRange = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
                    let lineRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                    dragSourceDim.frame = NSRect(
                        x: textContainerInset.width,
                        y: lineRect.origin.y + textContainerInset.height,
                        width: bounds.width - textContainerInset.width * 2,
                        height: lineRect.height
                    )
                    updateCaretPosition()
                    return
                }
            }
        }
        super.mouseDown(with: event)
        updateCaretPosition()
    }

    // MARK: - Image paste / insert / resize

    /// Image-file URLs (Finder copies) first, else raw image data (screenshots,
    /// browser copies). Returns false for non-image pasteboards.
    private func pasteImageIfPresent() -> Bool {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: ["public.image"]
        ]) as? [URL], !urls.isEmpty {
            let images = urls.compactMap { NSImage(contentsOf: $0) }
            if !images.isEmpty {
                insertImages(images)
                return true
            }
        }
        if pb.availableType(from: [.tiff, .png]) != nil, let img = NSImage(pasteboard: pb) {
            insertImage(img)
            return true
        }
        return false
    }

    /// Insert several images in order, each on its own line so a batch of
    /// screenshots reads top-to-bottom instead of running together.
    func insertImages(_ images: [NSImage]) {
        for (i, image) in images.enumerated() {
            if i > 0 { insertText("\n", replacementRange: selectedRange()) }
            insertImage(image)
        }
    }

    /// Save to ~/.floatnote-images and insert at the caret (undoable insertText).
    func insertImage(_ image: NSImage) {
        guard image.size.width > 0, let id = ImageStore.savePNG(image) else {
            NSSound.beep()
            return
        }
        let width = min(max(60, image.size.width), usableTextWidth())
        guard let att = ImageAttachment(imageId: id, displayWidth: width) else { return }
        insertText(NSAttributedString(attachment: att), replacementRange: selectedRange())
    }

    private func usableTextWidth() -> CGFloat {
        let container = textContainer?.size.width ?? 400
        let pad = (textContainer?.lineFragmentPadding ?? 5) * 2
        return max(100, container - pad)
    }

    /// The ImageAttachment at `charIndex`, if any.
    private func imageAttachment(at charIndex: Int) -> ImageAttachment? {
        guard let ts = textStorage, charIndex >= 0, charIndex < ts.length else { return nil }
        return ts.attribute(.attachment, at: charIndex, effectiveRange: nil) as? ImageAttachment
    }

    /// Glyph rect of the attachment char, in view coordinates.
    private func imageRect(for range: NSRange) -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        return rect
    }

    private func selectImage(at charIndex: Int) {
        selectedImageRange = NSRange(location: charIndex, length: 1)
        setSelectedRange(selectedImageRange!)
        positionImageOverlays()
        updateCaretPosition()
    }

    func deselectImage() {
        selectedImageRange = nil
        imageBorderView.isHidden = true
        imageHandleView.isHidden = true
    }

    /// Reposition (or hide) the selection border + resize handle. Call after
    /// anything that changes layout while an image is selected.
    private func positionImageOverlays() {
        guard let r = selectedImageRange, imageAttachment(at: r.location) != nil,
              let rect = imageRect(for: r) else {
            deselectImage()
            return
        }
        imageBorderView.frame = rect.insetBy(dx: -1, dy: -1)
        imageHandleView.frame = NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 12, height: 12)
        imageBorderView.isHidden = false
        imageHandleView.isHidden = false
        // Keep overlays above the text (same trick as ensureCaretOnTop).
        for v in [imageBorderView, imageHandleView] where subviews.last !== v {
            v.removeFromSuperview()
            addSubview(v)
        }
    }

    /// Returns the Y position of the top edge of the line at character index, and its height.
    private func lineGeometry(at charIndex: Int) -> (y: CGFloat, height: CGFloat)? {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage else { return nil }
        let str = ts.string as NSString
        let lineRange = str.lineRange(for: NSRange(location: min(charIndex, max(0, str.length - 1)), length: 0))
        let glyphRange = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        return (rect.origin.y + textContainerInset.height, rect.height)
    }

    override func mouseDragged(with event: NSEvent) {
        // Live image resize: scale width with the drag, aspect locked.
        if isResizingImage, let r = selectedImageRange,
           let att = imageAttachment(at: r.location), let ts = textStorage {
            let point = convert(event.locationInWindow, from: nil)
            let newWidth = min(max(60, resizeStartWidth + (point.x - resizeStartX)),
                               usableTextWidth())
            att.setDisplayWidth(newWidth)
            // An attachment's glyph size is cached by the layout manager, so a
            // bounds change needs an explicit layout+display invalidation —
            // `edited(.editedAttributes:)` alone leaves the old size on screen.
            ts.edited(.editedAttributes, range: r, changeInLength: 0)
            layoutManager?.invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
            layoutManager?.invalidateDisplay(forCharacterRange: r)
            positionImageOverlays()
            return
        }
        guard isDraggingLine, let storage = textStorage, let lm = layoutManager, let tc = textContainer else {
            super.mouseDragged(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        // Below the slop radius this is still a click, not a drag: leave
        // `dragDidMove` false so mouseUp toggles, and don't show drag chrome.
        if !dragDidMove {
            let dx = point.x - dragStartPoint.x
            let dy = point.y - dragStartPoint.y
            guard (dx * dx + dy * dy).squareRoot() >= Self.dragSlop else { return }
            dragDidMove = true
            dragSourceDim.isHidden = false
            NSCursor.closedHand.set()
        }
        let adjustedPoint = NSPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )

        let str = storage.string as NSString
        var fraction: CGFloat = 0
        let charIndex = lm.characterIndex(for: adjustedPoint, in: tc, fractionOfDistanceBetweenInsertionPoints: &fraction)
        let hoverLineRange = str.lineRange(for: NSRange(location: min(charIndex, max(0, str.length - 1)), length: 0))
        let sourceLineRange = str.lineRange(for: NSRange(location: min(dragStartLineIndex, max(0, str.length - 1)), length: 0))

        // Determine nesting level from mouse X position
        // Find the base indent of the neighbor line at drop target
        let hoverStr = str.substring(with: hoverLineRange)
        let neighborIndent = String(hoverStr.prefix(while: { $0 == " " }))
        let indentUnit: CGFloat = 28  // approximate width of 4 spaces in body font
        let baseX = textContainerInset.width + CGFloat(neighborIndent.count) * 7  // ~7pt per space

        // Mouse further right → nest deeper (one level = 4 spaces)
        let extraLevels = max(0, Int((point.x - baseX - 20) / indentUnit))
        let clampedLevels = min(extraLevels, 2)  // max 2 extra nesting levels
        let nestSpaces = String(repeating: " ", count: clampedLevels * 4)
        dragNestIndent = neighborIndent + nestSpaces

        // Determine if mouse is in top or bottom half of hovered line → insert above or below
        if let geo = lineGeometry(at: hoverLineRange.location) {
            let midY = geo.y + geo.height / 2
            let insertAbove = point.y < midY

            let insertCharIndex: Int
            if insertAbove {
                insertCharIndex = hoverLineRange.location
            } else {
                insertCharIndex = NSMaxRange(hoverLineRange)
            }

            let isOnSource = (insertCharIndex == sourceLineRange.location || insertCharIndex == NSMaxRange(sourceLineRange))
            dragInsertIndex = isOnSource ? -1 : insertCharIndex

            if isOnSource {
                dragInsertionLine.isHidden = true
            } else {
                let lineY: CGFloat = insertAbove ? geo.y - 1 : geo.y + geo.height - 1
                let indentOffset = CGFloat(dragNestIndent.count) * 7
                dragInsertionLine.frame = NSRect(
                    x: textContainerInset.width + 4 + indentOffset,
                    y: lineY,
                    width: bounds.width - textContainerInset.width * 2 - 8 - indentOffset,
                    height: 2
                )
                dragInsertionLine.isHidden = false
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        // Finish an image resize: register undo for the old width, then run the
        // normal change pipeline so the new width reaches the debounced save.
        if isResizingImage {
            isResizingImage = false
            if let r = selectedImageRange, let att = imageAttachment(at: r.location),
               att.displayWidth != resizeStartWidth {
                let oldWidth = resizeStartWidth
                undoManager?.registerUndo(withTarget: self) { tv in
                    att.setDisplayWidth(oldWidth)
                    tv.textStorage?.edited(.editedAttributes, range: r, changeInLength: 0)
                    tv.deselectImage()
                    tv.didChangeText()
                }
                undoManager?.setActionName("Resize Image")
                didChangeText()  // deselects; re-select below so handle stays usable
                if imageAttachment(at: r.location) != nil { selectImage(at: r.location) }
            }
            return
        }
        if isDraggingLine {
            isDraggingLine = false
            dragInsertionLine.isHidden = true
            dragSourceDim.isHidden = true
            NSCursor.arrow.set()

            guard let storage = textStorage else { return }
            let str = storage.string as NSString

            if !dragDidMove {
                // Didn't drag — treat as checkbox toggle
                let sourceLineRange = str.lineRange(for: NSRange(location: min(dragStartLineIndex, max(0, str.length - 1)), length: 0))
                let lineStr = str.substring(with: sourceLineRange)
                let leadingSpaces = lineStr.prefix(while: { $0 == " " }).count
                let afterIndent = String(lineStr.dropFirst(leadingSpaces))
                if afterIndent.hasPrefix("☐") || afterIndent.hasPrefix("☑") {
                    toggleCheckbox(at: sourceLineRange.location + leadingSpaces)
                }
                updateCaretPosition()
                return
            }

            guard dragInsertIndex >= 0 else {
                updateCaretPosition()
                return
            }

            let singleLineRange = str.lineRange(for: NSRange(location: min(dragStartLineIndex, max(0, str.length - 1)), length: 0))
            // Get full block (parent + children)
            let sourceBlockRange = blockRange(for: singleLineRange)

            // Snapshot full state for proper undo/redo
            let oldText = NSAttributedString(attributedString: storage)
            let oldSel = selectedRange()

            let sourceBlock = storage.attributedSubstring(from: sourceBlockRange)

            // Calculate insert position relative to after source removal
            var insertPos = dragInsertIndex
            if insertPos > sourceBlockRange.location {
                insertPos -= sourceBlockRange.length
            }

            // Remove source block
            storage.deleteCharacters(in: sourceBlockRange)

            let newStr = storage.string as NSString
            insertPos = min(insertPos, newStr.length)

            // Use the source block as-is (preserving all formatting and indentation)
            let mutable = NSMutableAttributedString(attributedString: sourceBlock)
            // Remove trailing newline from the mutable copy
            if mutable.string.hasSuffix("\n") {
                mutable.deleteCharacters(in: NSRange(location: mutable.length - 1, length: 1))
            }

            // Insert
            if insertPos >= newStr.length {
                // At end — prepend newline
                let final = NSMutableAttributedString(string: "\n")
                final.append(mutable)
                storage.insert(final, at: min(insertPos, storage.length))
            } else {
                mutable.append(NSAttributedString(string: "\n"))
                storage.insert(mutable, at: insertPos)
            }

            // Place caret after the prefix (smart home position)
            let finalPos = min(insertPos, storage.length)
            let (_, droppedPrefixLen) = listPrefixLen(at: min(finalPos, max(0, storage.length - 1)))
            let caretPos = min(finalPos + droppedPrefixLen, storage.length)
            setSelectedRange(NSRange(location: caretPos, length: 0))

            // Register undo — uses same recursive pattern as recordUndoSnapshot
            // so undo/redo chains indefinitely
            registerUndoWithState(oldText, selection: oldSel)

            didChangeText()
            updateCaretPosition()
            return
        }
        super.mouseUp(with: event)
        updateCaretPosition()
    }

    /// Captures current state for undo. Call BEFORE making changes.
    func recordUndoSnapshot() {
        guard let storage = textStorage else { return }
        registerUndoWithState(NSAttributedString(attributedString: storage), selection: selectedRange())
    }

    /// Registers an undo action that restores the given state. Chains indefinitely.
    private func registerUndoWithState(_ snapshot: NSAttributedString, selection: NSRange) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { tv in
            // Capture current state before restoring — this becomes the redo action
            guard let s = tv.textStorage else { return }
            tv.registerUndoWithState(NSAttributedString(attributedString: s), selection: tv.selectedRange())
            // Restore the snapshot
            s.setAttributedString(snapshot)
            tv.setSelectedRange(selection)
            tv.didChangeText()
        }
    }

    func toggleCheckbox(at charIndex: Int) {
        guard let storage = textStorage else { return }
        let str = storage.string as NSString
        guard charIndex >= 0 && charIndex < str.length else { return }
        let char = str.substring(with: NSRange(location: charIndex, length: 1))
        let lineRange = str.lineRange(for: NSRange(location: charIndex, length: 0))

        // Content range: after "☐ " or "☑ ", excluding trailing newline
        let contentStart = min(charIndex + 2, str.length)
        var lineEnd = lineRange.location + lineRange.length
        if lineEnd > contentStart && lineEnd > 0 && str.substring(with: NSRange(location: lineEnd - 1, length: 1)) == "\n" {
            lineEnd -= 1
        }
        let contentRange = NSRange(location: contentStart, length: max(0, lineEnd - contentStart))

        // Don't toggle empty checkboxes (prefix only, no content)
        let content = contentRange.length > 0 ? str.substring(with: contentRange).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard !content.isEmpty else { return }

        recordUndoSnapshot()

        let boxRange = NSRange(location: charIndex, length: 1)

        if char == "☐" {
            storage.replaceCharacters(in: boxRange, with: "☑")
            Tokens.Typography.styleCheckboxGlyph(storage, range: boxRange, checked: true)
            if contentRange.length > 0 {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: contentRange)
                let muted = (editorViewModel?.theme.editorTextNS ?? NSColor.textColor).withAlphaComponent(0.55)
                storage.addAttribute(.foregroundColor, value: muted, range: contentRange)
            }
        } else if char == "☑" {
            storage.replaceCharacters(in: boxRange, with: "☐")
            Tokens.Typography.styleCheckboxGlyph(storage, range: boxRange, checked: false)
            if contentRange.length > 0 {
                storage.removeAttribute(.strikethroughStyle, range: contentRange)
                let body = editorViewModel?.theme.editorTextNS ?? NSColor.textColor
                storage.addAttribute(.foregroundColor, value: body, range: contentRange)
            }
        }

        // Place caret at end of line content
        setSelectedRange(NSRange(location: lineEnd, length: 0))
        didChangeText()
    }

    override func layout() {
        super.layout()
        updateCaretPosition()
    }

    private func moveCaretTo(_ newFrame: NSRect) {
        if caretView.superview == nil {
            addSubview(caretView)
            caretView.frame = newFrame
            return
        }
        // Smooth slide animation like Office 2013
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            caretView.animator().frame = newFrame
        }
    }

    /// Font the caret sizes itself to: the glyph adjacent to the caret in the
    /// document, or — on an empty line/doc — the current typing attributes (which
    /// may be the H1 title line). Falls back to Body. Keeps the block caret's
    /// height matched to the text at the caret, so it's tall on H1/H2/H3 lines
    /// instead of always body-height.
    private func caretFont() -> NSFont {
        if let storage = textStorage, storage.length > 0 {
            let ns = storage.string as NSString
            let loc = min(selectedRange().location, storage.length)
            // Probe the glyph left of the caret (what you just typed / are
            // extending). Skip when it's a newline (caret at line start) — then
            // fall back to typing attributes for the line you're on.
            let probe = loc > 0 ? loc - 1 : 0
            if ns.character(at: probe) != 0x0A,
               let f = storage.attribute(.font, at: probe, effectiveRange: nil) as? NSFont {
                return f
            }
            return (typingAttributes[.font] as? NSFont) ?? Tokens.Typography.body()
        }
        // Empty document: match the visible "Start writing…" placeholder (body
        // size) rather than the H1 typingAttributes pre-armed for the first
        // character typed — that only takes over once something is actually typed.
        return Tokens.Typography.body()
    }

    func updateCaretPosition() {
        caretView.isHidden = selectedRange().length > 0 || !isEditorFocused
            || !(window?.isKeyWindow ?? false)

        // Empty doc: the insertion line is the extra line fragment, which is
        // H1-tall while the title line is armed — but the body-sized caret must
        // center in the SAME rect the ghost "Start writing…" prompt centers in
        // (emptyDocLineRect, shared with draw(_:)), or the two visibly misalign.
        if string.isEmpty {
            let baseFont = caretFont()
            let h = ceil(baseFont.ascender - baseFont.descender)
            let lineRect = emptyDocLineRect()
            moveCaretTo(NSRect(
                x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                y: textContainerInset.height + lineRect.minY + (lineRect.height - h) / 2,
                width: 2, height: h
            ))
            ensureCaretOnTop()
            return
        }

        // Use NSTextView's own insertion point rect — most reliable
        let charIndex = selectedRange().location
        var rectCount: Int = 0
        guard let rects = layoutManager?.rectArray(
            forCharacterRange: NSRange(location: charIndex, length: 0),
            withinSelectedCharacterRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer!,
            rectCount: &rectCount
        ), rectCount > 0 else { return }

        let rect = rects[0]
        let baseFont = caretFont()
        let h = ceil(baseFont.ascender - baseFont.descender)
        let y = rect.origin.y + textContainerInset.height + (rect.height - h) / 2

        moveCaretTo(NSRect(
            x: rect.origin.x + textContainerInset.width,
            y: y,
            width: 2, height: h
        ))
        ensureCaretOnTop()
    }

    private func ensureCaretOnTop() {
        if caretView.superview != self || subviews.last !== caretView {
            caretView.removeFromSuperview()
            addSubview(caretView)
        }
    }
}

// MARK: - Rich Text Editor (NSTextView WYSIWYG)

/// NSTextStorage whose attribute fixing keeps the SF Rounded font on unchecked
/// ☐ glyphs. SF Rounded has no ☐, so stock font fixing swaps in Apple Symbols
/// (a thin, square-cornered box) — which also breaks the NSGlyphInfo that maps
/// ☐ to SF Rounded's □ glyph, because glyphInfo is honored only while the font
/// attribute matches the font it was created with. After the stock fixing pass
/// we re-pin the rounded font on every ☐ that carries the glyphInfo substitution.
final class CheckboxTextStorage: NSTextStorage {
    private let backing = NSMutableAttributedString()

    override var string: String { backing.string }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    override func fixAttributes(in range: NSRange) {
        super.fixAttributes(in: range)
        let ns = backing.string as NSString
        var i = range.location
        let end = NSMaxRange(range)
        while i < end {
            if ns.character(at: i) == 0x2610 { // ☐
                let attrs = backing.attributes(at: i, effectiveRange: nil)
                if attrs[.glyphInfo] != nil, let f = attrs[.font] as? NSFont {
                    backing.addAttribute(.font,
                                         value: Tokens.Typography.rounded(size: f.pointSize, weight: .medium),
                                         range: NSRange(location: i, length: 1))
                }
            }
            i += 1
        }
    }
}

struct RichTextEditor: NSViewRepresentable {
    @EnvironmentObject var vm: EditorViewModel

    func makeCoordinator() -> Coordinator { Coordinator(vm: vm, initialTheme: vm.theme) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let contentSize = scrollView.contentSize
        let textContainer = NSTextContainer(containerSize: NSSize(width: contentSize.width, height: .greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = CheckboxTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textView = BlockCaretTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: textContainer)
        textView.editorViewModel = vm
        textView.autoresizingMask = [.width]
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.backgroundColor = vm.theme.editorBackgroundNS
        textView.insertionPointColor = vm.theme.editorCaretNS
        textView.setCaretColor(vm.theme.editorCaretNS)
        textView.textContainerInset = NSSize(width: 40, height: 24)

        // Center the text column with a max readable width. Updated whenever
        // the scroll view's frame changes (window resize, sidebar/terminal toggle).
        scrollView.postsFrameChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        let maxContentWidth: CGFloat = 640
        let minSideInset: CGFloat = 24
        let updateInset: () -> Void = { [weak scrollView, weak textView, weak coordinator = context.coordinator] in
            guard let sv = scrollView, let tv = textView, let coord = coordinator else { return }
            // Setting the inset / container size below mutates the text view's frame,
            // which re-posts frameDidChangeNotification → this closure. Bail if we're
            // already inside an update so the feedback loop can't spin (app hang).
            guard !coord.isUpdatingInset else { return }
            let viewW = sv.frame.width > 0 ? sv.frame.width : sv.contentSize.width
            guard viewW > 0 else { return }
            let target = max(minSideInset, (viewW - maxContentWidth) / 2)
            let newContainerW = max(1, viewW - 2*target)
            // Idempotent: only write (and thus re-fire the notification) when a value
            // actually changes.
            let insetChanged = abs(tv.textContainerInset.width - target) > 0.5
            let containerChanged = abs((tv.textContainer?.containerSize.width ?? 0) - newContainerW) > 0.5
            guard insetChanged || containerChanged else { return }
            coord.isUpdatingInset = true
            tv.textContainerInset = NSSize(width: target, height: tv.textContainerInset.height)
            if let tc = tv.textContainer {
                tc.containerSize = NSSize(width: newContainerW, height: .greatestFiniteMagnitude)
            }
            tv.needsLayout = true
            tv.needsDisplay = true
            coord.isUpdatingInset = false
        }
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView,
            queue: .main
        ) { _ in updateInset() }
        context.coordinator.textFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: textView,
            queue: .main
        ) { _ in updateInset() }
        // Fire repeatedly during initial layout passes to catch the moment the
        // scroll view has its real frame.
        for delay in [0.0, 0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { updateInset() }
        }
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.baseWritingDirection = .leftToRight
        textView.defaultParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.baseWritingDirection = .leftToRight
            p.alignment = .left
            p.applyReadableBodySpacing()
            return p
        }()

        let defaultFont = Tokens.Typography.body()
        let ltrParagraph = NSMutableParagraphStyle()
        ltrParagraph.baseWritingDirection = .leftToRight
        ltrParagraph.alignment = .left
        ltrParagraph.applyReadableBodySpacing()
        textView.typingAttributes = [
            .font: defaultFont,
            .foregroundColor: vm.theme.editorTextNS,
            .paragraphStyle: ltrParagraph
        ]

        scrollView.documentView = textView
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        // Capture/restore per-note scroll + caret position so switching tabs
        // returns the user to where they were.
        vm.captureScrollState = { [weak scrollView, weak textView] in
            guard let sv = scrollView, let tv = textView else { return nil }
            return (sv.contentView.bounds.origin.y, tv.selectedRange())
        }
        vm.restoreScrollState = { [weak scrollView, weak textView] y, sel in
            guard let sv = scrollView, let tv = textView else { return }
            let clampedStart = max(0, min(sel.location, tv.textStorage?.length ?? 0))
            let clampedLen = max(0, min(sel.length, (tv.textStorage?.length ?? 0) - clampedStart))
            tv.setSelectedRange(NSRange(location: clampedStart, length: clampedLen))
            sv.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
            sv.reflectScrolledClipView(sv.contentView)
        }

        vm.onContentLoaded = { [weak textView] attrStr in
            DispatchQueue.main.async {
                guard let textView else { return }
                // Fix LTR on the attributed string BEFORE setting it
                let fixed = NSMutableAttributedString(attributedString: attrStr)
                // Strip trailing newlines (HTML parsing always adds one)
                while fixed.length > 0 && fixed.string.hasSuffix("\n") {
                    fixed.deleteCharacters(in: NSRange(location: fixed.length - 1, length: 1))
                }
                let fullRange = NSRange(location: 0, length: fixed.length)
                if fullRange.length > 0 {
                    let ltr = NSMutableParagraphStyle()
                    ltr.baseWritingDirection = .leftToRight
                    ltr.alignment = .left
                    ltr.applyReadableBodySpacing()
                    // Apply LTR paragraph style to all lines
                    fixed.addAttribute(.paragraphStyle, value: ltr, range: fullRange)
                    // Apply theme body color to every non-accent run (preserve headings/links).
                    let bodyColor = vm.theme.editorTextNS
                    fixed.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, range, _ in
                        let isAccent: Bool
                        if let c = (value as? NSColor)?.usingColorSpace(.genericRGB) {
                            isAccent = c.blueComponent > 0.85 && c.redComponent < 0.6
                        } else {
                            isAccent = false
                        }
                        if !isAccent {
                            fixed.addAttribute(.foregroundColor, value: bodyColor, range: range)
                        }
                    }
                }
                textView.textStorage?.setAttributedString(fixed)
                // Apply checklist styling and hanging indent to all lines
                if let storage = textView.textStorage {
                    let str = storage.string as NSString
                    var pos = 0
                    while pos < str.length {
                        let lr = str.lineRange(for: NSRange(location: pos, length: 0))
                        let ls = str.substring(with: lr)
                        // Handle indented checkboxes too
                        let leading = ls.prefix(while: { $0 == " " || $0 == "\u{00a0}" })
                        let afterIndent = String(ls.dropFirst(leading.count))
                        if afterIndent.hasPrefix("☑") {
                            let checkPos = lr.location + leading.count
                            let cStart = checkPos + 2
                            var lEnd = lr.location + lr.length
                            if lEnd > cStart && str.substring(with: NSRange(location: lEnd - 1, length: 1)) == "\n" {
                                lEnd -= 1
                            }
                            let cRange = NSRange(location: cStart, length: max(0, lEnd - cStart))
                            if cRange.length > 0 {
                                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: cRange)
                                storage.addAttribute(.foregroundColor, value: vm.theme.editorTextNS.withAlphaComponent(0.55), range: cRange)
                            }
                        }
                        // Enlarge checkbox glyphs (☐/☑) so they read as proper boxes.
                        if afterIndent.hasPrefix("☐") || afterIndent.hasPrefix("☑") {
                            let boxStart = lr.location + leading.count
                            let boxRange = NSRange(location: boxStart, length: 1)
                            Tokens.Typography.styleCheckboxGlyph(storage, range: boxRange, checked: afterIndent.hasPrefix("☑"))
                            // Slight baseline nudge so the bigger glyph sits on the text baseline.
                        }
                        let next = lr.location + lr.length
                        if next <= pos { break }
                        pos = next
                    }
                }
                // Apply hanging indent to all list lines
                context.coordinator.applyListIndentToAllLines(textView: textView)
                // Move cursor to start
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.updateCaretPosition()
                // Reset typing attributes to defaults (prevents stale styles
                // leaking between tabs). Empty notes type as Body — the note's
                // title lives in the sidebar, not the document.
                textView.typingAttributes = textView.bodyLineTypingAttributes()
                textView.updateCaretPosition()  // size caret to the loaded line's font
                // Sync coordinator's lastSelectedRange so toolbar buttons work
                self.vm.editorCoordinator?.lastSelectedRange = NSRange(location: 0, length: 0)
            }
        }

        vm.editorCoordinator = context.coordinator

        // Load initial content if it was ready before the view was created
        if vm.attributedText.length > 0 {
            vm.onContentLoaded?(vm.attributedText)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let theme = vm.theme
        if context.coordinator.appliedTheme != theme {
            context.coordinator.applyTheme(theme, to: textView)
            context.coordinator.appliedTheme = theme
        }
        // Keep the empty-note placeholder in sync with tab switches: the
        // ghost "Title" line shows on any empty note.
        if textView.string.isEmpty {
            textView.needsDisplay = true
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        let vm: EditorViewModel
        weak var textView: NSTextView?
        var appliedTheme: AppTheme
        var frameObserver: NSObjectProtocol?
        var textFrameObserver: NSObjectProtocol?
        /// Re-entrancy guard for `updateInset`: setting the text container size re-fires
        /// `frameDidChangeNotification` on the text view, which would call `updateInset`
        /// again. Without this flag the feedback loop can spin forever (app hang).
        var isUpdatingInset = false

        deinit {
            if let o = frameObserver { NotificationCenter.default.removeObserver(o) }
            if let o = textFrameObserver { NotificationCenter.default.removeObserver(o) }
        }

        // Computed (not captured) so a live font-family / body-size change is
        // reflected by formatting operations without recreating the editor.
        var bodyFont: NSFont { Tokens.Typography.body() }
        var h1Font: NSFont { Tokens.Typography.bold(size: Tokens.Typography.h1Size) }
        var h2Font: NSFont { Tokens.Typography.bold(size: Tokens.Typography.h2Size) }
        var h3Font: NSFont { Tokens.Typography.bold(size: Tokens.Typography.h3Size) }
        var textColor: NSColor

        /// Recolor editor surface + swap previous body-text color on existing content.
        func applyTheme(_ theme: AppTheme, to textView: NSTextView) {
            let oldBody = textColor
            let newBody = theme.editorTextNS
            textColor = newBody

            textView.backgroundColor = theme.editorBackgroundNS
            textView.insertionPointColor = theme.editorCaretNS
            (textView as? BlockCaretTextView)?.setCaretColor(theme.editorCaretNS)

            // Update typing attributes for future typing
            var attrs = textView.typingAttributes
            if let fg = attrs[.foregroundColor] as? NSColor,
               colorsMatch(fg, oldBody) {
                attrs[.foregroundColor] = newBody
                textView.typingAttributes = attrs
            } else {
                attrs[.foregroundColor] = newBody
                textView.typingAttributes = attrs
            }

            // Recolor existing runs that match the previous body color.
            // Leave accent-colored runs (links, etc.) untouched.
            guard let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
                if value == nil {
                    storage.addAttribute(.foregroundColor, value: newBody, range: range)
                } else if let c = value as? NSColor, colorsMatch(c, oldBody) {
                    storage.addAttribute(.foregroundColor, value: newBody, range: range)
                }
            }
            storage.endEditing()
        }

        private func colorsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
            guard let ac = a.usingColorSpace(.genericRGB),
                  let bc = b.usingColorSpace(.genericRGB) else { return false }
            let tol: CGFloat = 0.02
            return abs(ac.redComponent - bc.redComponent) < tol
                && abs(ac.greenComponent - bc.greenComponent) < tol
                && abs(ac.blueComponent - bc.blueComponent) < tol
        }

        private var isProcessingMarkdown = false
        var lastSelectedRange: NSRange = NSRange(location: 0, length: 0)

        init(vm: EditorViewModel, initialTheme: AppTheme) {
            self.vm = vm
            self.appliedTheme = initialTheme
            self.textColor = initialTheme.editorTextNS
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            lastSelectedRange = textView.selectedRange()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }

            if !isProcessingMarkdown {
                isProcessingMarkdown = true
                processMarkdownShortcuts(textView: textView)
                isProcessingMarkdown = false
            }

            applyListIndentForCurrentLine(textView: textView)

            let length = textView.textStorage?.length ?? 0
            let unchecked = NoteTab.countUnchecked(in: textView.textStorage?.string ?? "")
            Task { @MainActor in
                vm.textDidChange(html: "", length: length, uncheckedCount: unchecked)
            }
        }

        /// Apply hanging indent to the current line only (where cursor is).
        private func applyListIndentForCurrentLine(textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let str = storage.string as NSString
            guard str.length > 0 else { return }

            let cursor = textView.selectedRange().location
            let lineRange = str.lineRange(for: NSRange(location: min(cursor, max(0, str.length - 1)), length: 0))
            applyListIndentToRange(storage: storage, lineRange: lineRange)

            // Re-check previous line (may have gained/lost parent status)
            if lineRange.location > 0 {
                let prevLineRange = str.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
                applyListIndentToRange(storage: storage, lineRange: prevLineRange)
            }

            // Re-check next line (current line may now be its parent)
            let lineEnd = NSMaxRange(lineRange)
            if lineEnd < str.length {
                let nextLineRange = str.lineRange(for: NSRange(location: lineEnd, length: 0))
                applyListIndentToRange(storage: storage, lineRange: nextLineRange)
            }
        }

        /// Returns the indent level (number of leading whitespace chars) for a line.
        private func indentLevel(of lineStr: String) -> Int {
            lineStr.prefix(while: { $0 == " " || $0 == "\u{00a0}" }).count
        }

        /// Apply hanging indent and parent spacing to a specific line range.
        private func applyListIndentToRange(storage: NSTextStorage, lineRange: NSRange) {
            let str = storage.string as NSString
            let lineStr = str.substring(with: lineRange)

            let leadingWS = lineStr.prefix(while: { $0 == " " || $0 == "\u{00a0}" })
            let afterIndent = String(lineStr.dropFirst(leadingWS.count))

            var prefixStr: String? = nil
            for pfx in ["• ", "☐ ", "☑ "] {
                if afterIndent.hasPrefix(pfx) {
                    prefixStr = String(leadingWS) + pfx
                    break
                }
            }

            if let prefix = prefixStr {
                let prefixWidth = (prefix as NSString).size(withAttributes: [.font: bodyFont]).width
                let ps = NSMutableParagraphStyle.tightListItem(headIndent: prefixWidth)

                // Check if next line is indented deeper → this is a "parent" item
                let lineEnd = NSMaxRange(lineRange)
                if lineEnd < str.length {
                    let nextLineRange = str.lineRange(for: NSRange(location: lineEnd, length: 0))
                    let nextLineStr = str.substring(with: nextLineRange)
                    let currentIndent = indentLevel(of: lineStr)
                    let nextIndent = indentLevel(of: nextLineStr)
                    let nextHasPrefix = nextLineStr.dropFirst(nextIndent).hasPrefix("• ") ||
                                        nextLineStr.dropFirst(nextIndent).hasPrefix("☐ ") ||
                                        nextLineStr.dropFirst(nextIndent).hasPrefix("☑ ")
                    if nextHasPrefix && nextIndent > currentIndent {
                        ps.paragraphSpacingBefore = Tokens.Spacing.listParentSpacingBefore
                    }
                }

                storage.addAttribute(.paragraphStyle, value: ps, range: lineRange)
            }
        }

        /// Apply hanging indent and parent spacing to ALL list lines.
        func applyListIndentToAllLines(textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let str = storage.string as NSString
            guard str.length > 0 else { return }

            // Collect all line ranges first
            var lines: [(range: NSRange, str: String)] = []
            var pos = 0
            while pos < str.length {
                let lr = str.lineRange(for: NSRange(location: pos, length: 0))
                lines.append((lr, str.substring(with: lr)))
                pos = NSMaxRange(lr)
            }

            storage.beginEditing()
            for i in 0..<lines.count {
                let lineRange = lines[i].range
                let lineStr = lines[i].str

                let leadingWS = lineStr.prefix(while: { $0 == " " || $0 == "\u{00a0}" })
                let afterIndent = String(lineStr.dropFirst(leadingWS.count))

                var prefixStr: String? = nil
                for pfx in ["• ", "☐ ", "☑ "] {
                    if afterIndent.hasPrefix(pfx) {
                        prefixStr = String(leadingWS) + pfx
                        break
                    }
                }

                if let prefix = prefixStr {
                    let prefixWidth = (prefix as NSString).size(withAttributes: [.font: bodyFont]).width
                    let ps = NSMutableParagraphStyle.tightListItem(headIndent: prefixWidth)

                    let currentIndent = indentLevel(of: lineStr)

                    // Add spacing before parent items that have indented children
                    if i + 1 < lines.count {
                        let nextStr = lines[i + 1].str
                        let nextIndent = indentLevel(of: nextStr)
                        let nextHasPrefix = nextStr.dropFirst(nextIndent).hasPrefix("• ") ||
                                            nextStr.dropFirst(nextIndent).hasPrefix("☐ ") ||
                                            nextStr.dropFirst(nextIndent).hasPrefix("☑ ")
                        if nextHasPrefix && nextIndent > currentIndent {
                            if i > 0 {
                                let prevStr = lines[i - 1].str
                                let prevIndent = indentLevel(of: prevStr)
                                if prevIndent <= currentIndent {
                                    ps.paragraphSpacingBefore = Tokens.Spacing.listParentSpacingBefore
                                }
                            }
                        }
                    }

                    storage.addAttribute(.paragraphStyle, value: ps, range: lineRange)

                    // Bump size of the checkbox glyph (☐/☑) so it reads as a real box.
                    if afterIndent.hasPrefix("☐") || afterIndent.hasPrefix("☑") {
                        let boxStart = lineRange.location + leadingWS.count
                        let boxRange = NSRange(location: boxStart, length: 1)
                        Tokens.Typography.styleCheckboxGlyph(storage, range: boxRange, checked: afterIndent.hasPrefix("☑"))
                    }
                }
            }
            storage.endEditing()
        }

        private func processMarkdownShortcuts(textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let cursor = textView.selectedRange().location
            guard cursor > 0 else { return }

            let str = storage.string as NSString
            let lineRange = str.lineRange(for: NSRange(location: cursor - 1, length: 0))
            let beforeCursor = str.substring(with: NSRange(location: lineRange.location, length: cursor - lineRange.location))

            switch beforeCursor {
            case "### ":
                replaceMarkdownPrefix(storage: storage, textView: textView, at: lineRange.location, len: 4, font: h3Font)
            case "## ":
                replaceMarkdownPrefix(storage: storage, textView: textView, at: lineRange.location, len: 3, font: h2Font)
            case "# ":
                replaceMarkdownPrefix(storage: storage, textView: textView, at: lineRange.location, len: 2, font: h1Font)
            case "- ", "* ":
                replaceMarkdownWithText(storage: storage, textView: textView, at: lineRange.location, len: 2, replacement: "• ")
            case "- [ ] ", "- [] ", "[] ", "[ ] ":
                replaceMarkdownWithText(storage: storage, textView: textView, at: lineRange.location, len: beforeCursor.count, replacement: "☐ ")
            case "- [x] ", "[x] ":
                replaceMarkdownWithText(storage: storage, textView: textView, at: lineRange.location, len: beforeCursor.count, replacement: "☑ ")
            case "/":
                let tv = textView
                let pos = lineRange.location
                DispatchQueue.main.async { [self] in
                    self.showSlashMenu(textView: tv, at: pos)
                }
            default:
                let trimmed = beforeCursor.trimmingCharacters(in: .newlines)
                if trimmed == "---" {
                    let divider = NSAttributedString(string: "───────────────────", attributes: [
                        .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1.0),
                        .font: bodyFont
                    ])
                    storage.replaceCharacters(in: NSRange(location: lineRange.location, length: cursor - lineRange.location), with: divider)
                    textView.setSelectedRange(NSRange(location: lineRange.location + divider.length, length: 0))
                }
            }
        }

        private func replaceMarkdownPrefix(storage: NSTextStorage, textView: NSTextView, at lineStart: Int, len: Int, font: NSFont) {
            storage.replaceCharacters(in: NSRange(location: lineStart, length: len), with: "")
            textView.setSelectedRange(NSRange(location: lineStart, length: 0))
            textView.typingAttributes[.font] = font
            textView.typingAttributes[.foregroundColor] = textColor
        }

        private func replaceMarkdownWithText(storage: NSTextStorage, textView: NSTextView, at lineStart: Int, len: Int, replacement: String) {
            let attr = NSMutableAttributedString(string: replacement, attributes: [
                .font: bodyFont,
                .foregroundColor: textColor
            ])
            if replacement.hasPrefix("☐") || replacement.hasPrefix("☑") {
                Tokens.Typography.styleCheckboxGlyph(attr, range: NSRange(location: 0, length: 1), checked: replacement.hasPrefix("☑"))
            }
            storage.replaceCharacters(in: NSRange(location: lineStart, length: len), with: attr)
            textView.setSelectedRange(NSRange(location: lineStart + replacement.count, length: 0))
        }

        private var slashPosition: Int = 0
        private var fromSlashMenu = false

        private func showSlashMenu(textView: NSTextView, at slashPos: Int) {
            slashPosition = slashPos
            let menu = NSMenu(title: "Insert")

            let items: [(title: String, icon: String, tag: Int)?] = [
                ("Heading 1", "textformat.size.larger", 1),
                ("Heading 2", "textformat.size", 2),
                ("Heading 3", "textformat.size.smaller", 3),
                nil,
                ("Bullet List", "list.bullet", 4),
                ("Checklist", "checklist", 5),
                nil,
                ("Divider", "minus", 7),
            ]

            for item in items {
                if let item = item {
                    let mi = NSMenuItem(title: item.title, action: #selector(slashMenuItemClicked(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.tag = item.tag
                    mi.image = NSImage(systemSymbolName: item.icon, accessibilityDescription: item.title)
                    menu.addItem(mi)
                } else {
                    menu.addItem(.separator())
                }
            }

            // Position menu at the slash character
            var rectCount: Int = 0
            if let lm = textView.layoutManager, let tc = textView.textContainer,
               slashPos < (textView.textStorage?.length ?? 0),
               let rects = lm.rectArray(
                   forCharacterRange: NSRange(location: slashPos, length: 1),
                   withinSelectedCharacterRange: NSRange(location: NSNotFound, length: 0),
                   in: tc, rectCount: &rectCount
               ), rectCount > 0 {
                let rect = rects[0]
                let point = NSPoint(
                    x: rect.origin.x + textView.textContainerInset.width,
                    y: rect.origin.y + textView.textContainerInset.height + rect.height + 4
                )
                menu.popUp(positioning: nil, at: point, in: textView)
            } else {
                menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            }
        }

        private func recordUndo(for textView: NSTextView) {
            if let blockTV = textView as? BlockCaretTextView {
                blockTV.recordUndoSnapshot()
            } else {
                guard let storage = textView.textStorage, let um = textView.undoManager else { return }
                let snapshot = NSAttributedString(attributedString: storage)
                let sel = textView.selectedRange()
                um.registerUndo(withTarget: textView) { [weak self] tv in
                    self?.recordUndo(for: tv)
                    tv.textStorage?.setAttributedString(snapshot)
                    tv.setSelectedRange(sel)
                    tv.didChangeText()
                }
            }
        }

        @objc private func slashMenuItemClicked(_ sender: NSMenuItem) {
            guard let textView = self.textView else { return }
            guard let storage = textView.textStorage else { return }

            recordUndo(for: textView)

            // Remove the "/" character (validate position and content)
            if slashPosition >= 0 && slashPosition < storage.length {
                let charAtPos = (storage.string as NSString).substring(with: NSRange(location: slashPosition, length: 1))
                if charAtPos == "/" {
                    storage.replaceCharacters(in: NSRange(location: slashPosition, length: 1), with: "")
                    textView.setSelectedRange(NSRange(location: slashPosition, length: 0))
                }
            }

            fromSlashMenu = true
            switch sender.tag {
            case 1: applyFormat(.heading1, textView: textView)
            case 2: applyFormat(.heading2, textView: textView)
            case 3: applyFormat(.heading3, textView: textView)
            case 4: applyFormat(.bulletList, textView: textView)
            case 5: applyFormat(.checklist, textView: textView)
            case 7: applyFormat(.divider, textView: textView)
            default: break
            }
            fromSlashMenu = false
            textView.didChangeText()
        }

        func extractHTML(from textView: NSTextView) -> String {
            guard let storage = textView.textStorage, storage.length > 0 else { return "" }
            // Image attachments don't survive the Cocoa HTML exporter — swap
            // them for plain-text ⟦img:…⟧ markers on a COPY (never the live storage).
            let copy = NSMutableAttributedString(attributedString: storage)
            copy.replaceImageAttachmentsWithMarkers(font: bodyFont, color: textColor)
            let range = NSRange(location: 0, length: copy.length)
            guard let data = try? copy.data(from: range, documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }

        func applyFormat(_ action: FormatAction, textView: NSTextView) {
            let range = textView.selectedRange()
            guard let storage = textView.textStorage else {
                dbg("applyFormat BAIL: storage is nil")
                return
            }
            dbg("applyFormat: action=\(action), range=(\(range.location),\(range.length)), storageLen=\(storage.length), text='\(storage.string.prefix(50))'")

            recordUndo(for: textView)

            switch action {
            case .bold:
                storage.beginEditing()
                toggleTrait(.boldFontMask, in: range, storage: storage, textView: textView)
                storage.endEditing()
            case .italic:
                storage.beginEditing()
                toggleTrait(.italicFontMask, in: range, storage: storage, textView: textView)
                storage.endEditing()
            case .underline:
                storage.beginEditing()
                if range.length > 0 {
                    let current = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
                    let newVal = current == 0 ? NSUnderlineStyle.single.rawValue : 0
                    storage.addAttribute(.underlineStyle, value: newVal, range: range)
                } else {
                    let current = textView.typingAttributes[.underlineStyle] as? Int ?? 0
                    textView.typingAttributes[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
                }
                storage.endEditing()
            case .heading1:
                storage.beginEditing()
                applyFont(h1Font, in: range, storage: storage, textView: textView)
                storage.endEditing()
            case .heading2:
                storage.beginEditing()
                applyFont(h2Font, in: range, storage: storage, textView: textView)
                storage.endEditing()
            case .heading3:
                storage.beginEditing()
                applyFont(h3Font, in: range, storage: storage, textView: textView)
                storage.endEditing()
            case .body:
                storage.beginEditing()
                applyFont(bodyFont, in: range, storage: storage, textView: textView)
                storage.endEditing()
            case .bulletList:
                insertAtLineStart(textView: textView, prefix: "• ")
            case .checklist:
                toggleChecklist(textView: textView, storage: storage, range: range)
            case .link:
                let sel = range.length > 0 ? (storage.string as NSString).substring(with: range) : "link"
                let alert = NSAlert()
                alert.messageText = "Insert Link"
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Cancel")
                let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                input.placeholderString = "https://..."
                alert.accessoryView = input
                if alert.runModal() == .alertFirstButtonReturn {
                    let url = input.stringValue
                    if !url.isEmpty {
                        storage.beginEditing()
                        let linkStr = NSMutableAttributedString(string: sel, attributes: [
                            .link: URL(string: url) as Any,
                            .foregroundColor: NSColor(calibratedRed: 0.42, green: 0.68, blue: 1.0, alpha: 1.0),
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .font: bodyFont
                        ])
                        storage.replaceCharacters(in: range, with: linkStr)
                        storage.endEditing()
                        // Place caret after the link and clear link styling so
                        // subsequent typing is plain body text.
                        textView.setSelectedRange(NSRange(location: range.location + linkStr.length, length: 0))
                        textView.typingAttributes = [
                            .font: bodyFont,
                            .foregroundColor: textColor
                        ]
                    }
                }
            case .divider:
                storage.beginEditing()
                let divider = NSMutableAttributedString(string: "\n───────────────────\n", attributes: [
                    .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1.0),
                    .font: bodyFont
                ])
                storage.insert(divider, at: range.location)
                storage.endEditing()
            }
            textView.didChangeText()
        }

        private func toggleTrait(_ trait: NSFontTraitMask, in range: NSRange, storage: NSTextStorage, textView: NSTextView) {
            if range.length > 0 {
                storage.enumerateAttribute(.font, in: range) { value, subRange, _ in
                    guard let font = value as? NSFont else { return }
                    let fm = NSFontManager.shared
                    let newFont = fm.convert(font, toHaveTrait: fm.traits(of: font).contains(trait) ? fm.traits(of: font).subtracting(trait) : trait)
                    storage.addAttribute(.font, value: newFont, range: subRange)
                }
            } else {
                let current = textView.typingAttributes[.font] as? NSFont ?? bodyFont
                let fm = NSFontManager.shared
                let hasTrait = fm.traits(of: current).contains(trait)
                let newFont = fm.convert(current, toHaveTrait: hasTrait ? fm.traits(of: current).subtracting(trait) : trait)
                textView.typingAttributes[.font] = newFont
            }
        }

        private func applyFont(_ font: NSFont, in range: NSRange, storage: NSTextStorage, textView: NSTextView) {
            if range.length > 0 {
                let lineRange = (storage.string as NSString).lineRange(for: range)
                storage.addAttribute(.font, value: font, range: lineRange)
                storage.addAttribute(.foregroundColor, value: textColor, range: lineRange)
            } else {
                textView.typingAttributes[.font] = font
                textView.typingAttributes[.foregroundColor] = textColor
            }
        }

        private func insertAtLineStart(textView: NSTextView, prefix: String) {
            let range = textView.selectedRange()
            guard let storage = textView.textStorage else { return }
            let str = storage.string as NSString

            // Caret at beginning of a list line → insert new line with prefix above, push current line down
            // (skip when invoked from slash menu — user wants prefix on current line)
            if !fromSlashMenu && range.length == 0 && str.length > 0 && range.location < str.length {
                let lineRange = str.lineRange(for: NSRange(location: range.location, length: 0))
                let lineStr = str.substring(with: lineRange)
                let isAtLineStart = range.location == lineRange.location
                let hasListPrefix = lineStr.hasPrefix("• ") || lineStr.hasPrefix("☐ ") || lineStr.hasPrefix("☑ ")
                if isAtLineStart && hasListPrefix {
                    let newLine = NSAttributedString(string: prefix + "\n", attributes: [.font: bodyFont, .foregroundColor: textColor])
                    storage.insert(newLine, at: lineRange.location)
                    textView.setSelectedRange(NSRange(location: lineRange.location + prefix.count, length: 0))
                    textView.didChangeText()
                    return
                }
            }

            // Handle cursor at end of text or empty document
            let adjustedRange: NSRange
            if str.length == 0 || (fromSlashMenu && range.location == str.length && range.length == 0) {
                // Insert prefix at current position
                let insertPos = min(range.location, str.length)
                let attrPrefix = NSAttributedString(string: prefix, attributes: [.font: bodyFont, .foregroundColor: textColor])
                storage.insert(attrPrefix, at: insertPos)
                textView.setSelectedRange(NSRange(location: insertPos + prefix.count, length: 0))
                textView.didChangeText()
                return
            } else if range.location == str.length && range.length == 0 {
                adjustedRange = NSRange(location: max(0, range.location - 1), length: 0)
            } else {
                adjustedRange = range
            }

            let fullLineRange = str.lineRange(for: adjustedRange)
            dbg("insertAtLineStart: prefix='\(prefix)', range=(\(range.location),\(range.length)), adjusted=(\(adjustedRange.location),\(adjustedRange.length)), fullLine=(\(fullLineRange.location),\(fullLineRange.length)), strLen=\(str.length)")

            // Collect line start positions (iterate backwards to preserve offsets)
            var lineStarts: [Int] = []
            var pos = fullLineRange.location
            while pos < NSMaxRange(fullLineRange) {
                lineStarts.append(pos)
                let lr = str.lineRange(for: NSRange(location: pos, length: 0))
                pos = NSMaxRange(lr)
            }
            dbg("insertAtLineStart: lineStarts=\(lineStarts)")

            let skipEmpty = lineStarts.count > 1 // Only skip empty lines in multi-line selections

            storage.beginEditing()
            for start in lineStarts.reversed() {
                let currentStr = storage.string as NSString
                let lr = currentStr.lineRange(for: NSRange(location: min(start, max(0, currentStr.length - 1)), length: 0))
                let lineStr = lr.length > 0 ? currentStr.substring(with: lr) : ""
                let trimmed = lineStr.trimmingCharacters(in: .whitespacesAndNewlines)
                if skipEmpty && trimmed.isEmpty { continue }
                if lineStr.hasPrefix(prefix) {
                    // Toggle off
                    storage.replaceCharacters(in: NSRange(location: lr.location, length: prefix.count), with: "")
                } else {
                    // Remove other list prefixes first
                    let otherPrefixes = ["• ", "☐ ", "☑ "].filter { $0 != prefix }
                    var insertAt = lr.location
                    for other in otherPrefixes {
                        let curStr = storage.string as NSString
                        let curLr = curStr.lineRange(for: NSRange(location: min(insertAt, max(0, curStr.length - 1)), length: 0))
                        let curLine = curLr.length > 0 ? curStr.substring(with: curLr) : ""
                        if curLine.hasPrefix(other) {
                            storage.replaceCharacters(in: NSRange(location: curLr.location, length: other.count), with: "")
                            break
                        }
                    }
                    let curStr2 = storage.string as NSString
                    let curLr2 = curStr2.lineRange(for: NSRange(location: min(insertAt, max(0, curStr2.length - 1)), length: 0))
                    let attrPrefix = NSAttributedString(string: prefix, attributes: [
                        .font: bodyFont,
                        .foregroundColor: textColor
                    ])
                    storage.insert(attrPrefix, at: curLr2.location)
                }
            }
            storage.endEditing()
        }

        private func toggleChecklist(textView: NSTextView, storage: NSTextStorage, range: NSRange) {
            let str = storage.string as NSString

            // Caret at beginning of a list line → insert new checklist line above, push current line down
            // (skip when invoked from slash menu — user wants prefix on current line)
            if !fromSlashMenu && range.length == 0 && str.length > 0 && range.location < str.length {
                let lineRange = str.lineRange(for: NSRange(location: range.location, length: 0))
                let lineStr = str.substring(with: lineRange)
                let isAtLineStart = range.location == lineRange.location
                let hasListPrefix = lineStr.hasPrefix("• ") || lineStr.hasPrefix("☐ ") || lineStr.hasPrefix("☑ ")
                if isAtLineStart && hasListPrefix {
                    let newLine = NSMutableAttributedString()
                    var newBoxAttrs = Tokens.Typography.checkboxAttributes(checked: false)
                    newBoxAttrs[.foregroundColor] = textColor
                    newLine.append(NSAttributedString(string: "☐", attributes: newBoxAttrs))
                    newLine.append(NSAttributedString(string: " \n", attributes: [.font: bodyFont, .foregroundColor: textColor]))
                    storage.insert(newLine, at: lineRange.location)
                    textView.setSelectedRange(NSRange(location: lineRange.location + 2, length: 0))
                    textView.didChangeText()
                    return
                }
            }

            // Handle cursor at end of text or empty document
            let adjustedRange: NSRange
            if str.length == 0 || (fromSlashMenu && range.location == str.length && range.length == 0) {
                // Insert prefix at current position
                let insertPos = min(range.location, str.length)
                let attrPrefix = NSMutableAttributedString()
                var emptyBoxAttrs = Tokens.Typography.checkboxAttributes(checked: false)
                emptyBoxAttrs[.foregroundColor] = textColor
                attrPrefix.append(NSAttributedString(string: "☐", attributes: emptyBoxAttrs))
                attrPrefix.append(NSAttributedString(string: " ", attributes: [.font: bodyFont, .foregroundColor: textColor]))
                storage.insert(attrPrefix, at: insertPos)
                textView.setSelectedRange(NSRange(location: insertPos + 2, length: 0))
                textView.didChangeText()
                return
            } else if range.location == str.length && range.length == 0 {
                adjustedRange = NSRange(location: max(0, range.location - 1), length: 0)
            } else {
                adjustedRange = range
            }

            let fullLineRange = str.lineRange(for: adjustedRange)

            // Collect line start positions
            var lineStarts: [Int] = []
            var pos = fullLineRange.location
            while pos < NSMaxRange(fullLineRange) {
                lineStarts.append(pos)
                let lr = str.lineRange(for: NSRange(location: pos, length: 0))
                pos = NSMaxRange(lr)
            }

            let skipEmpty = lineStarts.count > 1

            storage.beginEditing()
            for start in lineStarts.reversed() {
                let currentStr = storage.string as NSString
                let lineRange = currentStr.lineRange(for: NSRange(location: min(start, max(0, currentStr.length - 1)), length: 0))
                let lineStr = lineRange.length > 0 ? currentStr.substring(with: lineRange) : ""
                let trimmed = lineStr.trimmingCharacters(in: .whitespacesAndNewlines)
                if skipEmpty && trimmed.isEmpty { continue }

                if lineStr.hasPrefix("☐ ") || lineStr.hasPrefix("☑ ") {
                    // Remove checkbox prefix
                    storage.replaceCharacters(in: NSRange(location: lineRange.location, length: 2), with: "")
                    let newStr = storage.string as NSString
                    let newLineRange = newStr.lineRange(for: NSRange(location: min(lineRange.location, newStr.length - 1), length: 0))
                    if newLineRange.length > 0 {
                        storage.removeAttribute(.strikethroughStyle, range: newLineRange)
                        storage.addAttribute(.foregroundColor, value: textColor, range: newLineRange)
                    }
                } else {
                    // Remove bullet prefix first if present
                    var insertAt = lineRange.location
                    if lineStr.hasPrefix("• ") {
                        storage.replaceCharacters(in: NSRange(location: lineRange.location, length: 2), with: "")
                    }
                    let curStr = storage.string as NSString
                    let curLr = curStr.lineRange(for: NSRange(location: min(insertAt, max(0, curStr.length - 1)), length: 0))
                    var boxAttrs = Tokens.Typography.checkboxAttributes(checked: false)
                    boxAttrs[.foregroundColor] = textColor
                    let box = NSAttributedString(string: "☐", attributes: boxAttrs)
                    let spaceAfter = NSAttributedString(string: " ", attributes: [
                        .font: bodyFont,
                        .foregroundColor: textColor
                    ])
                    let attrPrefix = NSMutableAttributedString()
                    attrPrefix.append(box)
                    attrPrefix.append(spaceAfter)
                    storage.insert(attrPrefix, at: curLr.location)
                }
            }
            storage.endEditing()
        }

        // Handle bold/italic keyboard shortcuts
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return handleNewline(textView: textView)
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                return handleTab(textView: textView)
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                return handleBacktab(textView: textView)
            }
            return false
        }

        private func handleNewline(textView: NSTextView) -> Bool {
            guard let storage = textView.textStorage else { return false }
            let range = textView.selectedRange()
            let str = storage.string as NSString
            let lineRange = str.lineRange(for: NSRange(location: range.location, length: 0))
            let lineStr = str.substring(with: lineRange)

            // Reset heading to body font on Enter
            if range.location > 0 {
                let charBefore = max(0, range.location - 1)
                if let font = storage.attribute(.font, at: charBefore, effectiveRange: nil) as? NSFont {
                    let size = font.pointSize
                    if size == h1Font.pointSize || size == h2Font.pointSize || size == h3Font.pointSize {
                        recordUndo(for: textView)
                        // Insert newline with body font, don't let heading continue
                        let newline = NSAttributedString(string: "\n", attributes: [
                            .font: bodyFont,
                            .foregroundColor: textColor
                        ])
                        storage.replaceCharacters(in: range, with: newline)
                        textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                        textView.typingAttributes[.font] = bodyFont
                        textView.typingAttributes[.foregroundColor] = textColor
                        textView.didChangeText()
                        return true
                    }
                }
            }

            // List continuation: detect leading whitespace + prefix (supports indented lists)
            let leadingSpaces = String(lineStr.prefix(while: { $0 == " " }))
            let afterIndent = String(lineStr.dropFirst(leadingSpaces.count))

            var detectedPrefix: String? = nil
            for pfx in ["☐ ", "☑ ", "• "] {
                if afterIndent.hasPrefix(pfx) {
                    detectedPrefix = pfx
                    break
                }
            }

            if let prefix = detectedPrefix {
                let fullPrefix = leadingSpaces + prefix

                // If cursor is before the content (inside or before prefix), plain newline
                if range.location < lineRange.location + fullPrefix.count {
                    return false  // let NSTextView handle the newline normally
                }

                recordUndo(for: textView)
                let contentAfterPrefix = String(lineStr.dropFirst(fullPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)

                if contentAfterPrefix.isEmpty {
                    // Empty list item — remove indent + prefix to end the list
                    storage.replaceCharacters(in: NSRange(location: lineRange.location, length: fullPrefix.count), with: "")
                    textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
                    textView.didChangeText()
                    return true
                }

                // Caret at the very start of the item's text → push this item (keeping
                // its own ☑/☐ state + text) DOWN and insert a fresh EMPTY, always-unchecked
                // item above. Without this the original prefix stays on the empty top line
                // (so a ☑ item leaves a checked empty box and un-checks the text below).
                let atContentStart = (range.length == 0 && range.location == lineRange.location + fullPrefix.count)
                if atContentStart {
                    let isCheckbox = (prefix == "☐ " || prefix == "☑ ")
                    let aboveLine = NSMutableAttributedString(string: leadingSpaces, attributes: [
                        .font: bodyFont, .foregroundColor: textColor
                    ])
                    if isCheckbox {
                        // New checkbox items are always unchecked.
                        var aboveBoxAttrs = Tokens.Typography.checkboxAttributes(checked: false)
                        aboveBoxAttrs[.foregroundColor] = textColor
                        aboveLine.append(NSAttributedString(string: "☐", attributes: aboveBoxAttrs))
                        aboveLine.append(NSAttributedString(string: " ", attributes: [
                            .font: bodyFont, .foregroundColor: textColor
                        ]))
                    } else {
                        aboveLine.append(NSAttributedString(string: prefix, attributes: [
                            .font: bodyFont, .foregroundColor: textColor
                        ]))
                    }
                    aboveLine.append(NSAttributedString(string: "\n", attributes: [
                        .font: bodyFont, .foregroundColor: textColor
                    ]))
                    storage.insert(aboveLine, at: lineRange.location)
                    // Keep the caret with the moved text (now one line down).
                    let newCaret = lineRange.location + aboveLine.length + fullPrefix.count
                    textView.setSelectedRange(NSRange(location: newCaret, length: 0))
                    textView.didChangeText()
                    return true
                }

                // Continue with same indent + prefix (☑ continues as ☐)
                let continuationPrefix = (prefix == "☑ ") ? "☐ " : prefix
                let head = "\n" + leadingSpaces  // newline + any indent
                let insertion = NSMutableAttributedString(string: head, attributes: [
                    .font: bodyFont,
                    .foregroundColor: textColor
                ])
                // If the prefix is a checkbox, use the rounded SF glyph for the box itself.
                if continuationPrefix == "☐ " || continuationPrefix == "☑ " {
                    let boxChar = String(continuationPrefix.first!)
                    var contBoxAttrs = Tokens.Typography.checkboxAttributes(checked: boxChar == "☑")
                    contBoxAttrs[.foregroundColor] = textColor
                    insertion.append(NSAttributedString(string: boxChar, attributes: contBoxAttrs))
                    insertion.append(NSAttributedString(string: " ", attributes: [
                        .font: bodyFont, .foregroundColor: textColor
                    ]))
                } else {
                    insertion.append(NSAttributedString(string: continuationPrefix, attributes: [
                        .font: bodyFont, .foregroundColor: textColor
                    ]))
                }
                storage.replaceCharacters(in: range, with: insertion)
                let newCaret = range.location + head.count + continuationPrefix.count
                textView.setSelectedRange(NSRange(location: newCaret, length: 0))
                textView.didChangeText()
                return true
            }

            return false
        }

        private func handleTab(textView: NSTextView) -> Bool {
            guard let storage = textView.textStorage else { return false }
            recordUndo(for: textView)
            let range = textView.selectedRange()
            let str = storage.string as NSString
            let fullLineRange = str.lineRange(for: range)
            let indent = "    "

            // Collect all line starts in selection
            var lineStarts: [Int] = []
            var pos = fullLineRange.location
            while pos < NSMaxRange(fullLineRange) {
                lineStarts.append(pos)
                let lr = str.lineRange(for: NSRange(location: pos, length: 0))
                pos = NSMaxRange(lr)
            }

            // If multiple lines or cursor is on a bullet/checklist line, indent lines.
            // Check after any existing leading whitespace so already-indented items still count.
            let firstLineStr = str.substring(with: str.lineRange(for: NSRange(location: fullLineRange.location, length: 0)))
            let firstTrimmed = firstLineStr.drop(while: { $0 == " " || $0 == "\u{00a0}" })
            let hasList = firstTrimmed.hasPrefix("• ") || firstTrimmed.hasPrefix("☐ ") || firstTrimmed.hasPrefix("☑ ")

            if lineStarts.count > 1 || hasList {
                storage.beginEditing()
                for start in lineStarts.reversed() {
                    let attrIndent = NSAttributedString(string: indent, attributes: [
                        .font: bodyFont,
                        .foregroundColor: textColor
                    ])
                    storage.insert(attrIndent, at: start)
                }
                storage.endEditing()
                textView.didChangeText()
                return true
            }

            // Plain text: just insert spaces at cursor
            textView.insertText(indent, replacementRange: range)
            return true
        }

        private func handleBacktab(textView: NSTextView) -> Bool {
            guard let storage = textView.textStorage else { return false }
            recordUndo(for: textView)
            let range = textView.selectedRange()
            let str = storage.string as NSString
            let fullLineRange = str.lineRange(for: range)
            let indent = "    "

            // Collect all line starts in selection
            var lineStarts: [Int] = []
            var pos = fullLineRange.location
            while pos < NSMaxRange(fullLineRange) {
                lineStarts.append(pos)
                let lr = str.lineRange(for: NSRange(location: pos, length: 0))
                pos = NSMaxRange(lr)
            }

            storage.beginEditing()
            var removed = 0
            for start in lineStarts.reversed() {
                let lineRange = str.lineRange(for: NSRange(location: start, length: 0))
                let lineStr = str.substring(with: lineRange)
                if lineStr.hasPrefix(indent) {
                    storage.deleteCharacters(in: NSRange(location: start, length: indent.count))
                    removed += indent.count
                } else {
                    // Remove as many leading spaces as possible (up to 4)
                    var count = 0
                    for ch in lineStr {
                        if ch == " " && count < 4 { count += 1 } else { break }
                    }
                    if count > 0 {
                        storage.deleteCharacters(in: NSRange(location: start, length: count))
                        removed += count
                    }
                }
            }
            storage.endEditing()

            if removed > 0 {
                textView.didChangeText()
            }
            return true
        }

    }
}
