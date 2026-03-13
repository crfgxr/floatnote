import SwiftUI
import AppKit

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

let BUCKET_GUID = "bf100d62-31b3-ac11-298c-6a90ae689031"
let NOTE_TITLE = "editor"
let LOCAL_SAVE_PATH = NSHomeDirectory() + "/.evernote-editor-local.html"
let LOCAL_TABS_PATH = NSHomeDirectory() + "/.evernote-editor-tabs.json"

@main
struct FloatNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var vm = EditorViewModel()

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
                Button("Save Now") { Task { await vm.saveNow() } }
                    .keyboardShortcut("s")
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var vm: EditorViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        dbg("APP LAUNCHED")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vm else { return .terminateNow }

        // Synchronously save local
        vm.saveLocalSync()

        // Try to sync to Evernote before quitting
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await vm.syncToEvernote()
            semaphore.signal()
        }
        // Wait up to 5 seconds for Evernote sync
        let result = semaphore.wait(timeout: .now() + 5)
        if result == .timedOut {
            // Local save is already done, Evernote sync timed out but data is safe
            NSLog("Evernote sync timed out on exit, local save is intact")
        }
        return .terminateNow
    }
}

// MARK: - Window Accessor

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.minSize = NSSize(width: 50, height: 50)
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Format Actions

enum FormatAction: Equatable {
    case bold, italic, underline, code, heading1, heading2, heading3, bulletList, checklist, link, divider, body
}

// MARK: - Tab Model

struct TabData: Codable {
    var id: String
    var title: String
    var noteGuid: String?
    var html: String
}

class NoteTab: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    var noteGuid: String?
    var html: String = ""
    var lastSavedHTML: String = ""

    init(id: UUID = UUID(), title: String, noteGuid: String? = nil) {
        self.id = id
        self.title = title
        self.noteGuid = noteGuid
    }

    func toData() -> TabData {
        TabData(id: id.uuidString, title: title, noteGuid: noteGuid, html: html)
    }

    static func from(_ data: TabData) -> NoteTab {
        let tab = NoteTab(id: UUID(uuidString: data.id) ?? UUID(), title: data.title, noteGuid: data.noteGuid)
        tab.html = data.html
        return tab
    }
}

// MARK: - ViewModel

@MainActor
class EditorViewModel: ObservableObject {
    @Published var status: String = "Loading..."
    @Published var isSaving = false
    @Published var charCount: Int = 0
    @Published var isPinned: Bool = false
    @Published var isDictating: Bool = false
    @Published var tabs: [NoteTab] = []
    @Published var activeTabId: UUID?
    @Published var editingTabId: UUID?
    @Published var draggingTabId: UUID?

    var activeTab: NoteTab? { tabs.first { $0.id == activeTabId } }
    var attributedText = NSMutableAttributedString()
    var onContentLoaded: ((NSAttributedString) -> Void)?
    weak var editorCoordinator: RichTextEditor.Coordinator?
    var isLoadingContent = false

    private var api: EvernoteAPI?
    private var noteGuid: String?
    private var saveTask: Task<Void, Never>?
    private var lastSavedHTML: String = ""
    private var currentHTML: String = ""

    init() {
        loadToken()
        Task { await loadOrCreateNote() }
    }

    static nonisolated let authPath = "/Users/cagdas/CodTemp/myevernote-macos-app/.auth.json"

    private func loadToken() {
        // Try to refresh if expired
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFmtNoFrac = ISO8601DateFormatter()
        isoFmtNoFrac.formatOptions = [.withInternetDateTime]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: Self.authPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let expiresAt = json["expiresAt"] as? String,
           let expDate = isoFmt.date(from: expiresAt) ?? isoFmtNoFrac.date(from: expiresAt),
           expDate < Date(),
           let refreshToken = json["refreshToken"] as? String {
            refreshAuthToken(refreshToken)
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.authPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["monoToken"] as? String,
              let shard = json["shard"] as? String else {
            status = "No auth token. Run: node login.js"
            return
        }
        api = EvernoteAPI(token: token, shard: shard)
    }

    private func refreshAuthToken(_ refreshToken: String) {
        let url = URL(string: "https://accounts.evernote.com/auth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "refresh_token=\(refreshToken)&client_id=evernote-web-client&grant_type=refresh_token&redirect_uri=https://www.evernote.com/client/web"
        request.httpBody = body.data(using: .utf8)

        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data,
                  let resp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = resp["access_token"] as? String else { return }

            // Decode JWT payload
            let parts = accessToken.split(separator: ".")
            guard parts.count >= 2,
                  let payloadData = Data(base64Encoded: String(parts[1])
                      .replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
                      .padding(toLength: ((String(parts[1]).count + 3) / 4) * 4, withPad: "=", startingAt: 0)),
                  let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                  let monoToken = payload["mono_authn_token"] as? String,
                  let exp = payload["exp"] as? Double else { return }

            let shardMatch = monoToken.range(of: #"S=(s\d+)"#, options: .regularExpression)
            let shard = shardMatch.flatMap { String(monoToken[$0]).components(separatedBy: "=").last } ?? "s24"

            var newAuth: [String: Any] = [
                "accessToken": accessToken,
                "refreshToken": (resp["refresh_token"] as? String) ?? refreshToken,
                "monoToken": monoToken,
                "expiresAt": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: exp)),
                "savedAt": ISO8601DateFormatter().string(from: Date()),
                "shard": shard
            ]
            if let userId = payload["evernote_user_id"] { newAuth["userId"] = userId }
            if let clientId = payload["client_id"] { newAuth["clientId"] = clientId }

            if let jsonData = try? JSONSerialization.data(withJSONObject: newAuth, options: .prettyPrinted) {
                try? jsonData.write(to: URL(fileURLWithPath: Self.authPath))
                NSLog("Token auto-refreshed, expires: %@", newAuth["expiresAt"] as? String ?? "?")
            }
        }.resume()
        _ = semaphore.wait(timeout: .now() + 10)
    }

