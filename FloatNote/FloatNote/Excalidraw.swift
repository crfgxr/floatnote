import SwiftUI
import WebKit

// MARK: - Board storage
//
// Each note has its own Excalidraw board, stored as a scene JSON file at
// ~/.floatnote-excalidraw/<noteUUID>.excalidraw.json. Writes are atomic
// (temp + replace) — plain in-place writes can fail silently under sandbox.

enum ExcalidrawStore {
    static let dir = NSHomeDirectory() + "/.floatnote-excalidraw"

    static func boardPath(for id: UUID) -> String {
        dir + "/" + id.uuidString + ".excalidraw.json"
    }

    static func ensureDir() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    /// Raw scene JSON for a note's board, or nil if none saved yet.
    static func readJSON(for id: UUID) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: boardPath(for: id))) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Atomic write (temp file + replace), with a move fallback for first write
    /// when the destination does not exist yet.
    static func writeJSON(_ json: String, for id: UUID) {
        ensureDir()
        let path = boardPath(for: id)
        guard let data = json.data(using: .utf8) else { return }
        let tmp = URL(fileURLWithPath: path + ".tmp")
        do {
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.moveItem(at: tmp, to: URL(fileURLWithPath: path))
        }
    }

    static func deleteBoard(for id: UUID) {
        try? FileManager.default.removeItem(atPath: boardPath(for: id))
    }

    /// Whether a note's board has at least one element (cheap JSON peek).
    static func hasContent(for id: UUID) -> Bool {
        guard let json = readJSON(for: id),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = obj["elements"] as? [Any] else { return false }
        return !elements.isEmpty
    }

    /// Modification date of a note's board file, nil if it doesn't exist.
    static func modDate(for id: UUID) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: boardPath(for: id)))?[.modificationDate] as? Date
    }

    /// Mod-dates of every board file, keyed by note ID. Drives the External
    /// File Sync pattern for MCP-written boards (see checkExternalBoardChanges).
    static func scanModDates() -> [UUID: Date] {
        var result: [UUID: Date] = [:]
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return result }
        let suffix = ".excalidraw.json"
        for f in files where f.hasSuffix(suffix) {
            guard let id = UUID(uuidString: String(f.dropLast(suffix.count))) else { continue }
            if let d = modDate(for: id) { result[id] = d }
        }
        return result
    }

    /// Scan the store and return the set of note IDs whose board is non-empty.
    /// Used at launch to seed the toolbar button's active/passive state.
    static func scanContentIds() -> Set<UUID> {
        var result = Set<UUID>()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return result }
        let suffix = ".excalidraw.json"
        for f in files where f.hasSuffix(suffix) {
            let idStr = String(f.dropLast(suffix.count))
            guard let id = UUID(uuidString: idStr) else { continue }
            if hasContent(for: id) { result.insert(id) }
        }
        return result
    }
}

extension Notification.Name {
    /// Posted after a board's scene is saved. userInfo: ["tabId": UUID, "hasContent": Bool].
    static let floatnoteBoardSaved = Notification.Name("floatnoteBoardSaved")
    /// Posted (object = note UUID) when a board file changed on disk from
    /// outside the app (MCP) so an open board view reloads its scene.
    static let floatnoteBoardExternallyChanged = Notification.Name("floatnoteBoardExternallyChanged")
}

// MARK: - Board view (WKWebView hosting bundled, offline Excalidraw)

struct ExcalidrawBoardView: NSViewRepresentable {
    let tabId: UUID
    let theme: AppTheme

    func makeCoordinator() -> Coordinator { Coordinator(tabId: tabId) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "floatnote")
        config.userContentController = ucc

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // Let the editor theme show through before the canvas paints.
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        context.coordinator.pendingTheme = theme

        if let indexURL = Self.indexURL() {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        } else {
            dbg("Excalidraw: index.html not found in bundle resources")
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.applyTheme(theme)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.flush()
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "floatnote")
    }

    /// Resolve the bundled Excalidraw entry HTML from the SPM resource bundle.
    static func indexURL() -> URL? {
        Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "excalidraw")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let tabId: UUID
        weak var webView: WKWebView?
        var pendingTheme: AppTheme?
        private var isReady = false
        private var externalChangeObserver: NSObjectProtocol?

        init(tabId: UUID) {
            self.tabId = tabId
            super.init()
            // Reload the scene when MCP rewrites this board's file while open.
            externalChangeObserver = NotificationCenter.default.addObserver(
                forName: .floatnoteBoardExternallyChanged, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, let id = note.object as? UUID,
                      id == self.tabId, self.isReady else { return }
                self.loadScene()
            }
        }

        deinit {
            if let o = externalChangeObserver { NotificationCenter.default.removeObserver(o) }
        }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                isReady = true
                loadScene()
                if let t = pendingTheme { applyTheme(t) }
            case "save":
                save(body)
            default:
                break
            }
        }

        private func loadScene() {
            // Pass the file content as a JS *string literal* — floatnoteLoadScene
            // JSON.parses string input (falling back to {}). Interpolating the raw
            // file content would execute it as JS if the file were ever malformed
            // or tampered with (it's also written by the MCP server now).
            let json = ExcalidrawStore.readJSON(for: tabId) ?? "{}"
            guard let data = try? JSONEncoder().encode(json),
                  let literal = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("window.floatnoteLoadScene(\(literal));", completionHandler: nil)
        }

        private func save(_ body: [String: Any]) {
            var scene: [String: Any] = [:]
            scene["elements"] = body["elements"] ?? []
            scene["appState"] = body["appState"] ?? [:]
            scene["files"] = body["files"] ?? [:]
            guard let data = try? JSONSerialization.data(withJSONObject: scene),
                  let json = String(data: data, encoding: .utf8) else { return }
            ExcalidrawStore.writeJSON(json, for: tabId)
            let hasContent = (scene["elements"] as? [Any])?.isEmpty == false
            NotificationCenter.default.post(
                name: .floatnoteBoardSaved,
                object: nil,
                userInfo: ["tabId": tabId, "hasContent": hasContent]
            )
        }

        func applyTheme(_ theme: AppTheme) {
            pendingTheme = theme
            guard isReady else { return }
            let mode = theme.swiftUIScheme == .dark ? "dark" : "light"
            webView?.evaluateJavaScript("window.floatnoteSetTheme('\(mode)');", completionHandler: nil)
        }

        /// Force any debounced in-flight save to flush immediately (before teardown).
        func flush() {
            webView?.evaluateJavaScript("window.floatnoteFlush && window.floatnoteFlush();", completionHandler: nil)
        }
    }
}
