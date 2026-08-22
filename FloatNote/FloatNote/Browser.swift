import SwiftUI
import AppKit
import Combine
import WebKit

// MARK: - Model

/// One page in the browser panel. Only `url` and `title` are persisted (under
/// `fn.browserTabs`): restoring a tab means reopening its page, not replaying
/// its history — a serialized `WKBackForwardList` isn't portable, and nobody
/// expects a browser's forward stack to survive a quit.
struct BrowserTab: Identifiable, Codable, Equatable {
    let id: UUID
    var url: String
    var title: String

    init(id: UUID = UUID(), url: String = "about:blank", title: String = "") {
        self.id = id
        self.url = url
        self.title = title
    }

    /// What the chip says. A page reports its title late (or never), so fall
    /// back to the host — "docs.swift.org" identifies a tab, a full URL doesn't
    /// fit in one.
    var displayName: String {
        if !title.isEmpty { return title }
        if url.isEmpty || url == "about:blank" { return "New Tab" }
        return URL(string: url)?.host ?? url
    }
}

/// Live chrome state for one page. Deliberately not part of `BrowserTab`: none
/// of it survives a relaunch, and all of it changes many times per navigation.
struct BrowserPageState: Equatable {
    var progress: Double = 0
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
}

/// Outcome of one RPC action — the two shapes the response file can take.
private enum BrowserRPCOutcome {
    case ok([String: Any])
    case failure(String)
}

// MARK: - Sessions

/// Owns browser pages independently of the SwiftUI view lifecycle, exactly as
/// `TerminalSessions` owns shells: a `WKWebView` is created the first time its
/// tab is shown (or touched over RPC) and lives until `close(_:)` — the chip's
/// ✕ — NOT when the SwiftUI view is dismantled. That is what makes hiding the
/// panel keep the page (and its scroll position, and its logins) instead of
/// reloading it, and what lets `browser_read` answer while the panel is hidden.
///
/// It is also the RPC executor: `mcp-server.js` is a separate node process, so
/// Claude's calls arrive as files in `~/.floatnote-browser-rpc/` and are
/// answered next to them (the External File Sync convention).
final class BrowserSessions: ObservableObject {
    static let shared = BrowserSessions()

    @Published private(set) var tabs: [BrowserTab] = []
    @Published var activeTabId: UUID? {
        didSet {
            guard activeTabId != oldValue else { return }
            UserDefaults.standard.set(activeTabId?.uuidString ?? "", forKey: Self.activeKey)
        }
    }
    /// Per-page chrome state, keyed by tab id. Read by the toolbar; written by
    /// the KVO observers in `BrowserPage`.
    @Published private(set) var states: [UUID: BrowserPageState] = [:]

    private var pages: [UUID: BrowserPage] = [:]
    private var rpcWatcher: DispatchSourceFileSystemObject?
    /// Request stems already handed to `execute` — an action can take seconds
    /// (a navigation waits for `didFinish`), and both the vnode watcher and the
    /// 2s timer will see the same file again in the meantime.
    private var inflight: Set<String> = []

    static let tabsKey = "fn.browserTabs"
    static let activeKey = "fn.browserActiveTab"
    static let persistKey = "fn.browserPersistSession"
    static let allowWritesKey = "fn.browserAllowClaudeWrites"
    static let rpcDir = NSHomeDirectory() + "/.floatnote-browser-rpc"
    static let shotsDir = NSHomeDirectory() + "/.floatnote-browser-shots"

    private init() {
        restoreTabs()
    }

    // MARK: Tabs

