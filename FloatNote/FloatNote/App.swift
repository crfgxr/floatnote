import SwiftUI
import AppKit
import AVFoundation
import AudioToolbox
import ScreenCaptureKit

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

let APP_VERSION = "v1.10.0"
let LOCAL_SAVE_PATH = NSHomeDirectory() + "/.floatnote-local.html"
let LOCAL_TABS_PATH = NSHomeDirectory() + "/.floatnote-tabs.json"

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
                Button("Export Notes…") { vm.exportNotes() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Import Notes…") { vm.importNotes() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var vm: EditorViewModel?
    private var fileWatchTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        dbg("APP LAUNCHED")

        // Poll tabs file for external changes (e.g. from MCP server)
        fileWatchTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let vm = self?.vm else { return }
            MainActor.assumeIsolated {
                vm.checkExternalTabChanges()
            }
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
                window.minSize = NSSize(width: 50, height: 50)
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Format Actions

enum FormatAction: Equatable {
    case bold, italic, underline, heading1, heading2, heading3, bulletList, checklist, link, divider, body
}

// MARK: - Tab Model

struct TabData: Codable {
    var id: String
    var title: String
    var noteGuid: String?  // legacy field, ignored
    var html: String
    var recordingPath: String?
}

class NoteTab: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    var html: String = ""
    var lastSavedHTML: String = ""
    var recordingPath: String? = nil

    init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
    }

    func toData() -> TabData {
        TabData(id: id.uuidString, title: title, html: html, recordingPath: recordingPath)
    }

    static func from(_ data: TabData) -> NoteTab {
        let tab = NoteTab(id: UUID(uuidString: data.id) ?? UUID(), title: data.title)
        tab.html = data.html
        tab.recordingPath = data.recordingPath
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
    var wantsDictation: Bool = false  // user intent: keep dictation alive
    @Published var tabs: [NoteTab] = []
    @Published var activeTabId: UUID?
    @Published var editingTabId: UUID?
    @Published var draggingTabId: UUID?
    @Published var isRecording = false
    @Published var isSavingRecording = false
    @Published var recordPermissionDenied = false
    @Published var recordingTabId: UUID?
    @Published var recordingStartTime: Date?
    @Published var currentRecordingPath: String?
    @Published var selectedLanguage: TranscriptLanguage = .auto
    @Published var isTranscribing = false
    @Published var isSummarizing = false

    let recordingManager = RecordingManager()
    let deepgramClient = DeepgramClient()

    var activeTab: NoteTab? { tabs.first { $0.id == activeTabId } }
    var attributedText = NSMutableAttributedString()
    var onContentLoaded: ((NSAttributedString) -> Void)?
    weak var editorCoordinator: RichTextEditor.Coordinator?
    var isLoadingContent = false

    private var lastSavedHTML: String = ""
    private var currentHTML: String = ""
    var lastTabsModDate: Date?
    private var deletedTabIds: Set<String> = []
    private var isSavingInternally = false
    private var suppressSaveAfterReload = false

    init() {
        loadOrCreateNote()
    }

    private func loadOrCreateNote() {
        // Migrate old tabs file path if needed
        let oldTabsPath = NSHomeDirectory() + "/.evernote-editor-tabs.json"
        if !FileManager.default.fileExists(atPath: LOCAL_TABS_PATH),
           FileManager.default.fileExists(atPath: oldTabsPath) {
            try? FileManager.default.moveItem(atPath: oldTabsPath, toPath: LOCAL_TABS_PATH)
        }

        loadTabsLocal()

        if tabs.isEmpty {
            let tab = NoteTab(title: "Untitled")
            if let localHTML = loadLocal(), !localHTML.isEmpty {
                tab.html = localHTML
            }
            tabs = [tab]
            saveTabsLocal()
        }

        let firstTab = tabs[0]
        activeTabId = firstTab.id
        currentHTML = firstTab.html
        lastSavedHTML = firstTab.lastSavedHTML
        currentRecordingPath = firstTab.recordingPath

        if !firstTab.html.isEmpty, let attrStr = htmlToAttributedString(firstTab.html) {
            attributedText = NSMutableAttributedString(attributedString: attrStr)
            charCount = attributedText.length
            onContentLoaded?(attributedText)
        }
        status = currentHTML.isEmpty ? "Ready" : "Loaded"
        lastTabsModDate = tabsFileModDate()
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

        // Cancel any pending save to avoid overwriting external changes
        saveTimer?.invalidate()
        saveTimer = nil

        let newTabs = tabsData.map { NoteTab.from($0) }
        let currentActiveId = activeTabId

        // Merge: keep active tab's in-memory HTML if user is editing,
        // but add any new tabs from disk (e.g. MCP-created)
        let existingIds = Set(tabs.map { $0.id })
        let diskIds = Set(newTabs.map { $0.id })

        // Add new tabs that appeared on disk
        for newTab in newTabs where !existingIds.contains(newTab.id) {
            tabs.append(newTab)
        }
        // Remove tabs deleted from disk (except active)
        tabs.removeAll { !diskIds.contains($0.id) && $0.id != currentActiveId }

        // Refresh tab content from disk
        for diskTab in newTabs {
            guard let existing = tabs.first(where: { $0.id == diskTab.id }) else { continue }
            if diskTab.id == currentActiveId {
                // Active tab: reload editor if content changed externally
                if diskTab.html != currentHTML && !diskTab.html.isEmpty {
                    currentHTML = diskTab.html
                    existing.html = diskTab.html
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
                existing.recordingPath = diskTab.recordingPath
            }
        }
    }

    func saveTabsLocal() {
        isSavingInternally = true
        // Merge externally-added tabs (e.g. from MCP) before saving
        if let diskData = try? Data(contentsOf: URL(fileURLWithPath: LOCAL_TABS_PATH)),
           let diskTabs = try? JSONDecoder().decode([TabData].self, from: diskData) {
            let memoryIds = Set(tabs.map { $0.id })
            for dt in diskTabs {
                guard let diskId = UUID(uuidString: dt.id),
                      !deletedTabIds.contains(dt.id.uppercased()) else { continue }
                if !memoryIds.contains(diskId) {
                    // New tab from external source
                    tabs.append(NoteTab.from(dt))
                } else if diskId != activeTabId,
                          let tab = tabs.first(where: { $0.id == diskId }),
                          tab.html != dt.html {
                    // External edit to non-active tab — adopt disk version
                    tab.html = dt.html
                    tab.title = dt.title
                    tab.recordingPath = dt.recordingPath
                }
            }
        }
        let data = tabs.map { $0.toData() }
        if let json = try? JSONEncoder().encode(data) {
            try? json.write(to: URL(fileURLWithPath: LOCAL_TABS_PATH))
        }
        lastTabsModDate = tabsFileModDate()
        DispatchQueue.main.async { self.isSavingInternally = false }
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
        currentRecordingPath = newTab.recordingPath
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
        currentHTML = ""
        currentRecordingPath = nil
        lastSavedHTML = ""
        charCount = 0
        onContentLoaded?(NSAttributedString(string: ""))
        saveTabsLocal()
        status = "New note"
    }

    func deleteTab(_ id: UUID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if id == recordingTabId && isRecording { return }
        deletedTabIds.insert(id.uuidString.uppercased())

        // Delete associated recording file from disk
        if let recPath = tabs[index].recordingPath {
            try? FileManager.default.removeItem(atPath: recPath)
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

    private var saveTimer: Timer?

    func textDidChange(html: String, length: Int) {
        guard !isLoadingContent else { return }
        if suppressSaveAfterReload {
            suppressSaveAfterReload = false
            return
        }
        charCount = length
        currentHTML = html
        activeTab?.html = html
        status = "Editing..."
        // Debounce disk writes — save after 0.5s of idle
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveLocal(html: self.currentHTML)
                self.saveTabsLocal()
                self.status = "Saved"
            }
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

    func startRecording() async {
        // Create a new tab for the recording
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm"
        let title = "Recording \(formatter.string(from: Date()))"
        addTab()
        activeTab?.title = title

        guard let tab = activeTab else { return }

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
            tab.recordingPath = url.path
        }
        recordingTabId = nil
        saveTabsLocal()
    }

    func transcribeRecording() async {
        dbg("transcribe: CALLED, currentPath=\(currentRecordingPath ?? "nil") tabPath=\(activeTab?.recordingPath ?? "nil")")
        let path = currentRecordingPath ?? activeTab?.recordingPath
        guard let path, let client = deepgramClient else {
            dbg("transcribe: guard failed — path=\(path ?? "nil") client=\(deepgramClient != nil)")
            return
        }
        let fileURL = URL(fileURLWithPath: path)
        isTranscribing = true
        status = "Transcribing…"
        guard let result = await client.transcribe(fileURL: fileURL, language: selectedLanguage, includeSummary: false) else {
            isTranscribing = false
            status = "Transcription failed"
            return
        }
        isTranscribing = false
        status = "Transcription done"
        insertTextIntoEditor(result.transcript)
    }

    func summarizeRecording() async {
        let path = currentRecordingPath ?? activeTab?.recordingPath
        guard let path, let client = deepgramClient else { return }
        let fileURL = URL(fileURLWithPath: path)
        isSummarizing = true
        guard let result = await client.transcribe(fileURL: fileURL, language: .english, includeSummary: true) else {
            isSummarizing = false
            return
        }
        isSummarizing = false
        if let summary = result.summary {
            insertTextIntoEditor("Summary:\n\(summary)")
        }
    }

    private func insertTextIntoEditor(_ text: String) {
        let newHtml = text.components(separatedBy: "\n").map { line in
            let escaped = line.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "<p>\(escaped.isEmpty ? "<br>" : escaped)</p>"
        }.joined()

        let existing = currentHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        let html: String
        if existing.isEmpty {
            html = newHtml
        } else {
            html = existing + "<hr>" + newHtml
        }

        currentHTML = html
        activeTab?.html = html
        if let attrStr = htmlToAttributedString(html) {
            attributedText = NSMutableAttributedString(attributedString: attrStr)
            charCount = attributedText.length
            onContentLoaded?(attributedText)
        }
        saveLocal(html: html)
        saveTabsLocal()
    }

    private func saveLocal(html: String) {
        try? html.write(toFile: LOCAL_SAVE_PATH, atomically: true, encoding: .utf8)
    }

    func saveLocalSync() {
        activeTab?.html = currentHTML
        try? currentHTML.write(toFile: LOCAL_SAVE_PATH, atomically: true, encoding: .utf8)
        saveTabsLocal()
    }

    private func loadLocal() -> String? {
        try? String(contentsOfFile: LOCAL_SAVE_PATH, encoding: .utf8)
    }

    // MARK: - Import / Export

    func exportNotes() {
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
                tab.recordingPath = td.recordingPath
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
        body { font-family: 'Times New Roman', serif; font-size: 16px; color: #e0e0e0; direction: ltr; text-align: left; }
        h1 { font-size: 28px; font-weight: 700; }
        h2 { font-size: 22px; font-weight: 600; }
        h3 { font-size: 18px; font-weight: 600; }
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

        return attrStr
    }
}

// MARK: - Deepgram Client

enum TranscriptLanguage: String, CaseIterable {
    case auto = "auto"
    case english = "en"
    case turkish = "tr"

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .english: return "English"
        case .turkish: return "Turkish"
        }
    }
}

struct DeepgramResult {
    var transcript: String   // diarized speaker-formatted text
    var summary: String?     // summarize=v2 result (English only)
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

        var params = "model=nova-3&diarize=true&smart_format=true&punctuate=true&utterances=true"
        if language == .auto {
            params += "&language=multi"
        } else {
            params += "&language=\(language.rawValue)"
        }
        if includeSummary {
            params += "&summarize=v2"
        }

        guard let url = URL(string: "https://api.deepgram.com/v1/listen?\(params)") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")
        request.httpBody = audioData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResp = response as? HTTPURLResponse else {
            dbg("deepgram: request failed")
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

    var body: some View {
        VStack(spacing: 0) {
            FormatToolbar()
            Divider()
            TabBar()
            Divider()
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
                .background(.bar)
                .task {
                    // Auto-dismiss after 10s if background stop hangs
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    vm.isSavingRecording = false
                }
                Divider()
            } else if let path = vm.activeTab?.recordingPath {
                RecordingPlayerView(fileURL: URL(fileURLWithPath: path))
                    .id(path)  // Force recreation when tab/path changes
                Divider()
            }
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
                    ForEach(vm.tabs) { tab in
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
                HStack(spacing: 3) {
                    if tab.recordingPath != nil {
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
            Text("\(vm.charCount) chars")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
            Text(APP_VERSION)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.5))
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
    @State private var hoveredButton: String?

    var body: some View {
        HStack(spacing: 0) {
            Group {
                toolBtn("H1", id: "h1") { vm.performFormat(.heading1) }
                toolBtn("H2", id: "h2") { vm.performFormat(.heading2) }
                toolBtn("H3", id: "h3") { vm.performFormat(.heading3) }
                toolBtn("Aa", id: "body") { vm.performFormat(.body) }
            }

            thinDivider()

            Group {
                iconBtn("bold", id: "bold") { vm.performFormat(.bold) }
                iconBtn("italic", id: "italic") { vm.performFormat(.italic) }
                iconBtn("underline", id: "underline") { vm.performFormat(.underline) }
            }

            thinDivider()

            Group {
                iconBtn("list.bullet", id: "bullet") { vm.performFormat(.bulletList) }
                iconBtn("checklist", id: "check") { vm.performFormat(.checklist) }
                iconBtn("link", id: "link") { vm.performFormat(.link) }
                iconBtn("minus", id: "divider") { vm.performFormat(.divider) }
            }

            thinDivider()

            Group {
                Button(action: { vm.togglePin() }) {
                    Image(systemName: vm.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .foregroundColor(vm.isPinned ? .accentColor : .secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(hoveredButton == "pin" ? Color.primary.opacity(0.08) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { hoveredButton = $0 ? "pin" : nil }
                .help(vm.isPinned ? "Unpin from top" : "Pin to top")

                Button(action: { toggleDictation() }) {
                    Image(systemName: vm.isDictating ? "mic.fill" : "mic")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .foregroundColor(vm.isDictating ? .red : .secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(hoveredButton == "mic" ? Color.primary.opacity(0.08) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { hoveredButton = $0 ? "mic" : nil }
                .help(vm.isDictating ? "Stop Dictation" : "Start Dictation")
            }

            thinDivider()

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
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .foregroundColor(
                        vm.recordPermissionDenied ? .secondary.opacity(0.4) :
                        vm.isRecording ? .red : .secondary
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 4)
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
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(.bar)
    }

    func thinDivider() -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }

    func toolBtn(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 22)
                .foregroundColor(.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hoveredButton == id ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hoveredButton = $0 ? id : nil }
    }

    func toggleDictation() {
        vm.wantsDictation.toggle()
        if vm.wantsDictation {
            startDictation()
            // Watch for dictation stopping (system timeout, user switched away, etc.)
            NotificationCenter.default.addObserver(forName: NSNotification.Name("NSTextInputContextDictationDidEnd"), object: nil, queue: .main) { [weak vm] _ in
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
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak vm] _ in
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
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name("NSTextInputContextDictationDidEnd"), object: nil)
            NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
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
                .frame(maxWidth: .infinity, minHeight: 22)
                .foregroundColor(.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 4)
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
        .background(.bar)
    }

    private func timeString(_ s: TimeInterval) -> String {
        let t = Int(max(0, s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Recording Player View

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

    var body: some View {
        Group {
        if !fileExists {
            Text("Recording file not found")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 0) {
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
                            Task { await vm.transcribeRecording() }
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
                            Task { await vm.summarizeRecording() }
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
                        .disabled(vm.isTranscribing || vm.isSummarizing || vm.selectedLanguage == .turkish)
                        .help(vm.selectedLanguage == .turkish ? "Summary is available for English only" : "Get AI summary")

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
            }
            .background(.bar)
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
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { t in
            currentTime = t.seconds
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            isPlaying = false
            currentTime = 0
            p.seek(to: .zero)
        }
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

// MARK: - Block Caret NSTextView

class BlockCaretTextView: NSTextView {
    private let caretView: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        return v
    }()

    // MARK: - Drag-to-reorder state
    private var isDraggingLine = false
    private var dragStartLineIndex: Int = 0  // character index of dragged line start
    private var dragInsertIndex: Int = -1     // character index where line will be inserted
    private var dragDidMove = false
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        addSubview(caretView)
        addSubview(dragSourceDim)
        addSubview(dragInsertionLine)
        DispatchQueue.main.async { self.updateCaretPosition() }

        // Track mouse movement for cursor changes over list prefixes
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage else {
            super.mouseMoved(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let adjusted = NSPoint(x: point.x - textContainerInset.width, y: point.y - textContainerInset.height)
        var fraction: CGFloat = 0
        let charIndex = lm.characterIndex(for: adjusted, in: tc, fractionOfDistanceBetweenInsertionPoints: &fraction)
        if charIndex < ts.length {
            let (lineRange, prefixLen) = listPrefixLen(at: charIndex)
            if prefixLen > 0 && charIndex < lineRange.location + prefixLen {
                NSCursor.pointingHand.set()
                return
            }
        }
        NSCursor.iBeam.set()
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

    // MARK: - Backspace removes full prefix
    // MARK: - Paste: strip external formatting, apply FloatNote body style, auto-link URLs
    override func paste(_ sender: Any?) {
        guard let pb = NSPasteboard.general.string(forType: .string), !pb.isEmpty else {
            super.paste(sender)
            return
        }
        guard let storage = textStorage else { return }

        recordUndoSnapshot()

        let bodyFont = NSFont(name: "Times New Roman", size: 16) ?? NSFont.systemFont(ofSize: 16)
        let ps = NSMutableParagraphStyle()
        ps.baseWritingDirection = .leftToRight
        ps.alignment = .left
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor(calibratedWhite: 0.88, alpha: 1.0),
            .paragraphStyle: ps
        ]

        // Build attributed string with URLs auto-linked
        let result = NSMutableAttributedString(string: pb, attributes: bodyAttrs)
        let urlPattern = try? NSRegularExpression(pattern: #"https?://[^\s<>\"\)\]]+"#, options: [])
        if let matches = urlPattern?.matches(in: pb, range: NSRange(location: 0, length: (pb as NSString).length)) {
            for match in matches {
                let urlStr = (pb as NSString).substring(with: match.range)
                if let url = URL(string: urlStr) {
                    result.addAttributes([
                        .link: url,
                        .foregroundColor: NSColor(calibratedRed: 0.42, green: 0.68, blue: 1.0, alpha: 1.0),
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ], range: match.range)
                }
            }
        }

        let range = selectedRange()
        storage.replaceCharacters(in: range, with: result)
        setSelectedRange(NSRange(location: range.location + result.length, length: 0))
        typingAttributes = bodyAttrs
        didChangeText()
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
        if let lm = layoutManager, let tc = textContainer, let ts = textStorage {
            var fraction: CGFloat = 0
            let charIndex = lm.characterIndex(for: adjustedPoint, in: tc, fractionOfDistanceBetweenInsertionPoints: &fraction)
            if charIndex < ts.length {
                let (lineRange, prefixLen) = listPrefixLen(at: charIndex)
                if prefixLen > 0 && charIndex < lineRange.location + prefixLen {
                    // Clicked on a list prefix — prepare for possible drag
                    isDraggingLine = true
                    dragDidMove = false
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
        guard isDraggingLine, let storage = textStorage, let lm = layoutManager, let tc = textContainer else {
            super.mouseDragged(with: event)
            return
        }

        dragDidMove = true
        dragSourceDim.isHidden = false
        NSCursor.closedHand.set()

        let point = convert(event.locationInWindow, from: nil)
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

        let layoutManager = NSLayoutManager()
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
                    // Apply LTR paragraph style to all lines
                    fixed.addAttribute(.paragraphStyle, value: ltr, range: fullRange)
                    // Apply text color to all
                    fixed.addAttribute(.foregroundColor, value: NSColor(calibratedWhite: 0.88, alpha: 1.0), range: fullRange)
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
                                storage.addAttribute(.foregroundColor, value: NSColor(calibratedWhite: 0.45, alpha: 1.0), range: cRange)
                            }
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

        // Load initial content if it was ready before the view was created
        if vm.attributedText.length > 0 {
            vm.onContentLoaded?(vm.attributedText)
        }

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

            applyListIndentForCurrentLine(textView: textView)

            let html = extractHTML(from: textView)
            Task { @MainActor in
                vm.textDidChange(html: html, length: textView.textStorage?.length ?? 0)
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
                let ps = NSMutableParagraphStyle()
                ps.baseWritingDirection = .leftToRight
                ps.alignment = .left
                ps.headIndent = prefixWidth

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
                        ps.paragraphSpacingBefore = 8
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
                    let ps = NSMutableParagraphStyle()
                    ps.baseWritingDirection = .leftToRight
                    ps.alignment = .left
                    ps.headIndent = prefixWidth

                    let currentIndent = indentLevel(of: lineStr)

                    // Add spacing before parent items that have indented children
                    if i + 1 < lines.count {
                        let nextStr = lines[i + 1].str
                        let nextIndent = indentLevel(of: nextStr)
                        let nextHasPrefix = nextStr.dropFirst(nextIndent).hasPrefix("• ") ||
                                            nextStr.dropFirst(nextIndent).hasPrefix("☐ ") ||
                                            nextStr.dropFirst(nextIndent).hasPrefix("☑ ")
                        if nextHasPrefix && nextIndent > currentIndent {
                            // This is a parent — add spacing only if not the first line
                            // and previous line is not an indented child of us
                            if i > 0 {
                                let prevStr = lines[i - 1].str
                                let prevIndent = indentLevel(of: prevStr)
                                // Add gap if previous line is at same or lower indent (sibling/ancestor, not child)
                                if prevIndent <= currentIndent {
                                    ps.paragraphSpacingBefore = 8
                                }
                            }
                        }
                    }

                    storage.addAttribute(.paragraphStyle, value: ps, range: lineRange)
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
            let attr = NSAttributedString(string: replacement, attributes: [
                .font: bodyFont,
                .foregroundColor: textColor
            ])
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
                    let newLine = NSAttributedString(string: "☐ \n", attributes: [.font: bodyFont, .foregroundColor: textColor])
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
                let attrPrefix = NSAttributedString(string: "☐ ", attributes: [.font: bodyFont, .foregroundColor: textColor])
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

                // Continue with same indent + prefix (☑ continues as ☐)
                let continuationPrefix = (prefix == "☑ ") ? "☐ " : prefix
                let insertionStr = "\n" + leadingSpaces + continuationPrefix
                let insertion = NSAttributedString(string: insertionStr, attributes: [
                    .font: bodyFont,
                    .foregroundColor: textColor
                ])
                storage.replaceCharacters(in: range, with: insertion)
                textView.setSelectedRange(NSRange(location: range.location + insertionStr.count, length: 0))
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