    func loadOrCreateNote() async {
        // Load tabs from local JSON
        loadTabsLocal()

        if tabs.isEmpty {
            // Migrate from old single-file format
            let tab = NoteTab(title: "Untitled")
            if let localHTML = loadLocal(), !localHTML.isEmpty {
                tab.html = localHTML
            }
            tabs = [tab]
            saveTabsLocal()
        }

        // Activate first tab
        let firstTab = tabs[0]
        activeTabId = firstTab.id
        currentHTML = firstTab.html
        lastSavedHTML = firstTab.lastSavedHTML

        if !firstTab.html.isEmpty, let attrStr = htmlToAttributedString(firstTab.html) {
            attributedText = NSMutableAttributedString(attributedString: attrStr)
            charCount = attributedText.length
            onContentLoaded?(attributedText)
            status = "Loaded (local)"
        }

        // Try to sync active tab with Evernote
        guard let api else {
            if currentHTML.isEmpty { status = "Ready" }
            return
        }

        status = "Syncing..."
        do {
            // Find or create an Evernote note for this tab
            if firstTab.noteGuid == nil {
                let result = try await api.listNotes(notebookGuid: BUCKET_GUID, maxNotes: 100)
                if let existing = result.notes.first(where: { $0.title == firstTab.title }) {
                    firstTab.noteGuid = existing.guid
                } else {
                    let guid = try await api.createNote(title: firstTab.title, body: "<p></p>", notebookGuid: BUCKET_GUID)
                    firstTab.noteGuid = guid
                }
                noteGuid = firstTab.noteGuid
                saveTabsLocal()
            } else {
                noteGuid = firstTab.noteGuid
            }

            // If tab has content, push to Evernote; otherwise pull from Evernote
            if !currentHTML.isEmpty {
                await save(html: currentHTML)
            } else if let guid = firstTab.noteGuid {
                let note = try await api.getNote(guid: guid)
                let remoteHTML = enmlToHTML(note.content)
                firstTab.html = remoteHTML
                firstTab.lastSavedHTML = remoteHTML
                currentHTML = remoteHTML
                lastSavedHTML = remoteHTML
                if let attrStr = htmlToAttributedString(remoteHTML) {
                    attributedText = NSMutableAttributedString(attributedString: attrStr)
                    charCount = attributedText.length
                    onContentLoaded?(attributedText)
                }
                saveTabsLocal()
            }
            status = "Loaded"
        } catch {
            status = currentHTML.isEmpty ? "Error: \(error.localizedDescription)" : "Loaded (local)"
        }
    }