    private func restoreTabs() {
        if let data = UserDefaults.standard.data(forKey: Self.tabsKey),
           let saved = try? JSONDecoder().decode([BrowserTab].self, from: data), !saved.isEmpty {
            tabs = saved
        }
        // The empty state is one blank tab, not zero: a panel with no page has
        // no URL field to type into and no way back.
        if tabs.isEmpty { tabs = [BrowserTab()] }
        let stored = UserDefaults.standard.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:))
        activeTabId = tabs.contains(where: { $0.id == stored }) ? stored : tabs.first?.id
    }

    private func saveTabs() {
        guard let data = try? JSONEncoder().encode(tabs) else { return }
        UserDefaults.standard.set(data, forKey: Self.tabsKey)
    }

    @discardableResult
    func newTab() -> UUID {
        let tab = BrowserTab()
        tabs.append(tab)
        activeTabId = tab.id
        saveTabs()
        return tab.id
    }

    /// Open `url`, in a new tab or in the active one. Returns the tab it landed
    /// in so an RPC caller can address it later.
    @discardableResult
    func open(_ url: String, newTab wantsNewTab: Bool) -> UUID {
        let id: UUID
        if !wantsNewTab, let active = activeTabId, tabs.contains(where: { $0.id == active }) {
            id = active
        } else {
            id = newTab()
        }
        navigate(id, to: url)
        return id
    }

    func close(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        pages[id]?.detach()
        pages[id] = nil
        states[id] = nil
        tabs.remove(at: idx)
        if activeTabId == id {
            activeTabId = tabs.isEmpty ? nil : tabs[min(idx, tabs.count - 1)].id
        }
        // Same empty-state rule as launch — closing the last tab leaves a blank
        // page, not a dead panel. Visibility is the app shell's business.
        if tabs.isEmpty { newTab() } else { saveTabs() }
        dbg("browser: closed tab — \(tabs.count) open")
    }

    func navigate(_ id: UUID, to url: String) {
        guard let page = page(for: id) else { return }
        let target = Self.resolveInput(url)
        if let idx = tabs.firstIndex(where: { $0.id == id }), tabs[idx].url != target {
            tabs[idx].url = target
            saveTabs()
        }
        page.load(target)
    }

    func back(_ id: UUID) { page(for: id)?.webView.goBack() }
    func forward(_ id: UUID) { page(for: id)?.webView.goForward() }
    func reload(_ id: UUID) { page(for: id)?.webView.reload() }
    func stop(_ id: UUID) { page(for: id)?.webView.stopLoading() }

    // MARK: Pages

    /// The live web view for `id`, created (and its URL loaded) on first use.
    func webView(for id: UUID) -> WKWebView { pageObject(for: id).webView }

    private func pageObject(for id: UUID) -> BrowserPage {
        if let existing = pages[id] { return existing }
        let page = BrowserPage(id: id, sessions: self)
        pages[id] = page
        // Restored tabs load here, on first sight — not at launch, so a relaunch
        // doesn't fetch pages nobody has asked for yet.
        page.load(tabs.first(where: { $0.id == id })?.url ?? "about:blank")
        return page
    }

    fileprivate func page(for id: UUID) -> BrowserPage? {
        guard tabs.contains(where: { $0.id == id }) else { return nil }
        return pageObject(for: id)
    }

    /// A clean profile by default, matching Claude Desktop's "separate from your
    /// personal browser" rule: the browser an agent drives must not start out
    /// logged into everything the user is. One store shared by every tab, so a
    /// login made in one tab is visible in the next.
    static var persistSession: Bool { UserDefaults.standard.bool(forKey: persistKey) }

    private static var sharedDataStore: WKWebsiteDataStore?

    static func dataStore() -> WKWebsiteDataStore {
        if let store = sharedDataStore { return store }
        let store = persistSession ? WKWebsiteDataStore.default() : WKWebsiteDataStore.nonPersistent()
        sharedDataStore = store
        return store
    }

    /// Flipping persistence has to rebuild every page: a web view's data store
    /// is fixed at creation, so an existing tab would keep the old profile.
    func setPersistSession(_ persist: Bool) {
        guard persist != Self.persistSession else { return }
        UserDefaults.standard.set(persist, forKey: Self.persistKey)
        Self.sharedDataStore = nil
        for page in pages.values { page.detach() }
        pages.removeAll()
        states.removeAll()
        objectWillChange.send()
        dbg("browser: session persistence → \(persist), \(tabs.count) page(s) rebuilt")
    }

    /// Pushed from `BrowserPage`'s KVO observers: one funnel for every property
    /// the chrome paints from, so the view never observes a web view directly.
    fileprivate func pageChanged(_ id: UUID) {
        guard let webView = pages[id]?.webView else { return }
        var next = states[id] ?? BrowserPageState()
        next.progress = webView.estimatedProgress
        next.isLoading = webView.isLoading
        next.canGoBack = webView.canGoBack
        next.canGoForward = webView.canGoForward
        if states[id] != next { states[id] = next }

        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let url = webView.url?.absoluteString ?? tabs[idx].url
        let title = webView.title ?? ""
        if tabs[idx].url != url {
            // A new document: adopt its title even when empty, or the chip keeps
            // advertising the page we just left.
            tabs[idx].url = url
            tabs[idx].title = title
            saveTabs()
        } else if !title.isEmpty, tabs[idx].title != title {
            tabs[idx].title = title
            saveTabs()
        }
    }

    // MARK: Address parsing

    /// What the URL field (and every RPC `url` param) accepts: a scheme is taken
    /// as-is, a bare host gets `https://`, and anything else is a search. The
    /// host test is deliberately dumb — a dot and no spaces — because the only
    /// failure mode is searching for something that was nearly a URL.
    static func resolveInput(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "about:blank" }
        if text.contains("://") || text.hasPrefix("about:") || text.hasPrefix("data:") {
            return text
        }
        let looksLikeHost = !text.contains(" ")
            && ((text.contains(".") && !text.hasSuffix(".")) || text.hasPrefix("localhost"))
        if looksLikeHost { return "https://" + text }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let query = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        return "https://duckduckgo.com/?q=\(query)"
    }

    // MARK: - RPC

    /// Write actions default to ON: Claude Code in the terminal already has a
    /// shell on this machine, so clicking a link in a sandboxed web view adds no
    /// privilege. The switch exists to make a read-only session possible, and
    /// the per-request log line is what makes a write recoverable after the fact.
    static var allowClaudeWrites: Bool {
        UserDefaults.standard.object(forKey: allowWritesKey) as? Bool ?? true
    }

    private static let writesDisabled = "write actions are disabled in FloatNote's browser settings"
    private static let noTabError = "no such tab — pass an id from browser_tabs, or open one first"

    /// Fires `pollRPC()` the moment the MCP server drops a request, instead of
    /// waiting out the 2s timer. The timer stays as the safety net — a watcher
    /// misses events if the directory is recreated.
    func startRPCWatcher() {
        try? FileManager.default.createDirectory(atPath: Self.rpcDir, withIntermediateDirectories: true)
        // Qualified: this class has its own `open(_:newTab:)`, which shadows
        // the POSIX one.
        let fd = Darwin.open(Self.rpcDir, O_EVTONLY)
        guard fd >= 0 else {
            dbg("browser: cannot watch \(Self.rpcDir)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main
        )
        source.setEventHandler { [weak self] in self?.pollRPC() }
        // Qualified for the same reason as `Darwin.open` above: `close(_:)` here
        // is this class's tab-closing method.
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        rpcWatcher = source
        dbg("browser: rpc watcher started on \(Self.rpcDir)")
    }

    /// Consume every request file that isn't already running. Registered on the
    /// AppDelegate 2s timer as well as the watcher above.
    func pollRPC() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: Self.rpcDir),
              !names.isEmpty else { return }
        for name in names.sorted() where name.hasSuffix(".req.json") {
            let stem = String(name.dropLast(".req.json".count))
            guard !inflight.contains(stem) else { continue }
            let path = Self.rpcDir + "/" + name
            guard let data = FileManager.default.contents(atPath: path),
                  let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                // Unparseable. A temp+rename writer never produces a
                // half-written file, but a *badly* named temp file inside the
                // spool would look like one — so give anything this fresh a
                // couple of polls to become whole, and only then treat it as
                // garbage. Left in place it would be re-read forever.
                let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                if let modified, Date().timeIntervalSince(modified) < 3 { continue }
                dbg("browser: dropped unreadable request \(name)")
                try? FileManager.default.removeItem(atPath: path)
                continue
            }
            inflight.insert(stem)
            let id = request["id"] as? String ?? stem
            let action = (request["action"] as? String ?? "").lowercased()
            let params = request["params"] as? [String: Any] ?? [:]
            dbg("browser: \(action.isEmpty ? "<no action>" : action) \(Self.summarize(params)) [req \(stem.prefix(8))]")
            // A call the MCP side has already given up on must never be replayed
            // against a live page minutes later.
            if let ts = request["ts"] as? Double, Date().timeIntervalSince1970 - ts > 60 {
                respond(stem: stem, id: id, outcome: .failure("request expired (older than 60s)"))
                continue
            }
            execute(action: action, params: params) { [weak self] outcome in
                self?.respond(stem: stem, id: id, outcome: outcome)
            }
        }
    }

    private func respond(stem: String, id: String, outcome: BrowserRPCOutcome) {
        var body: [String: Any] = ["id": id]
        switch outcome {
        case .ok(let result):
            body["ok"] = true
            body["result"] = result
        case .failure(let message):
            body["ok"] = false
            body["error"] = message
            dbg("browser: [req \(stem.prefix(8))] failed — \(message)")
        }
        if let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) {
            Self.atomicWrite(data, to: Self.rpcDir + "/" + stem + ".res.json")
        }
        // Response first, request second: the MCP side must never see the
        // request gone with no answer beside it.
        try? FileManager.default.removeItem(atPath: Self.rpcDir + "/" + stem + ".req.json")
        inflight.remove(stem)
    }

    private func execute(action: String, params: [String: Any],
                         done: @escaping (BrowserRPCOutcome) -> Void) {
        switch action {
        case "tabs":
            done(.ok(["tabs": tabs.map {
                ["id": $0.id.uuidString, "url": $0.url, "title": $0.title,
                 "active": $0.id == activeTabId]
            }]))

        case "open":
            guard let url = Self.str(params, "url") else { return done(.failure("open needs a url")) }
            let id = open(url, newTab: Self.bool(params, "newTab", default: true))
            requestVisible()
            // Every path has to reach `done` — a request that never answers is
            // never deleted either, so it would sit in the spool forever.
            guard let page = page(for: id) else { return done(.failure(Self.noTabError)) }
            // Resolve on didFinish so an `open` followed by a `read` needs no
            // sleep on the caller's side.
            page.waitForLoad { done(.ok(["id": id.uuidString, "url": $0])) }

        case "activate":
            guard let id = Self.uuid(params, "id"), tabs.contains(where: { $0.id == id }) else {
                return done(.failure(Self.noTabError))
            }
            activeTabId = id
            requestVisible()
            done(.ok(["id": id.uuidString]))

        case "close":
            guard let id = Self.uuid(params, "id"), tabs.contains(where: { $0.id == id }) else {
                return done(.failure(Self.noTabError))
            }
            close(id)
            done(.ok(["closed": id.uuidString]))

        case "navigate":
            guard let url = Self.str(params, "url") else { return done(.failure("navigate needs a url")) }
            guard let id = resolve(params), let page = page(for: id) else {
                return done(.failure(Self.noTabError))
            }
            navigate(id, to: url)
            requestVisible()
            page.waitForLoad { done(.ok(["id": id.uuidString, "url": $0])) }

        case "back", "forward", "reload":
            guard let id = resolve(params), let page = page(for: id) else {
                return done(.failure(Self.noTabError))
            }
            switch action {
            case "back":
                guard page.webView.canGoBack else { return done(.failure("nothing to go back to")) }
                page.webView.goBack()
            case "forward":
                guard page.webView.canGoForward else { return done(.failure("nothing to go forward to")) }
                page.webView.goForward()
            default:
                page.webView.reload()
            }
            requestVisible()
            page.waitForLoad { done(.ok(["url": $0])) }

        case "read":
            guard let id = resolve(params), let page = page(for: id) else {
                return done(.failure(Self.noTabError))
            }
            let html = (Self.str(params, "format") ?? "text").lowercased() == "html"
            let maxChars = max(200, min(2_000_000, Self.num(params, "maxChars") ?? 60_000))
            let js = html
                ? "document.documentElement ? document.documentElement.outerHTML : ''"
                : "(document.body || document.documentElement || {}).innerText || ''"
            page.webView.evaluateJavaScript(js) { value, error in
                if let error { return done(.failure("read failed — \(error.localizedDescription)")) }
                let full = value as? String ?? ""
                let truncated = full.count > maxChars
                let content = truncated
                    ? String(full.prefix(maxChars)) + "\n… [truncated at \(maxChars) chars]"
                    : full
                done(.ok(["url": page.currentURL, "title": page.webView.title ?? "",
                          "format": html ? "html" : "text",
                          "content": content, "truncated": truncated]))
            }

        case "click":
            guard Self.allowClaudeWrites else { return done(.failure(Self.writesDisabled)) }
            guard let id = resolve(params), let page = page(for: id) else {
                return done(.failure(Self.noTabError))
            }
            let selector = Self.str(params, "selector")
            let text = Self.str(params, "text")
            guard selector != nil || text != nil else {
                return done(.failure("click needs a selector or text"))
            }
            let what = selector.map { "selector \($0)" } ?? "visible text \"\(text ?? "")\""
            page.webView.evaluateJavaScript(Self.clickJS(selector: selector, text: text)) { value, error in
                if let error { return done(.failure("click failed — \(error.localizedDescription)")) }
                // A miss is an error with the target echoed back, never a silent
                // success — an agent that believes it clicked reads the wrong page.
                guard let matched = value as? String else {
                    return done(.failure("nothing matched \(what)"))
                }
                self.settle(page) { done(.ok(["hit": true, "matched": matched])) }
            }

        case "type":
            guard Self.allowClaudeWrites else { return done(.failure(Self.writesDisabled)) }
            guard let selector = Self.str(params, "selector") else {
                return done(.failure("type needs a selector"))
            }
            guard let id = resolve(params), let page = page(for: id) else {
                return done(.failure(Self.noTabError))
            }
            let text = params["text"] as? String ?? ""
            let submit = Self.bool(params, "submit", default: false)
            let js = Self.typeJS(selector: selector, text: text, submit: submit)
            page.webView.evaluateJavaScript(js) { value, error in
                if let error { return done(.failure("type failed — \(error.localizedDescription)")) }
                guard let typed = (value as? NSNumber)?.intValue, typed >= 0 else {
                    return done(.failure("nothing matched selector \(selector)"))
                }
                if submit {
                    self.settle(page) { done(.ok(["typed": typed])) }
                } else {
                    done(.ok(["typed": typed]))
                }
            }

        case "eval":
            guard Self.allowClaudeWrites else { return done(.failure(Self.writesDisabled)) }
            guard let js = Self.str(params, "js") else { return done(.failure("eval needs js")) }
            guard let id = resolve(params), let page = page(for: id) else {
                return done(.failure(Self.noTabError))
            }
            page.webView.evaluateJavaScript(js) { value, error in
                if let error { return done(.failure("eval failed — \(error.localizedDescription)")) }
                done(.ok(["value": String(Self.jsonFragment(value).prefix(20_000))]))
            }

        case "screenshot":
            guard let id = resolve(params), let page = page(for: id) else {
                return done(.failure(Self.noTabError))
            }
            let fullPage = Self.bool(params, "fullPage", default: false)
            // Unlike `read`, this one does need the panel up: a web view that
            // isn't in a window has nothing rendered to capture.
            requestVisible()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.capture(page, fullPage: fullPage, done: done)
            }

        case "wait":
            guard let id = resolve(params), let page = page(for: id) else {
                return done(.failure(Self.noTabError))
            }
            let ms = min(15_000, max(0, Self.num(params, "ms") ?? 1_000))
            guard let selector = Self.str(params, "selector") else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(ms) / 1000) {
                    done(.ok(["found": true, "waitedMs": ms]))
                }
                return
            }
            pollFor(selector: selector, in: page, deadlineMs: ms, waitedMs: 0, done: done)

        default:
            done(.failure("unknown action \"\(action)\""))
        }
    }

    /// `id` defaults to the active tab — that is what makes the param optional
    /// on nearly every action.
    private func resolve(_ params: [String: Any]) -> UUID? {
        if let explicit = Self.uuid(params, "id") {
            return tabs.contains(where: { $0.id == explicit }) ? explicit : nil
        }
        if let active = activeTabId, tabs.contains(where: { $0.id == active }) { return active }
        return tabs.first?.id
    }

    /// The panel has to be on screen for this action to mean anything. The app
    /// shell owns `isBrowserVisible`, so ask rather than reach for it.
    private func requestVisible() {
        NotificationCenter.default.post(name: .floatnoteBrowserRequestedVisible,
                                        object: activeTabId)
    }

    /// After a click or a form submit, answer once whatever navigation it
    /// started has landed — otherwise the caller's next `read` races the old
    /// document. Nothing started? Answer immediately.
    private func settle(_ page: BrowserPage, then done: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if page.webView.isLoading {
                page.waitForLoad { _ in done() }
            } else {
                done()
            }
        }
    }

    /// Poll for a selector rather than injecting a MutationObserver: the page
    /// may navigate mid-wait, which would take the observer with it. An
    /// evaluation error (a bad selector, a document swapped under us) counts as
    /// "not yet" and lands as `found: false` at the deadline — the spec's shape
    /// for a wait that times out.
    private func pollFor(selector: String, in page: BrowserPage,
                         deadlineMs: Int, waitedMs: Int,
                         done: @escaping (BrowserRPCOutcome) -> Void) {
        let js = "!!document.querySelector(\(Self.jsLiteral(selector)))"
        page.webView.evaluateJavaScript(js) { value, _ in
            if (value as? Bool) == true {
                return done(.ok(["found": true, "waitedMs": waitedMs]))
            }
            guard waitedMs < deadlineMs else {
                return done(.ok(["found": false, "waitedMs": waitedMs]))
            }
            let step = min(100, deadlineMs - waitedMs)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) / 1000) {
                self.pollFor(selector: selector, in: page, deadlineMs: deadlineMs,
                             waitedMs: waitedMs + step, done: done)
            }
        }
    }

    // MARK: Screenshots

    private func capture(_ page: BrowserPage, fullPage: Bool,
                         done: @escaping (BrowserRPCOutcome) -> Void) {
        let webView = page.webView
        guard fullPage else {
            webView.takeSnapshot(with: nil) { image, error in
                self.finishCapture(image, error: error, page: page, done: done)
            }
            return
        }
        webView.evaluateJavaScript("document.documentElement.scrollHeight") { value, _ in
            let reported = CGFloat((value as? NSNumber)?.doubleValue ?? 0)
            // Width stays the panel's, so the capture matches the layout the
            // user is looking at; only the height grows. 12 000pt ceiling
            // because an infinite-scroll page reports a height that would
            // allocate gigabytes of bitmap.
            let width = max(320, webView.bounds.width)
            let height = min(12_000, max(webView.bounds.height, reported))
            self.fullPageSnapshot(page, size: CGSize(width: width, height: height)) { image, error in
                self.finishCapture(image, error: error, page: page, done: done)
            }
        }
    }

    /// Full-page capture means the web view has to *be* that tall for a moment:
    /// `WKSnapshotConfiguration.rect` can't reach content below the fold. The
    /// container clips its subviews (see `BrowserWebContainer`), so the oversize
    /// view never flashes over the rest of the window.
    private func fullPageSnapshot(_ page: BrowserPage, size: CGSize,
                                  done: @escaping (NSImage?, Error?) -> Void) {
        let webView = page.webView
        let container = webView.superview
        let savedFrame = webView.frame
        let pinned = container?.constraints.filter {
            $0.firstItem === webView || $0.secondItem === webView
        } ?? []
        NSLayoutConstraint.deactivate(pinned)
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = CGRect(origin: .zero, size: size)
        webView.layoutSubtreeIfNeeded()
        // WebKit needs a beat to paint the part of the page that was off-screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: size)
            webView.takeSnapshot(with: config) { image, error in
                webView.frame = savedFrame
                webView.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate(pinned)
                container?.layoutSubtreeIfNeeded()
                done(image, error)
            }
        }
    }

    private func finishCapture(_ image: NSImage?, error: Error?, page: BrowserPage,
                               done: @escaping (BrowserRPCOutcome) -> Void) {
        guard let image else {
            return done(.failure("screenshot failed — \(error?.localizedDescription ?? "no image")"))
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return done(.failure("screenshot failed — could not encode PNG"))
        }
        try? FileManager.default.createDirectory(atPath: Self.shotsDir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let path = Self.shotsDir + "/shot-\(stamp)-\(page.id.uuidString.prefix(8)).png"
        guard Self.atomicWrite(png, to: path) else {
            return done(.failure("screenshot failed — could not write \(path)"))
        }
        done(.ok(["path": path]))
    }

    // MARK: Param + JS helpers

    private static func str(_ params: [String: Any], _ key: String) -> String? {
        guard let value = params[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func num(_ params: [String: Any], _ key: String) -> Int? {
        if let n = params[key] as? NSNumber { return n.intValue }
        if let s = params[key] as? String { return Int(s) }
        return nil
    }

    private static func bool(_ params: [String: Any], _ key: String, default fallback: Bool) -> Bool {
        if let n = params[key] as? NSNumber { return n.boolValue }
        if let s = params[key] as? String { return s == "true" || s == "1" }
        return fallback
    }

    private static func uuid(_ params: [String: Any], _ key: String) -> UUID? {
        guard let raw = params[key] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    /// One log line per request has to fit on a line: values are trimmed, not
    /// dropped, so a `type` with a long body still shows what field it went to.
    private static func summarize(_ params: [String: Any]) -> String {
        params.keys.sorted().map { key in
            let raw = String(describing: params[key] ?? "")
                .replacingOccurrences(of: "\n", with: " ")
            return "\(key)=\(raw.count > 60 ? String(raw.prefix(60)) + "…" : raw)"
        }.joined(separator: " ")
    }

    /// Params reach the page as JS *literals*, never as interpolated source —
    /// a selector containing a quote would otherwise rewrite the script.
    private static func jsLiteral(_ value: String?) -> String {
        guard let value else { return "null" }
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }

    /// `eval` returns whatever the page produced, JSON-encoded. Values WebKit
    /// bridges outside JSON's vocabulary (a `Date`, say) fall back to their
    /// description rather than failing the call.
    private static func jsonFragment(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    /// `querySelector` when a selector is given, else a case-insensitive
    /// *visible*-text match over the things a person could actually click. The
    /// visibility test matters: pages keep hidden duplicates of their nav, and
    /// clicking one does nothing at all.
    private static func clickJS(selector: String?, text: String?) -> String {
        """
        (function() {
          var sel = \(jsLiteral(selector));
          var wanted = \(jsLiteral(text));
          function label(el) {
            var t = el.innerText || el.value || el.getAttribute('aria-label') || el.title || '';
            return String(t).replace(/\\s+/g, ' ').trim();
          }
          function visible(el) {
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          var el = null;
          if (sel) {
            el = document.querySelector(sel);
          } else if (wanted) {
            var needle = wanted.toLowerCase();
            var nodes = document.querySelectorAll('a, button, [role=button], input[type=submit], summary, [onclick]');
            for (var i = 0; i < nodes.length; i++) {
              if (!visible(nodes[i])) continue;
              if (label(nodes[i]).toLowerCase().indexOf(needle) !== -1) { el = nodes[i]; break; }
            }
          }
          if (!el) return null;
          el.scrollIntoView({ block: 'center' });
          if (el.focus) el.focus();
          el.click();
          return ((el.tagName || '').toLowerCase() + ' ' + label(el).slice(0, 80)).trim();
        })()
        """
    }

    /// -1 means nothing matched, which the caller turns into an error. The
    /// native value setter is used in preference to `el.value =` because React
    /// (and friends) track that setter to notice a change — assigning the
    /// property directly types text the framework never sees.
    private static func typeJS(selector: String, text: String, submit: Bool) -> String {
        """
        (function() {
          var el = document.querySelector(\(jsLiteral(selector)));
          if (!el) return -1;
          var txt = \(jsLiteral(text));
          if (el.focus) el.focus();
          if ('value' in el) {
            var proto = (el.tagName === 'TEXTAREA') ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            var desc = Object.getOwnPropertyDescriptor(proto, 'value');
            if (desc && desc.set) { desc.set.call(el, txt); } else { el.value = txt; }
          } else {
            el.textContent = txt;
          }
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          if (\(submit ? "true" : "false")) {
            var opts = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true };
            el.dispatchEvent(new KeyboardEvent('keydown', opts));
            el.dispatchEvent(new KeyboardEvent('keyup', opts));
            var form = el.form || (el.closest ? el.closest('form') : null);
            if (form) { if (form.requestSubmit) { form.requestSubmit(); } else { form.submit(); } }
          }
          return txt.length;
        })()
        """
    }

    /// Temp + rename, the app-wide rule: the reader on the other side is a
    /// separate process polling the directory, and an in-place write is a file
    /// it can catch half-finished (or one that fails silently under sandbox).
    @discardableResult
    static func atomicWrite(_ data: Data, to path: String) -> Bool {
        let tmp = path + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmp))
            if FileManager.default.fileExists(atPath: path) {
                _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                          withItemAt: URL(fileURLWithPath: tmp))
            } else {
                try FileManager.default.moveItem(atPath: tmp, toPath: path)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            dbg("browser: write failed \(path) — \(error)")
            return false
        }
    }
}

// MARK: - Page

/// One page: its `WKWebView`, its delegates, and the load-completion waiters the
/// RPC resolves on. Retained by `BrowserSessions`, never by a SwiftUI view.
final class BrowserPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: UUID
    let webView: WKWebView
    private weak var sessions: BrowserSessions?
    /// Callbacks waiting for the current navigation to land, keyed so each one's
    /// own timeout can drop it without disturbing the others.
    private var waiters: [UUID: (String) -> Void] = [:]
    private var observations: [NSKeyValueObservation] = []

    init(id: UUID, sessions: BrowserSessions) {
        self.id = id
        self.sessions = sessions
        let config = WKWebViewConfiguration()
        config.websiteDataStore = BrowserSessions.dataStore()
        // Without this, `window.open` from a script is dropped before
        // `createWebViewWith` is ever consulted.
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // nil = WebKit's own Safari UA. A custom one gets served the
        // "unsupported browser" page, which is the last thing an agent reading
        // the DOM needs.
        webView.customUserAgent = nil
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        observe()
    }

    deinit { observations.forEach { $0.invalidate() } }

    /// KVO rather than delegate callbacks: progress and title change many times
    /// per navigation and have no delegate at all.
    private func observe() {
        let push: () -> Void = { [weak self] in
            guard let self else { return }
            self.sessions?.pageChanged(self.id)
        }
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { _, _ in push() },
            webView.observe(\.isLoading, options: [.new]) { _, _ in push() },
            webView.observe(\.title, options: [.new]) { _, _ in push() },
            webView.observe(\.url, options: [.new]) { _, _ in push() },
            webView.observe(\.canGoBack, options: [.new]) { _, _ in push() },
            webView.observe(\.canGoForward, options: [.new]) { _, _ in push() },
        ]
    }

    var currentURL: String { webView.url?.absoluteString ?? "" }
    /// Where the last `load` was headed, so a completion for the view's own
    /// initial empty document can be told apart from the one being waited on.
    private var pendingTarget: String?

    func load(_ raw: String) {
        guard let url = URL(string: BrowserSessions.resolveInput(raw)) else { return }
        pendingTarget = url.absoluteString
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// Call `done` when the page settles, with the URL it settled on. The
    /// ceiling matters: a page that never finishes (a stalled socket, an
    /// endless stream) would otherwise leave the MCP call hanging until its own
    /// timeout, with no answer file ever written.
    func waitForLoad(timeout: TimeInterval = 15, _ done: @escaping (String) -> Void) {
        let token = UUID()
        waiters[token] = done
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, let waiter = self.waiters.removeValue(forKey: token) else { return }
            waiter(self.currentURL)
        }
    }

    private func finishWaiters() {
        // A freshly created web view finishes its own empty document moments
        // after creation, and that completion used to answer the `open` that
        // had just started the real navigation — so the caller was told it had
        // opened "about:blank" while the page it asked for was still in flight.
        if let target = pendingTarget, target != "about:blank", currentURL == "about:blank" { return }
        pendingTarget = nil
        let pending = waiters
        waiters.removeAll()
        let url = currentURL
        for waiter in pending.values { waiter(url) }
    }

    /// Drop the page for good (tab closed, or the data store changed under us).
    func detach() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        finishWaiters()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        sessions?.pageChanged(id)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sessions?.pageChanged(id)
        finishWaiters()
    }

    /// A failed navigation still ends the wait — an RPC caller needs the answer
    /// "this is where we ended up", not a timeout.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        dbg("browser: load failed — \(error.localizedDescription)")
        finishWaiters()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        dbg("browser: load failed — \(error.localizedDescription)")
        finishWaiters()
    }

    // MARK: WKUIDelegate

    /// `target=_blank` / `window.open()`. Returning nil without doing anything
    /// drops the request silently, so give it a tab — the panel has no second
    /// window to hand it.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            sessions?.open(url.absoluteString, newTab: true)
        }
        return nil
    }
}

extension Notification.Name {
    /// An RPC action needs the browser panel on screen (the app shell owns
    /// `isBrowserVisible`, so `BrowserSessions` asks instead of reaching for
    /// it). Object = the tab the action targets, when there is one.
    static let floatnoteBrowserRequestedVisible =
        Notification.Name("floatnote.browser.requestedVisible")
}

// MARK: - Page host

/// Thin SwiftUI wrapper that displays a page. Like `SwiftTermContainer` it
/// deliberately does NOT create or tear down anything — `BrowserSessions` owns
/// the page lifecycle — so hiding the panel (which dismantles this wrapper)
/// never drops the page, its scroll position or its session.
///
/// `makeNSView` returns a FRESH container each time (SwiftUI doesn't reliably
/// re-display a reused representable view) and re-parents the persistent web
/// view into it.
struct BrowserWebContainer: NSViewRepresentable {
    let id: UUID

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        // Clipping is load-bearing: the full-page screenshot path resizes the
        // web view to the whole document height for a moment, and an NSView
        // doesn't clip its subviews by default — that would flash the oversize
        // page across the rest of the window.
        container.layer?.masksToBounds = true
        BrowserSessions.attach(BrowserSessions.shared.webView(for: id), to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        BrowserSessions.attach(BrowserSessions.shared.webView(for: id), to: nsView)
    }
}