    private func loadTabsLocal() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: LOCAL_TABS_PATH)),
              let tabsData = try? JSONDecoder().decode([TabData].self, from: data) else { return }
        tabs = tabsData.map { NoteTab.from($0) }
    }

    func saveTabsLocal() {
        let data = tabs.map { $0.toData() }
        if let json = try? JSONEncoder().encode(data) {
            try? json.write(to: URL(fileURLWithPath: LOCAL_TABS_PATH))
        }
    }

    // MARK: - Tab Management

    func switchTab(_ id: UUID) {
        guard id != activeTabId, let newTab = tabs.first(where: { $0.id == id }) else { return }

        // Commit any active rename
        if let editId = editingTabId {
            if let tab = tabs.first(where: { $0.id == editId }) {
                renameTab(editId, title: tab.title)
            }
            editingTabId = nil
        }

        // Save current tab's state
        if let current = activeTab {
            current.html = currentHTML
            current.lastSavedHTML = lastSavedHTML
        }
        saveTabsLocal()

        activeTabId = id
        noteGuid = newTab.noteGuid
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
        // Reset flag after async onContentLoaded completes
        DispatchQueue.main.async { self.isLoadingContent = false }
        status = "Loaded"
    }

    func addTab() {
        // Save current tab
        if let current = activeTab {
            current.html = currentHTML
            current.lastSavedHTML = lastSavedHTML
        }

        let tab = NoteTab(title: "Untitled")
        tabs.append(tab)
        activeTabId = tab.id
        noteGuid = nil
        currentHTML = ""
        lastSavedHTML = ""
        charCount = 0
        onContentLoaded?(NSAttributedString(string: ""))
        saveTabsLocal()
        status = "New note"

        // Create note on Evernote
        if let api {
            Task {
                do {
                    let guid = try await api.createNote(title: tab.title, body: "<p></p>", notebookGuid: BUCKET_GUID)
                    tab.noteGuid = guid
                    noteGuid = guid
                    saveTabsLocal()
                    status = "Created"
                } catch {
                    NSLog("Failed to create Evernote note: %@", "\(error)")
                    status = "Local only"
                }
            }
        }
    }

    func deleteTab(_ id: UUID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]

        // Delete from Evernote
        if let guid = tab.noteGuid, let api {
            Task {
                _ = try? await api.deleteNote(guid: guid)
            }
        }

        // Switch away if deleting the active tab
        if activeTabId == id {
            let newIndex = index > 0 ? index - 1 : 1
            let nextTab = tabs[newIndex]
            tabs.remove(at: index)
            switchTab(nextTab.id)
        } else {
            tabs.remove(at: index)
        }
        saveTabsLocal()
    }

    func renameTab(_ id: UUID, title: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.title = title
        editingTabId = nil
        saveTabsLocal()

        // Sync title to Evernote
        if let guid = tab.noteGuid, let api {
            Task {
                let enml = htmlToEnml(tab.html.isEmpty ? "<p></p>" : tab.html)
                _ = try? await api.updateNote(guid: guid, title: title, content: enml)
            }
        }
    }

    func moveTab(from sourceId: UUID, to destId: UUID) {
        guard sourceId != destId,
              let fromIdx = tabs.firstIndex(where: { $0.id == sourceId }),
              let toIdx = tabs.firstIndex(where: { $0.id == destId }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            tabs.move(fromOffsets: IndexSet(integer: fromIdx), toOffset: toIdx > fromIdx ? toIdx + 1 : toIdx)
        }
        saveTabsLocal()
    }

    func textDidChange(html: String, length: Int) {
        guard !isLoadingContent else { return }
        charCount = length
        currentHTML = html
        activeTab?.html = html
        // Always save locally immediately
        saveLocal(html: html)
        saveTabsLocal()
        guard html != lastSavedHTML else { return }
        status = "Editing..."
        // Debounce Evernote sync
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await save(html: html)
        }
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
        if let window = NSApp.windows.first(where: { $0.isKeyWindow }) ?? NSApp.windows.first {
            window.level = isPinned ? .floating : .normal
        }
    }

    func saveNow() async {
        saveTask?.cancel()
        saveLocal(html: currentHTML)
        await save(html: currentHTML)
    }

    // Save to local file (fast, always works)
    private func saveLocal(html: String) {
        try? html.write(toFile: LOCAL_SAVE_PATH, atomically: true, encoding: .utf8)
    }

    // Synchronous version for app exit
    func saveLocalSync() {
        activeTab?.html = currentHTML
        try? currentHTML.write(toFile: LOCAL_SAVE_PATH, atomically: true, encoding: .utf8)
        saveTabsLocal()
    }

    // Load from local file
    private func loadLocal() -> String? {
        try? String(contentsOfFile: LOCAL_SAVE_PATH, encoding: .utf8)
    }

    // Sync current content to Evernote (used on exit)
    func syncToEvernote() async {
        guard currentHTML != lastSavedHTML else { return }
        await save(html: currentHTML)
    }

    func save(html: String) async {
        guard let api, let guid = noteGuid else {
            saveLocal(html: html)
            status = "Saved (local only)"
            return
        }
        guard html != lastSavedHTML else { status = "Saved"; return }

        isSaving = true
        status = "Syncing..."

        let enml = htmlToEnml(html)
        do {
            _ = try await api.updateNote(guid: guid, title: activeTab?.title ?? NOTE_TITLE, content: enml)
            lastSavedHTML = html
            status = "Saved"
        } catch {
            saveLocal(html: html)
            let errMsg = "\(error)"
            NSLog("Sync error: %@", errMsg)
            if errMsg.contains("RTE room") || errMsg.contains("already been open") {
                status = "Close note in Evernote first"
            } else {
                status = "Sync failed: \(error.localizedDescription)"
            }
        }
        isSaving = false
    }

    private func enmlToHTML(_ enml: String) -> String {
        var text = enml
        text = text.replacingOccurrences(of: #"<\?xml[^?]*\?>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<!DOCTYPE[^>]*>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<en-note>", with: "")
        text = text.replacingOccurrences(of: "</en-note>", with: "")
        text = text.replacingOccurrences(of: #"<en-note[^>]*>"#, with: "", options: .regularExpression)
        // Convert en-todo tags to checkbox characters
        text = text.replacingOccurrences(of: #"<en-todo\b[^>]*checked="true"[^>]*/?>"#, with: "☑ ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<en-todo\b[^>]*/?>"#, with: "☐ ", options: .regularExpression)
        text = text.replacingOccurrences(of: "</en-todo>", with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func htmlToEnml(_ html: String) -> String {
        var clean = html
        // Extract body content only (NSTextView exports full HTML documents)
        if let bodyStart = clean.range(of: #"<body[^>]*>"#, options: .regularExpression),
           let bodyEnd = clean.range(of: "</body>", options: .caseInsensitive) {
            clean = String(clean[bodyStart.upperBound..<bodyEnd.lowerBound])
        }
        // Convert checkbox characters to en-todo tags
        clean = clean.replacingOccurrences(of: "☑", with: "<en-todo checked=\"true\"/>")
        clean = clean.replacingOccurrences(of: "☐", with: "<en-todo/>")
        // Clean ENML-incompatible attributes (keep spans/fonts/styles for formatting)
        clean = clean.replacingOccurrences(of: #" class=\"[^\"]*\""#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #" dir=\"[^\"]*\""#, with: "", options: .regularExpression)
        // Remove webkit-specific and unsupported CSS properties from style attrs
        clean = clean.replacingOccurrences(of: #"-webkit-[^;\"]*;?\s*"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"font-variant-ligatures:[^;\"]*;?\s*"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"font-kerning:[^;\"]*;?\s*"#, with: "", options: .regularExpression)
        // Remove empty style attributes left after cleanup
        clean = clean.replacingOccurrences(of: #" style=\"\s*\""#, with: "", options: .regularExpression)
        // Self-close void elements for XHTML/ENML compliance
        clean = clean.replacingOccurrences(of: #"<br\s*>"#, with: "<br/>", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"<hr\s*>"#, with: "<hr/>", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"<img([^>]*[^/])>"#, with: "<img$1/>", options: .regularExpression)
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE en-note SYSTEM \"http://xml.evernote.com/pub/enml2.dtd\"><en-note>\(clean)</en-note>"
    }

    func htmlToAttributedString(_ html: String) -> NSAttributedString? {
        let styledHTML = """
        <html dir="ltr"><head><style>
        body { font-family: 'Times New Roman', serif; font-size: 16px; color: #e0e0e0; direction: ltr; text-align: left; }
        h1 { font-size: 28px; font-weight: 700; }
        h2 { font-size: 22px; font-weight: 600; }
        h3 { font-size: 18px; font-weight: 600; }
        code { font-family: Menlo; font-size: 13px; background: #2a2a2a; padding: 2px 4px; border-radius: 3px; }
        a { color: #6cb6ff; }
        </style></head><body dir="ltr">\(html)</body></html>
        """
        guard let data = styledHTML.data(using: .utf8),
              let attrStr = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              ) else { return nil }

        // Post-process: mark code spans with .codeBlock attribute and paragraph styling
        let mutable = NSMutableAttributedString(attributedString: attrStr)
        let fullStr = mutable.string as NSString
        mutable.enumerateAttribute(.font, in: NSRange(location: 0, length: mutable.length), options: []) { value, range, _ in
            if let font = value as? NSFont, font.fontName.lowercased().contains("menlo") {
                let paraRange = fullStr.paragraphRange(for: range)
                mutable.addAttribute(.codeBlock, value: true, range: paraRange)
                mutable.removeAttribute(.backgroundColor, range: paraRange)
                let ps = NSMutableParagraphStyle()
                ps.baseWritingDirection = .leftToRight
                ps.alignment = .left
                ps.headIndent = 12
                ps.firstLineHeadIndent = 12
                ps.tailIndent = -12
                mutable.addAttribute(.paragraphStyle, value: ps, range: paraRange)
                mutable.addAttribute(.foregroundColor, value: NSColor(calibratedWhite: 0.78, alpha: 1.0), range: paraRange)
            }
        }
        return mutable
    }
}

// MARK: - Editor View

struct EditorView: View {
    @EnvironmentObject var vm: EditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            FormatToolbar()
            Divider()
            TabBar()
            Divider()
            RichTextEditor()
                .environmentObject(vm)
            Divider()
            StatusBar()
        }
        .frame(minWidth: 0, minHeight: 0)
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
struct NativeHScrollView<Content: View>: NSViewRepresentable {
    let scrollState: TabScrollState
    let onScroll: (CGFloat, CGFloat, CGFloat) -> Void // (offset, contentWidth, containerWidth)
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
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
        HStack(spacing: 0) {
            if overflows {
                Button(action: { scrollState.scroll(by: -100) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 26)
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
                    ForEach(vm.tabs) { tab in
                        TabItemView(tab: tab)
                            .id(tab.id)
                    }
                    Button(action: { vm.addTab() }) {
                        Image(systemName: "plus")
                            .font(.system(size: 11))
                            .frame(width: 24, height: 26)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            }
            .frame(height: 30)

            if overflows {
                Button(action: { scrollState.scroll(by: 100) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundColor(clippedRight ? .secondary : .secondary.opacity(0.2))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.bar)
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
                TextField("", text: $tab.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(minWidth: 40, maxWidth: 140)
                    .focused($isFieldFocused)
                    .onSubmit {
                        vm.renameTab(tab.id, title: tab.title)
                    }
                    .onAppear { isFieldFocused = true }
            } else {
                Text(tab.title)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
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
            vm.editingTabId = tab.id
        }
        .onTapGesture(count: 1) {
            if vm.editingTabId != tab.id {
                vm.switchTab(tab.id)
            }
        }
        .onDrag {
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
        vm.draggingTabId = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragId = vm.draggingTabId, dragId != tab.id else { return }
        vm.moveTab(from: dragId, to: tab.id)
    }

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
            if vm.tabs.count > 1 {
                Button(action: { vm.deleteTab(vm.activeTabId!) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete this notepad")
            }
            Button(action: { Task { await vm.saveNow() } }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Sync")
                }
                .font(.system(size: 10))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help("Sync to Evernote now")
            Text("\(vm.charCount) chars")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
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

// MARK: - Format Toolbar

struct FormatToolbar: View {
    @EnvironmentObject var vm: EditorViewModel

    var body: some View {
        FlowLayout(spacing: 4) {
            toolBtn("H1") { vm.performFormat(.heading1) }
            toolBtn("H2") { vm.performFormat(.heading2) }
            toolBtn("H3") { vm.performFormat(.heading3) }
            toolBtn("Body") { vm.performFormat(.body) }
            iconBtn("bold") { vm.performFormat(.bold) }
            iconBtn("italic") { vm.performFormat(.italic) }
            iconBtn("underline") { vm.performFormat(.underline) }
            iconBtn("chevron.left.forwardslash.chevron.right") { vm.performFormat(.code) }
            iconBtn("list.bullet") { vm.performFormat(.bulletList) }
            iconBtn("checklist") { vm.performFormat(.checklist) }
            iconBtn("link") { vm.performFormat(.link) }
            iconBtn("minus") { vm.performFormat(.divider) }
            Button(action: { vm.togglePin() }) {
                Image(systemName: vm.isPinned ? "pin.fill" : "pin")
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(vm.isPinned ? "Unpin from top" : "Pin to top")
            Button(action: { toggleDictation() }) {
                Image(systemName: vm.isDictating ? "mic.fill" : "mic")
                    .foregroundColor(vm.isDictating ? .red : .primary)
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.bordered)
            .tint(vm.isDictating ? .red : nil)
            .controlSize(.small)
            .help(vm.isDictating ? "Stop Dictation" : "Start Dictation")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    func toolBtn(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .frame(minWidth: 28, minHeight: 24)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    func toggleDictation() {
        vm.isDictating.toggle()
        if vm.isDictating {
            let sel = NSSelectorFromString("startDictation:")
            NSApp.sendAction(sel, to: nil, from: nil)
            // Watch for dictation ending (system can stop it)
            NotificationCenter.default.addObserver(forName: NSNotification.Name("NSTextInputContextDictationDidEnd"), object: nil, queue: .main) { [weak vm] _ in
                vm?.isDictating = false
            }
        } else {
            // Send Escape to stop dictation
            let src = CGEventSource(stateID: .hidSystemState)
            if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true),
               let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false) {
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
            }
        }
    }

    func iconBtn(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

// MARK: - Code Block Layout Manager

extension NSAttributedString.Key {
    static let codeBlock = NSAttributedString.Key("FloatNoteCodeBlock")
}

class CodeBlockLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage = textStorage, let textContainer = textContainers.first else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }

        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let containerWidth = textContainer.containerSize.width
        var drawnRanges: [NSRange] = []

        // Find contiguous code block regions and merge them
        textStorage.enumerateAttribute(.codeBlock, in: charRange, options: []) { value, attrRange, _ in
            guard value != nil else { return }

            // Expand to full paragraph lines
            let str = textStorage.string as NSString
            let paraRange = str.paragraphRange(for: attrRange)
            let glyphRange = self.glyphRange(forCharacterRange: paraRange, actualCharacterRange: nil)

            // Skip if already drawn (merged ranges)
            if drawnRanges.contains(where: { NSIntersectionRange($0, paraRange).length > 0 }) { return }
            drawnRanges.append(paraRange)

            // Get bounding rect for all lines in this code block
            self.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in }
            var blockRect = self.boundingRect(forGlyphRange: glyphRange, in: textContainer)

            // Make full-width block
            let fullRect = NSRect(
                x: origin.x,
                y: blockRect.origin.y + origin.y - 6,
                width: containerWidth,
                height: blockRect.height + 12
            )

            // Draw rounded container
            let path = NSBezierPath(roundedRect: fullRect, xRadius: 6, yRadius: 6)
            NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1.0).setFill()
            path.fill()

            // Draw border
            NSColor(calibratedWhite: 0.30, alpha: 1.0).setStroke()
            path.lineWidth = 1.0
            path.stroke()
        }

        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

// MARK: - Block Caret NSTextView

class BlockCaretTextView: NSTextView {
    private let caretView: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        return v
    }()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        addSubview(caretView)
        DispatchQueue.main.async { self.updateCaretPosition() }
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // Hide system caret
    }

    override func didChangeText() {
        super.didChangeText()
        updateCaretPosition()
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
        updateCaretPosition()
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        updateCaretPosition()
    }

    override func mouseDown(with event: NSEvent) {
        // Check for checkbox click
        let point = convert(event.locationInWindow, from: nil)
        let adjustedPoint = NSPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )
        if let lm = layoutManager, let tc = textContainer, let ts = textStorage {
            var fraction: CGFloat = 0
            let charIndex = lm.characterIndex(for: adjustedPoint, in: tc, fractionOfDistanceBetweenInsertionPoints: &fraction)
            if charIndex < ts.length {
                let char = (ts.string as NSString).substring(with: NSRange(location: charIndex, length: 1))
                if char == "☐" || char == "☑" {
                    toggleCheckbox(at: charIndex)
                    updateCaretPosition()
                    return
                }
            }
        }
        super.mouseDown(with: event)
        updateCaretPosition()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        updateCaretPosition()
    }

    func toggleCheckbox(at charIndex: Int) {
        guard let storage = textStorage else { return }
        let str = storage.string as NSString
        let char = str.substring(with: NSRange(location: charIndex, length: 1))
        let lineRange = str.lineRange(for: NSRange(location: charIndex, length: 0))

        // Content range: after "☐ " or "☑ ", excluding trailing newline
        let contentStart = min(charIndex + 2, str.length)
        var lineEnd = lineRange.location + lineRange.length
        if lineEnd > contentStart && lineEnd > 0 && str.substring(with: NSRange(location: lineEnd - 1, length: 1)) == "\n" {
            lineEnd -= 1
        }
        let contentRange = NSRange(location: contentStart, length: max(0, lineEnd - contentStart))

        if char == "☐" {
            storage.replaceCharacters(in: NSRange(location: charIndex, length: 1), with: "☑")
            if contentRange.length > 0 {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: contentRange)
                storage.addAttribute(.foregroundColor, value: NSColor(calibratedWhite: 0.45, alpha: 1.0), range: contentRange)
            }
        } else if char == "☑" {
            storage.replaceCharacters(in: NSRange(location: charIndex, length: 1), with: "☐")
            if contentRange.length > 0 {
                storage.removeAttribute(.strikethroughStyle, range: contentRange)
                storage.addAttribute(.foregroundColor, value: NSColor(calibratedWhite: 0.88, alpha: 1.0), range: contentRange)
            }
        }
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

    func updateCaretPosition() {
        caretView.isHidden = selectedRange().length > 0

        // Use NSTextView's own insertion point rect — most reliable
        let charIndex = selectedRange().location
        var rectCount: Int = 0
        guard let rects = layoutManager?.rectArray(
            forCharacterRange: NSRange(location: charIndex, length: 0),
            withinSelectedCharacterRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer!,
            rectCount: &rectCount
        ), rectCount > 0 else {
            // Fallback for empty doc
            let baseFont = NSFont(name: "Times New Roman", size: 16) ?? NSFont.systemFont(ofSize: 16)
            let h = ceil(baseFont.ascender - baseFont.descender)
            moveCaretTo(NSRect(
                x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                y: textContainerInset.height,
                width: 2, height: h
            ))
            ensureCaretOnTop()
            return
        }

        let rect = rects[0]
        let baseFont = NSFont(name: "Times New Roman", size: 16) ?? NSFont.systemFont(ofSize: 16)
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

struct RichTextEditor: NSViewRepresentable {
    @EnvironmentObject var vm: EditorViewModel

    func makeCoordinator() -> Coordinator { Coordinator(vm: vm) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let contentSize = scrollView.contentSize
        let textContainer = NSTextContainer(containerSize: NSSize(width: contentSize.width, height: .greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true

        let layoutManager = CodeBlockLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textView = BlockCaretTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: textContainer)
        textView.autoresizingMask = [.width]
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 40, height: 24)
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
            return p
        }()

        let defaultFont = NSFont(name: "Times New Roman", size: 16) ?? NSFont.systemFont(ofSize: 16)
        let ltrParagraph = NSMutableParagraphStyle()
        ltrParagraph.baseWritingDirection = .leftToRight
        ltrParagraph.alignment = .left
        textView.typingAttributes = [
            .font: defaultFont,
            .foregroundColor: NSColor(calibratedWhite: 0.88, alpha: 1.0),
            .paragraphStyle: ltrParagraph
        ]

        scrollView.documentView = textView
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

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
                    fixed.addAttribute(.paragraphStyle, value: ltr, range: fullRange)
                    fixed.addAttribute(.foregroundColor, value: NSColor(calibratedWhite: 0.88, alpha: 1.0), range: fullRange)
                }
                textView.textStorage?.setAttributedString(fixed)
                // Apply checklist styling to checked items
                if let storage = textView.textStorage {
                    let str = storage.string as NSString
                    var pos = 0
                    while pos < str.length {
                        let lr = str.lineRange(for: NSRange(location: pos, length: 0))
                        let ls = str.substring(with: lr)
                        if ls.hasPrefix("☑ ") {
                            let cStart = lr.location + 2
                            var lEnd = lr.location + lr.length
                            if lEnd > cStart && str.substring(with: NSRange(location: lEnd - 1, length: 1)) == "\n" {
                                lEnd -= 1
                            }
                            let cRange = NSRange(location: cStart, length: max(0, lEnd - cStart))
                            if cRange.length > 0 {
                                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: cRange)
                                storage.addAttribute(.foregroundColor, value: NSColor(calibratedWhite: 0.45, alpha: 1.0), range: cRange)
                            }
                        }
                        let next = lr.location + lr.length
                        if next <= pos { break }
                        pos = next
                    }
                }
                // Move cursor to start
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.updateCaretPosition()
                // Reset typing attributes to defaults (prevents stale styles leaking between tabs)
                let defaultParagraph = NSMutableParagraphStyle()
                defaultParagraph.baseWritingDirection = .leftToRight
                defaultParagraph.alignment = .left
                let defaultFont = NSFont(name: "Times New Roman", size: 16) ?? NSFont.systemFont(ofSize: 16)
                textView.typingAttributes = [
                    .font: defaultFont,
                    .foregroundColor: NSColor(calibratedWhite: 0.88, alpha: 1.0),
                    .paragraphStyle: defaultParagraph
                ]
                // Sync coordinator's lastSelectedRange so toolbar buttons work
                self.vm.editorCoordinator?.lastSelectedRange = NSRange(location: 0, length: 0)
            }
        }

        vm.editorCoordinator = context.coordinator

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        let vm: EditorViewModel
        weak var textView: NSTextView?

        let bodyFont = NSFont(name: "Times New Roman", size: 16) ?? NSFont.systemFont(ofSize: 16)
        let h1Font = NSFont(name: "Times New Roman Bold", size: 28) ?? NSFont.boldSystemFont(ofSize: 28)
        let h2Font = NSFont(name: "Times New Roman Bold", size: 22) ?? NSFont.boldSystemFont(ofSize: 22)
        let h3Font = NSFont(name: "Times New Roman Bold", size: 18) ?? NSFont.boldSystemFont(ofSize: 18)
        let codeFont = NSFont(name: "Menlo", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let textColor = NSColor(calibratedWhite: 0.88, alpha: 1.0)

        private var isProcessingMarkdown = false
        var lastSelectedRange: NSRange = NSRange(location: 0, length: 0)

        init(vm: EditorViewModel) { self.vm = vm }

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

            let html = extractHTML(from: textView)
            Task { @MainActor in
                vm.textDidChange(html: html, length: textView.textStorage?.length ?? 0)
            }
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
            let attr = NSAttributedString(string: replacement, attributes: [
                .font: bodyFont,
                .foregroundColor: textColor
            ])
            storage.replaceCharacters(in: NSRange(location: lineStart, length: len), with: attr)
            textView.setSelectedRange(NSRange(location: lineStart + replacement.count, length: 0))
        }

        private var slashPosition: Int = 0

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
                ("Code", "chevron.left.forwardslash.chevron.right", 6),
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

        @objc private func slashMenuItemClicked(_ sender: NSMenuItem) {
            guard let textView = self.textView else { return }
            guard let storage = textView.textStorage else { return }

            // Remove the "/" character
            if slashPosition < storage.length {
                let charAtPos = (storage.string as NSString).substring(with: NSRange(location: slashPosition, length: 1))
                if charAtPos == "/" {
                    storage.replaceCharacters(in: NSRange(location: slashPosition, length: 1), with: "")
                    textView.setSelectedRange(NSRange(location: slashPosition, length: 0))
                }
            }

            switch sender.tag {
            case 1: applyFormat(.heading1, textView: textView)
            case 2: applyFormat(.heading2, textView: textView)
            case 3: applyFormat(.heading3, textView: textView)
            case 4: applyFormat(.bulletList, textView: textView)
            case 5: applyFormat(.checklist, textView: textView)
            case 6: applyFormat(.code, textView: textView)
            case 7: applyFormat(.divider, textView: textView)
            default: break
            }
            textView.didChangeText()
        }

        func extractHTML(from textView: NSTextView) -> String {
            guard let storage = textView.textStorage, storage.length > 0 else { return "" }
            let range = NSRange(location: 0, length: storage.length)
            guard let data = try? storage.data(from: range, documentAttributes: [
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
            case .code:
                storage.beginEditing()
                let str = storage.string as NSString
                var paraRange = str.paragraphRange(for: range)

                // Check if already code — toggle off
                var isCode = false
                if paraRange.length > 0 {
                    storage.enumerateAttribute(.codeBlock, in: paraRange, options: []) { val, _, _ in
                        if val != nil { isCode = true }
                    }
                }
                if isCode {
                    storage.removeAttribute(.codeBlock, range: paraRange)
                    storage.removeAttribute(.backgroundColor, range: paraRange)
                    storage.removeAttribute(.foregroundColor, range: paraRange)
                    applyFont(bodyFont, in: paraRange, storage: storage, textView: textView)
                    storage.addAttribute(.foregroundColor, value: NSColor(calibratedWhite: 0.88, alpha: 1.0), range: paraRange)
                    let ps = NSMutableParagraphStyle()
                    ps.baseWritingDirection = .leftToRight
                    ps.alignment = .left
                    storage.addAttribute(.paragraphStyle, value: ps, range: paraRange)
                } else {
                    // If cursor is on empty line with no content, insert a space placeholder
                    let paraStr = str.substring(with: paraRange)
                    if paraStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let insertPos = paraRange.location
                        // Insert a newline if we're at the very end without one, or use existing line
                        if paraRange.length == 0 {
                            storage.insert(NSAttributedString(string: " "), at: insertPos)
                            paraRange = NSRange(location: insertPos, length: 1)
                        }
                    }

                    applyFont(codeFont, in: paraRange, storage: storage, textView: textView)
                    storage.addAttribute(.codeBlock, value: true, range: paraRange)
                    let ps = NSMutableParagraphStyle()
                    ps.baseWritingDirection = .leftToRight
                    ps.alignment = .left
                    ps.headIndent = 12
                    ps.firstLineHeadIndent = 12
                    ps.tailIndent = -12
                    storage.addAttribute(.paragraphStyle, value: ps, range: paraRange)
                    storage.addAttribute(.foregroundColor, value: NSColor(calibratedWhite: 0.78, alpha: 1.0), range: paraRange)

                    // Set typing attributes so new text continues in code style
                    var typingAttrs = textView.typingAttributes
                    typingAttrs[.font] = codeFont
                    typingAttrs[.codeBlock] = true
                    typingAttrs[.paragraphStyle] = ps
                    typingAttrs[.foregroundColor] = NSColor(calibratedWhite: 0.78, alpha: 1.0)
                    textView.typingAttributes = typingAttrs

                    // Place cursor inside the code block
                    textView.setSelectedRange(NSRange(location: paraRange.location, length: 0))
                }
                storage.endEditing()
                textView.needsDisplay = true
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

            // Handle cursor at end of text or empty document — use previous character's line
            let adjustedRange: NSRange
            if str.length == 0 {
                // Empty document — just insert prefix
                storage.beginEditing()
                let attrPrefix = NSAttributedString(string: prefix, attributes: [.font: bodyFont, .foregroundColor: textColor])
                storage.insert(attrPrefix, at: 0)
                storage.endEditing()
                textView.setSelectedRange(NSRange(location: prefix.count, length: 0))
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

            // Handle cursor at end of text
            let adjustedRange: NSRange
            if str.length == 0 {
                storage.beginEditing()
                let attrPrefix = NSAttributedString(string: "☐ ", attributes: [.font: bodyFont, .foregroundColor: textColor])
                storage.insert(attrPrefix, at: 0)
                storage.endEditing()
                textView.setSelectedRange(NSRange(location: 2, length: 0))
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
                    let attrPrefix = NSAttributedString(string: "☐ ", attributes: [
                        .font: bodyFont,
                        .foregroundColor: textColor
                    ])
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

            // Checklist continuation
            for prefix in ["☐ ", "☑ "] {
                if lineStr.hasPrefix(prefix) {
                    let afterPrefix = String(lineStr.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if afterPrefix.isEmpty {
                        // Empty checklist item - remove prefix to end the list
                        storage.replaceCharacters(in: NSRange(location: lineRange.location, length: prefix.count), with: "")
                        textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
                        textView.didChangeText()
                        return true
                    }
                    let insertion = NSAttributedString(string: "\n☐ ", attributes: [
                        .font: bodyFont,
                        .foregroundColor: textColor
                    ])
                    storage.replaceCharacters(in: range, with: insertion)
                    textView.setSelectedRange(NSRange(location: range.location + 3, length: 0))
                    textView.didChangeText()
                    return true
                }
            }

            // Bullet list continuation
            if lineStr.hasPrefix("• ") {
                let afterPrefix = String(lineStr.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if afterPrefix.isEmpty {
                    storage.replaceCharacters(in: NSRange(location: lineRange.location, length: 2), with: "")
                    textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
                    textView.didChangeText()
                    return true
                }
                let insertion = NSAttributedString(string: "\n• ", attributes: [
                    .font: bodyFont,
                    .foregroundColor: textColor
                ])
                storage.replaceCharacters(in: range, with: insertion)
                textView.setSelectedRange(NSRange(location: range.location + 3, length: 0))
                textView.didChangeText()
                return true
            }

            return false
        }

        private func handleTab(textView: NSTextView) -> Bool {
            guard let storage = textView.textStorage else { return false }
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

            // If multiple lines or cursor is on a bullet/checklist line, indent lines
            let firstLineStr = str.substring(with: str.lineRange(for: NSRange(location: fullLineRange.location, length: 0)))
            let hasList = firstLineStr.hasPrefix("• ") || firstLineStr.hasPrefix("☐ ") || firstLineStr.hasPrefix("☑ ")

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
    }
}