extension BrowserSessions {
    /// Parent `webView` in `container`, filling it. Shared by the representable
    /// and the rebuild-on-profile-change path, which has to swap one web view
    /// for another under a container SwiftUI won't recreate.
    static func attach(_ webView: WKWebView, to container: NSView) {
        guard webView.superview !== container else { return }
        for stale in container.subviews where stale !== webView { stale.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

// MARK: - Panel

/// The browser panel: tab bar, toolbar, page. Painted in the terminal's palette
/// (`TerminalSessions.currentPalette()`) rather than its own colors, so the two
/// right-hand panels read as one surface instead of two apps side by side.
struct BrowserPanel: View {
    @EnvironmentObject var vm: EditorViewModel
    @ObservedObject private var sessions = BrowserSessions.shared
    /// Bumped by `.floatnoteTerminalPaletteChanged` purely to re-evaluate the
    /// body — the palette lives in `TerminalSessions`, not in SwiftUI state.
    @State private var paletteGeneration = 0
    @State private var urlText = ""
    @FocusState private var urlFocused: Bool

    private var palette: TerminalPalette {
        _ = paletteGeneration
        return TerminalSessions.currentPalette()
    }

    private var activeTab: BrowserTab? {
        guard let id = sessions.activeTabId else { return nil }
        return sessions.tabs.first { $0.id == id }
    }

    private var state: BrowserPageState {
        sessions.activeTabId.flatMap { sessions.states[$0] } ?? BrowserPageState()
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            toolbar
            progressBar
            if let tab = activeTab {
                BrowserWebContainer(id: tab.id)
                    .id(tab.id)
                    .background(palette.backgroundColor)
            } else {
                palette.backgroundColor
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .floatnoteTerminalPaletteChanged)) { _ in
            paletteGeneration &+= 1
        }
        .onAppear { syncURLField() }
        .onChange(of: sessions.activeTabId) { _, _ in syncURLField() }
        // The page's own navigations (a redirect, a link, an RPC `open`) have to
        // reach the field too — it is the only place the current URL is shown.
        .onChange(of: activeTab?.url) { _, _ in syncURLField() }
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(sessions.tabs) { tab in
                tabChip(tab)
                Divider().frame(height: 20)
            }
            Button(action: { _ = sessions.newTab() }) {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .frame(width: 30, height: 28)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("New tab")
            Spacer(minLength: 0)
        }
        .background(vm.theme.chromeBackground)
    }

    private func tabChip(_ tab: BrowserTab) -> some View {
        let isActive = sessions.activeTabId == tab.id
        // The active chip reads as the top edge of the page below it, so it is
        // painted in the page surface's colors — same reasoning as the terminal
        // chips, and the same trap avoided (a hardcoded slab leaves the label
        // invisible under one of the two themes).
        let onSurface = palette.foregroundColor
        return HStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isActive ? .accentColor : .secondary)
            Text(tab.displayName)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? onSurface : .secondary)
                .lineLimit(1)
            Button(action: { withAnimation(.easeInOut(duration: 0.18)) { sessions.close(tab.id) } }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundColor(isActive ? onSurface.opacity(0.6) : .secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Close this tab")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: 180)
        .background(isActive ? palette.backgroundColor : Color.clear)
        .overlay(alignment: .top) {
            if isActive { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { sessions.activeTabId = tab.id }
        .help(tab.url)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 2) {
            navButton("chevron.left", help: "Back", enabled: state.canGoBack) {
                if let id = sessions.activeTabId { sessions.back(id) }
            }
            navButton("chevron.right", help: "Forward", enabled: state.canGoForward) {
                if let id = sessions.activeTabId { sessions.forward(id) }
            }
            navButton(state.isLoading ? "xmark" : "arrow.clockwise",
                      help: state.isLoading ? "Stop" : "Reload",
                      enabled: activeTab != nil) {
                guard let id = sessions.activeTabId else { return }
                if state.isLoading { sessions.stop(id) } else { sessions.reload(id) }
            }
            TextField("Search or enter address", text: $urlText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(palette.foregroundColor)
                .focused($urlFocused)
                .onSubmit { commitURL() }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(palette.backgroundColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(palette.foregroundColor.opacity(urlFocused ? 0.35 : 0.15))
                        )
                )
            navButton("arrow.up.forward.app", help: "Open in default browser",
                      enabled: activeTab != nil) {
                openExternally()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(vm.theme.chromeBackground)
    }

    private func navButton(_ symbol: String, help: String, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 24)
                .foregroundColor(enabled ? palette.foregroundColor.opacity(0.8)
                                         : Color.secondary.opacity(0.4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    /// A hairline, the way every browser signals "still fetching". The panel has
    /// nowhere else to say it — the page itself is often blank while loading.
    private var progressBar: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geo.size.width * CGFloat(max(0.02, state.progress)))
        }
        .frame(height: 2)
        .opacity(state.isLoading ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: state.progress)
        .animation(.easeOut(duration: 0.2), value: state.isLoading)
    }

    // MARK: Address field

    /// Never clobber what the user is typing — the field is also a live readout
    /// of the page's URL, and the page keeps navigating while they type.
    private func syncURLField() {
        guard !urlFocused else { return }
        let url = activeTab?.url ?? ""
        urlText = url == "about:blank" ? "" : url
    }

    private func commitURL() {
        let target = BrowserSessions.resolveInput(urlText)
        if let id = sessions.activeTabId {
            sessions.navigate(id, to: target)
        } else {
            sessions.open(target, newTab: true)
        }
        urlFocused = false
    }

    private func openExternally() {
        guard let raw = activeTab?.url, raw != "about:blank",
              let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Resize handle

/// The terminal↔browser boundary handle — same shape as `TerminalResizeHandle`,
/// adjusting `vm.browserWidth`. Drag-left widens the browser.
struct BrowserResizeHandle: View {
    @EnvironmentObject var vm: EditorViewModel

    @State private var isDragging = false
    @State private var isHovering = false
    @State private var startWidth: CGFloat = 0

    private let minWidth: CGFloat = 280
    private let maxWidth: CGFloat = 1600
    private let hitWidth: CGFloat = 10
    /// Room the editor keeps no matter what the drag asks for. A panel that ate
    /// the note would also eat the handle you'd drag back with.
    private let editorFloor: CGFloat = 200

    /// `availableBrowserWidth()` is the same number the panel is rendered at, so
    /// the drag can't run past the point where it stops having any visible
    /// effect. NOT `availablePanelWidth()` — that one subtracts *this* panel's
    /// width, so the cap would shrink as the drag grew it and fight the gesture.
    private var widthCap: CGFloat {
        min(maxWidth, max(minWidth, vm.availableBrowserWidth() - editorFloor))
    }

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
                    if !isDragging { isDragging = true; startWidth = vm.browserWidth }
                    // Drag-left → wider (subtract dx); cap to the window.
                    vm.browserWidth = min(widthCap, max(minWidth, startWidth - value.translation.width))
                }
                .onEnded { _ in isDragging = false }
        )
    }
}
