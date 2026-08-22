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

/// A viewport to render the page in, the way Chrome DevTools' device toolbar
/// does it: a fixed CSS pixel size plus the user agent that goes with it.
///
/// Both halves matter. The size alone shows you the layout at that width; the
/// user agent is what makes a server send its mobile page in the first place, so
/// switching device reloads the tab.
struct BrowserDevice: Identifiable, Equatable {
    let name: String
    let width: CGFloat
    let height: CGFloat
    /// nil = leave the platform default (a Mac Safari UA) alone.
    let userAgent: String?
    /// `.responsive` fills the panel instead of pinning a width.
    var isResponsive: Bool { width == 0 }

    var id: String { name }
    var label: String { isResponsive ? name : "\(name) · \(Int(width))×\(Int(height))" }

    static let iPhoneUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    static let iPadUA = "Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    static let androidUA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36"

    static let responsive = BrowserDevice(name: "Responsive", width: 0, height: 0, userAgent: nil)

    /// Sizes are the CSS viewports these devices actually report, not their
    /// hardware pixels — a 393pt iPhone 15 is a 1179px screen.
    static let all: [BrowserDevice] = [
        responsive,
        BrowserDevice(name: "iPhone SE", width: 375, height: 667, userAgent: iPhoneUA),
        BrowserDevice(name: "iPhone 15", width: 393, height: 852, userAgent: iPhoneUA),
        BrowserDevice(name: "iPhone 15 Pro Max", width: 430, height: 932, userAgent: iPhoneUA),
        BrowserDevice(name: "Pixel 8", width: 412, height: 915, userAgent: androidUA),
        BrowserDevice(name: "Galaxy S24", width: 360, height: 780, userAgent: androidUA),
        BrowserDevice(name: "iPad mini", width: 744, height: 1133, userAgent: iPadUA),
        BrowserDevice(name: "iPad Pro 11\"", width: 834, height: 1194, userAgent: iPadUA),
        BrowserDevice(name: "Desktop", width: 1440, height: 900, userAgent: nil),
    ]

    static func named(_ name: String) -> BrowserDevice {
        all.first { $0.name == name } ?? responsive
    }
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
    /// The viewport every tab renders in — app-wide, like a DevTools toolbar
    /// setting, because you are checking "the page" and not one tab of it.
    @Published var device: BrowserDevice = BrowserDevice.named(
        UserDefaults.standard.string(forKey: "fn.browserDevice") ?? "Responsive")
    /// Landscape swaps the two axes without needing a preset per orientation.
    @Published var deviceLandscape: Bool = UserDefaults.standard.bool(forKey: "fn.browserDeviceLandscape")

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
                // The annotation tool bar is OUR chrome. It has no business in a
                // picture of the user's page, whoever asked for the picture.
                page.webView.evaluateJavaScript("window.__fnAnn && window.__fnAnn.chrome(false)") { _, _ in
                    self.capture(page, fullPage: fullPage) { outcome in
                        page.webView.evaluateJavaScript("window.__fnAnn && window.__fnAnn.chrome(true)") { _, _ in }
                        done(outcome)
                    }
                }
            }

        // Annotations: boxes drawn ON the page, in page coordinates, so they
        // scroll with the content and land in every screenshot. Claude adds them
        // to point at something ("this is the fare that flips"); the user draws
        // them with the pane's pencil. Both end up in the same list.
        case "annotate":
            guard Self.allowClaudeWrites else { return done(.failure(Self.writesDisabled)) }
            guard let id = resolve(params), let page = page(for: id) else {
                return done(.failure(Self.noTabError))
            }
            let selector = Self.str(params, "selector")
            let rect = params["rect"] as? [String: Any]
            guard selector != nil || rect != nil else {
                return done(.failure("annotate needs a selector or a rect"))
            }
            var spec: [String: Any] = ["source": "claude"]
            if let selector { spec["selector"] = selector }
            if let rect { spec["rect"] = rect }
            if let note = Self.str(params, "note") { spec["note"] = note }
            if let color = Self.str(params, "color") { spec["color"] = color }
            let call = "window.__fnAnn.add(\(Self.jsonLiteral(spec)))"
            withAnnotations(page, call) { value, error in
                if let error { return done(.failure("annotate failed — \(error)")) }
                guard let json = value as? String, let item = Self.decodeJSON(json) else {
                    return done(.failure(selector.map { "nothing matched selector \($0)" }
                                         ?? "the rect could not be placed"))
                }
                done(.ok(["annotation": item]))
            }

        case "device":
            if let name = Self.str(params, "name") {
                let match = BrowserDevice.all.first {
                    $0.name.lowercased() == name.lowercased()
                        || $0.name.lowercased().contains(name.lowercased())
                }
                guard let match else {
                    let names = BrowserDevice.all.map(\.name).joined(separator: ", ")
                    return done(.failure("no such device \"\(name)\" — try one of: \(names)"))
                }
                setDevice(match, landscape: Self.boolOrNil(params, "landscape") ?? deviceLandscape)
            } else if let landscape = Self.boolOrNil(params, "landscape") {
                setDevice(device, landscape: landscape)
            }
            requestVisible()
            let size = deviceSize
            done(.ok(["name": device.name,
                      "width": size == .zero ? 0 : Int(size.width),
                      "height": size == .zero ? 0 : Int(size.height),
                      "landscape": deviceLandscape,
                      "userAgent": device.userAgent ?? "default (macOS Safari)",
                      "available": BrowserDevice.all.map(\.name)]))

        case "annotations":
            guard let id = resolve(params), let page = page(for: id) else {
                return done(.failure(Self.noTabError))
            }
            withAnnotations(page, "window.__fnAnn.list()") { value, error in
                if let error { return done(.failure("annotations failed — \(error)")) }
                let items = (value as? String).flatMap { Self.decodeJSONArray($0) } ?? []
                done(.ok(["url": page.currentURL, "annotations": items]))
            }

        case "annotate_clear":
            guard Self.allowClaudeWrites else { return done(.failure(Self.writesDisabled)) }
            guard let id = resolve(params), let page = page(for: id) else {
                return done(.failure(Self.noTabError))
            }
            let index = Self.num(params, "index")
            let call = index.map { "window.__fnAnn.clear(\($0))" } ?? "window.__fnAnn.clear()"
            withAnnotations(page, call) { value, error in
                if let error { return done(.failure("annotate_clear failed — \(error)")) }
                done(.ok(["cleared": (value as? NSNumber)?.intValue ?? 0]))
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
    /// Install the annotation runtime (idempotent) and then run `call` against
    /// it. Every annotation action goes through here, so a page that navigated
    /// since the last call still gets a live layer instead of a JS error.
    private func withAnnotations(_ page: BrowserPage, _ call: String,
                                 _ done: @escaping (Any?, String?) -> Void) {
        page.webView.evaluateJavaScript(Self.annotationRuntimeJS) { _, error in
            if let error { return done(nil, error.localizedDescription) }
            page.webView.evaluateJavaScript(call) { value, error in
                done(value, error?.localizedDescription)
            }
        }
    }

    /// Screenshot the annotated page and post it for delivery. Not sent from
    /// here: `BrowserSessions` has no idea which terminal is active, and the
    /// AppDelegate that observes this does.
    func sendAnnotations(tab id: UUID) {
        guard let page = page(for: id) else { return }
        withAnnotations(page, "window.__fnAnn.list()") { [weak self] value, _ in
            guard let self else { return }
            let items = (value as? String).flatMap { Self.decodeJSONArray($0) } ?? []
            // The tool bar is app chrome, not a mark — a screenshot with it in
            // shows Claude a picture of our own UI.
            page.webView.evaluateJavaScript("window.__fnAnn.chrome(false)") { _, _ in
            self.capture(page, fullPage: false) { outcome in
                guard case .ok(let result) = outcome, let path = result["path"] as? String else {
                    dbg("browser: annotation send failed — no screenshot")
                    return
                }
                var lines = ["Screenshot of \(page.currentURL) with my annotations: \(path)"]
                for item in items {
                    let index = (item["index"] as? NSNumber)?.intValue ?? 0
                    let note = (item["note"] as? String) ?? ""
                    let covers = (item["text"] as? String) ?? ""
                    var line = "\(index). \(note.isEmpty ? "(no note)" : note)"
                    if !covers.isEmpty { line += " — covers: \(covers)" }
                    lines.append(line)
                }
                let text = lines.joined(separator: "\n")
                dbg("browser: annotation → terminal (\(items.count) mark(s), \(path))")
                NotificationCenter.default.post(name: .floatnoteBrowserAnnotationReady,
                                                object: nil, userInfo: ["text": text])
                // "Add to chat" ends the markup session: the marks are in the
                // picture that was just sent, so they are wiped, and the tool
                // closes — leaving them up meant the next send carried the same
                // stale drawing, and the pencil stayed armed over a page you
                // were done marking.
                page.webView.evaluateJavaScript("window.__fnAnn.clear(); window.__fnAnn.mode(false)") { _, _ in
                    NotificationCenter.default.post(name: .floatnoteBrowserAnnotateModeOff, object: nil)
                }
            }
            }
        }
    }

    /// The size to render at, honouring orientation. Zero means "fill the panel".
    var deviceSize: CGSize {
        guard !device.isResponsive else { return .zero }
        return deviceLandscape
            ? CGSize(width: device.height, height: device.width)
            : CGSize(width: device.width, height: device.height)
    }

    /// Switch viewport. The user agent goes on every live page and each one
    /// reloads: a site that decides mobile-vs-desktop on the server would
    /// otherwise keep serving what it decided before the switch.
    func setDevice(_ device: BrowserDevice, landscape: Bool? = nil) {
        self.device = device
        if let landscape { deviceLandscape = landscape }
        UserDefaults.standard.set(device.name, forKey: "fn.browserDevice")
        UserDefaults.standard.set(deviceLandscape, forKey: "fn.browserDeviceLandscape")
        for page in pages.values {
            page.webView.customUserAgent = device.userAgent
            if page.currentURL.isEmpty == false, page.currentURL != "about:blank" {
                page.webView.reload()
            }
        }
        dbg("browser: device → \(device.name)\(deviceLandscape ? " (landscape)" : "")")
    }

    /// Turn the pane's pencil on or off for a page (the user-drawn path).
    func setAnnotating(_ on: Bool, tab id: UUID?) {
        guard let id, let page = page(for: id) else { return }
        withAnnotations(page, "window.__fnAnn.mode(\(on))") { _, error in
            if let error { dbg("browser: annotate mode failed — \(error)") }
        }
        dbg("browser: annotate mode \(on ? "on" : "off")")
    }

    /// A dictionary as a JS object literal (valid JSON is valid JS).
    private static func jsonLiteral(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// A bool param that may be absent — `bool(_:default:)` can't say "unset".
    private static func boolOrNil(_ params: [String: Any], _ key: String) -> Bool? {
        (params[key] as? NSNumber)?.boolValue ?? (params[key] as? Bool)
    }

    private static func decodeJSON(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func decodeJSONArray(_ text: String) -> [[String: Any]]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    /// The in-page annotation layer. Lives in the document (not in an AppKit
    /// overlay) for three reasons: `takeSnapshot` captures it for free, the
    /// boxes scroll with the content because they are in page coordinates, and
    /// the same list serves Claude and the user. Navigation clears it — an
    /// annotation is about the page in front of you, not a saved artefact.
    /// The in-page markup layer: pen, line, rectangle, ellipse and text, in four
    /// colours, drawn into one SVG that lives in the document.
    ///
    /// In the document, not in an AppKit overlay, for three reasons: `takeSnapshot`
    /// captures it for free, page coordinates mean the marks scroll with the
    /// content they point at, and the same shape list serves both the person
    /// drawing and Claude reading. Navigation clears it — a mark is about the
    /// page in front of you, not a saved artefact.
    private static let annotationRuntimeJS = """
    (function() {
      if (window.__fnAnn) return 'ok';
      var COLORS = { coral: '#E5484D', blue: '#3B82F6', green: '#22A06B', black: '#111111' };
      var NS = 'http://www.w3.org/2000/svg';
      var doc = document;
      var root = doc.body || doc.documentElement;

      var svg = doc.createElementNS(NS, 'svg');
      svg.setAttribute('id', '__fn_ann_svg');
      svg.style.cssText = 'position:absolute;left:0;top:0;pointer-events:none;z-index:2147483000;overflow:visible;';
      root.appendChild(svg);

      var api = { shapes: [], seq: 0, drawing: false, tool: 'pen', color: 'coral' };

      function docSize() {
        var d = doc.documentElement, b = doc.body || d;
        return {
          w: Math.max(d.scrollWidth, b.scrollWidth, window.innerWidth),
          h: Math.max(d.scrollHeight, b.scrollHeight, window.innerHeight),
        };
      }
      function sizeSVG() {
        var s = docSize();
        svg.setAttribute('width', s.w);
        svg.setAttribute('height', s.h);
        svg.setAttribute('viewBox', '0 0 ' + s.w + ' ' + s.h);
      }
      sizeSVG();

      function hex(name) { return COLORS[name] || COLORS.coral; }

      function bounds(shape) {
        if (shape.kind === 'pen') {
          var xs = shape.points.map(function(p) { return p[0]; });
          var ys = shape.points.map(function(p) { return p[1]; });
          var x = Math.min.apply(null, xs), y = Math.min.apply(null, ys);
          return { x: Math.round(x), y: Math.round(y),
                   w: Math.round(Math.max.apply(null, xs) - x),
                   h: Math.round(Math.max.apply(null, ys) - y) };
        }
        return { x: Math.round(Math.min(shape.x1, shape.x2)), y: Math.round(Math.min(shape.y1, shape.y2)),
                 w: Math.round(Math.abs(shape.x2 - shape.x1)), h: Math.round(Math.abs(shape.y2 - shape.y1)) };
      }

      function textUnder(box) {
        var cx = Math.min(window.innerWidth - 2, Math.max(1, box.x + box.w / 2 - window.scrollX));
        var cy = Math.min(window.innerHeight - 2, Math.max(1, box.y + box.h / 2 - window.scrollY));
        var el = doc.elementFromPoint(cx, cy);
        var t = el ? (el.innerText || el.value || '') : '';
        return String(t).replace(/\\s+/g, ' ').trim().slice(0, 120);
      }

      function draw(shape) {
        var el;
        var stroke = hex(shape.color);
        if (shape.kind === 'pen') {
          el = doc.createElementNS(NS, 'polyline');
          el.setAttribute('points', shape.points.map(function(p) { return p.join(','); }).join(' '));
          el.setAttribute('fill', 'none');
        } else if (shape.kind === 'line') {
          el = doc.createElementNS(NS, 'line');
          el.setAttribute('x1', shape.x1); el.setAttribute('y1', shape.y1);
          el.setAttribute('x2', shape.x2); el.setAttribute('y2', shape.y2);
        } else if (shape.kind === 'ellipse') {
          el = doc.createElementNS(NS, 'ellipse');
          el.setAttribute('cx', (shape.x1 + shape.x2) / 2);
          el.setAttribute('cy', (shape.y1 + shape.y2) / 2);
          el.setAttribute('rx', Math.abs(shape.x2 - shape.x1) / 2);
          el.setAttribute('ry', Math.abs(shape.y2 - shape.y1) / 2);
          el.setAttribute('fill', 'none');
        } else if (shape.kind === 'text') {
          el = doc.createElementNS(NS, 'text');
          el.setAttribute('x', shape.x1); el.setAttribute('y', shape.y1);
          el.setAttribute('fill', stroke);
          el.setAttribute('font-family', '-apple-system, system-ui, sans-serif');
          el.setAttribute('font-size', '17');
          el.setAttribute('font-weight', '600');
          el.textContent = shape.note || '';
        } else {
          var b = bounds(shape);
          el = doc.createElementNS(NS, 'rect');
          el.setAttribute('x', b.x); el.setAttribute('y', b.y);
          el.setAttribute('width', b.w); el.setAttribute('height', b.h);
          el.setAttribute('rx', 4);
          el.setAttribute('fill', 'none');
        }
        if (shape.kind !== 'text') {
          el.setAttribute('stroke', stroke);
          el.setAttribute('stroke-width', 3);
          el.setAttribute('stroke-linecap', 'round');
          el.setAttribute('stroke-linejoin', 'round');
        }
        shape.el = el;
        svg.appendChild(el);
        if (shape.label) {
          var tag = doc.createElementNS(NS, 'text');
          var b2 = bounds(shape);
          tag.setAttribute('x', b2.x);
          tag.setAttribute('y', Math.max(14, b2.y - 6));
          tag.setAttribute('fill', stroke);
          tag.setAttribute('font-family', '-apple-system, system-ui, sans-serif');
          tag.setAttribute('font-size', '13');
          tag.setAttribute('font-weight', '700');
          tag.textContent = shape.label;
          shape.tagEl = tag;
          svg.appendChild(tag);
        }
      }

      function repaint() {
        while (svg.firstChild) svg.removeChild(svg.firstChild);
        sizeSVG();
        api.shapes.forEach(draw);
      }

      // ---- programmatic marks (Claude pointing at something) ----
      api.add = function(spec) {
        var box = spec.rect;
        if (spec.selector) {
          var el = doc.querySelector(spec.selector);
          if (!el) return null;
          el.scrollIntoView({ block: 'center' });
          var r = el.getBoundingClientRect();
          box = { x: r.left + window.scrollX, y: r.top + window.scrollY, w: r.width, h: r.height };
        }
        if (!box || !(box.w > 0) || !(box.h > 0)) return null;
        var shape = {
          index: ++api.seq, kind: 'rect', source: spec.source || 'claude',
          color: COLORS[spec.color] ? spec.color : 'coral',
          x1: box.x, y1: box.y, x2: box.x + box.w, y2: box.y + box.h,
          note: spec.note || '', selector: spec.selector || null,
        };
        shape.label = String(shape.index) + (shape.note ? ' · ' + shape.note : '');
        api.shapes.push(shape);
        repaint();
        return JSON.stringify(api.describe(shape));
      };

      api.describe = function(shape) {
        var b = bounds(shape);
        return { index: shape.index, kind: shape.kind, color: shape.color, note: shape.note || '',
                 selector: shape.selector || null, source: shape.source, rect: b, text: textUnder(b) };
      };

      api.list = function() {
        return JSON.stringify(api.shapes.map(api.describe));
      };

      api.clear = function(index) {
        var before = api.shapes.length;
        api.shapes = index == null ? [] : api.shapes.filter(function(s) { return s.index !== index; });
        repaint();
        return before - api.shapes.length;
      };

      api.setTool = function(t) { api.tool = t; applyCursor(); return api.tool; };
      api.setColor = function(c) { api.color = COLORS[c] ? c : 'coral'; return api.color; };

      // The pointer has to say what mode you are in, and a crosshair says
      // "select", not "draw". Page CSS sets its own cursors on links and
      // buttons, so this goes in as a `!important` rule over everything —
      // except the tool bar, which is chrome and keeps an arrow.
      var cursorStyle = null;
      function cursorFor(tool) {
        if (tool === 'text') return 'text';
        if (tool !== 'pen') return 'crosshair';
        var svg = '<svg xmlns=%22http://www.w3.org/2000/svg%22 width=%2224%22 height=%2224%22 ' +
          'viewBox=%220 0 24 24%22><path d=%22M3 21l4-1 11.5-11.5-3-3L4 17z%22 fill=%22%23ffffff%22 ' +
          'stroke=%22%23111111%22 stroke-width=%221.4%22 stroke-linejoin=%22round%22/>' +
          '<path d=%22M16.2 4.9l2.9 2.9 1.5-1.5a1.4 1.4 0 0 0 0-2l-.9-.9a1.4 1.4 0 0 0-2 0z%22 ' +
          'fill=%22%23E5484D%22 stroke=%22%23111111%22 stroke-width=%221.2%22/>' +
          '<path d=%22M3 21l1.6-.4-1.2-1.2z%22 fill=%22%23111111%22/></svg>';
        return 'url("data:image/svg+xml;utf8,' + svg + '") 2 22, crosshair';
      }
      function applyCursor() {
        if (!api.drawing) {
          if (cursorStyle) { cursorStyle.remove(); cursorStyle = null; }
          return;
        }
        if (!cursorStyle) {
          cursorStyle = doc.createElement('style');
          cursorStyle.id = '__fn_ann_cursor';
          (doc.head || root).appendChild(cursorStyle);
        }
        cursorStyle.textContent =
          'html, body, *, *::before, *::after { cursor: ' + cursorFor(api.tool) + ' !important; }' +
          '#__fn_ann_bar, #__fn_ann_bar * { cursor: default !important; }';
      }

      // ---- drawing ----
      var live = null;
      function pt(e) { return [Math.round(e.pageX), Math.round(e.pageY)]; }

      function onDown(e) {
        if (!api.drawing || e.button !== 0) return;
        if (e.target.closest && e.target.closest('#__fn_ann_bar')) return;
        e.preventDefault(); e.stopPropagation();
        var p = pt(e);
        if (api.tool === 'text') { promptText(p); return; }
        live = { index: ++api.seq, kind: api.tool, color: api.color, source: 'user',
                 x1: p[0], y1: p[1], x2: p[0], y2: p[1], points: [p], note: '' };
        api.shapes.push(live);
        repaint();
      }
      function onMove(e) {
        if (!live) return;
        e.preventDefault();
        var p = pt(e);
        if (live.kind === 'pen') { live.points.push(p); } else { live.x2 = p[0]; live.y2 = p[1]; }
        repaint();
      }
      function onUp(e) {
        if (!live) return;
        e.preventDefault(); e.stopPropagation();
        var b = bounds(live);
        var trivial = live.kind === 'pen' ? live.points.length < 3 : (b.w < 6 && b.h < 6);
        if (trivial) { api.shapes.pop(); }
        live = null;
        repaint();
      }

      function promptText(p) {
        var input = doc.createElement('input');
        input.placeholder = 'text, then Enter';
        input.style.cssText = 'position:absolute;left:' + p[0] + 'px;top:' + p[1] +
          'px;z-index:2147483002;font:15px -apple-system,system-ui,sans-serif;padding:4px 6px;' +
          'border:2px solid ' + hex(api.color) + ';border-radius:5px;background:#fff;color:#111;min-width:180px;';
        root.appendChild(input);
        input.focus();
        input.addEventListener('keydown', function(ev) {
          ev.stopPropagation();
          if (ev.key === 'Enter') {
            var value = input.value.trim();
            input.remove();
            if (!value) return;
            api.shapes.push({ index: ++api.seq, kind: 'text', color: api.color, source: 'user',
                              x1: p[0], y1: p[1], x2: p[0] + 8 * value.length, y2: p[1] + 18,
                              points: [p], note: value });
            repaint();
          } else if (ev.key === 'Escape') {
            input.remove();
          }
        }, true);
      }

      doc.addEventListener('mousedown', onDown, true);
      doc.addEventListener('mousemove', onMove, true);
      doc.addEventListener('mouseup', onUp, true);
      window.addEventListener('resize', repaint);

      // ---- the floating tool bar, in the page so it follows the viewport ----
      var bar = null;
      function buildBar() {
        if (bar) return;
        bar = doc.createElement('div');
        bar.id = '__fn_ann_bar';
        bar.style.cssText = 'position:fixed;left:50%;bottom:16px;transform:translateX(-50%);' +
          'z-index:2147483003;display:flex;align-items:center;gap:6px;padding:7px 10px;border-radius:11px;' +
          'background:rgba(28,28,30,0.94);box-shadow:0 6px 24px rgba(0,0,0,0.35);' +
          'font:600 12px -apple-system,system-ui,sans-serif;';
        var tools = [['pen', '✎'], ['line', '╱'], ['rect', '▢'], ['ellipse', '◯'], ['text', 'T']];
        tools.forEach(function(t) {
          var b = doc.createElement('button');
          b.textContent = t[1];
          b.dataset.tool = t[0];
          b.style.cssText = btnCSS(api.tool === t[0]);
          b.onclick = function(e) { e.stopPropagation(); api.setTool(t[0]); syncBar(); };
          bar.appendChild(b);
        });
        var sep = doc.createElement('div');
        sep.style.cssText = 'width:1px;height:18px;background:rgba(255,255,255,0.22);margin:0 2px;';
        bar.appendChild(sep);
        Object.keys(COLORS).forEach(function(name) {
          var dot = doc.createElement('button');
          dot.dataset.color = name;
          // flex:none + box-sizing, or the flex row shrinks the width and the
          // 2px selection ring grows the height — which is how a swatch ends up
          // an oval instead of a dot. -webkit-appearance:none drops the
          // platform button chrome that distorts it further.
          dot.style.cssText = 'width:18px;height:18px;flex:0 0 18px;box-sizing:border-box;' +
            'border-radius:50%;border:2px solid transparent;padding:0;margin:0;' +
            '-webkit-appearance:none;appearance:none;background:' + COLORS[name] + ';cursor:pointer;';
          dot.onclick = function(e) { e.stopPropagation(); api.setColor(name); syncBar(); };
          bar.appendChild(dot);
        });
        var trash = doc.createElement('button');
        trash.textContent = '🗑';
        trash.style.cssText = btnCSS(false);
        trash.onclick = function(e) { e.stopPropagation(); api.clear(); };
        bar.appendChild(trash);
        var close = doc.createElement('button');
        close.textContent = 'Close';
        close.style.cssText = btnCSS(false) + 'padding:3px 8px;';
        close.onclick = function(e) {
          e.stopPropagation();
          api.mode(false);
          post({ type: 'annotationMode', on: false });
        };
        bar.appendChild(close);
        var send = doc.createElement('button');
        send.textContent = 'Add to chat';
        send.style.cssText = 'background:#E5E4DF;color:#111;border:0;border-radius:7px;padding:4px 9px;' +
          'font:600 12px -apple-system,system-ui,sans-serif;cursor:pointer;';
        send.onclick = function(e) { e.stopPropagation(); post({ type: 'annotation', send: true }); };
        bar.appendChild(send);
        root.appendChild(bar);
      }
      function btnCSS(active) {
        return 'background:' + (active ? 'rgba(255,255,255,0.22)' : 'transparent') +
          ';color:#fff;border:0;border-radius:6px;min-width:24px;height:22px;cursor:pointer;' +
          'flex:0 0 auto;box-sizing:border-box;-webkit-appearance:none;appearance:none;' +
          'font:600 13px -apple-system,system-ui,sans-serif;padding:0 4px;';
      }
      function syncBar() {
        if (!bar) return;
        Array.prototype.forEach.call(bar.querySelectorAll('button[data-tool]'), function(b) {
          b.style.cssText = btnCSS(b.dataset.tool === api.tool);
        });
        Array.prototype.forEach.call(bar.querySelectorAll('button[data-color]'), function(b) {
          b.style.borderColor = b.dataset.color === api.color ? '#fff' : 'transparent';
        });
      }
      function post(msg) {
        try { window.webkit.messageHandlers.floatnote.postMessage(msg); } catch (e) {}
      }

      api.mode = function(on) {
        api.drawing = !!on;
        svg.style.pointerEvents = 'none';   // the SVG never eats clicks; the doc listeners do the work
        applyCursor();
        if (on) { buildBar(); syncBar(); bar.style.display = 'flex'; }
        else if (bar) { bar.style.display = 'none'; }
        return api.drawing;
      };

      /// Hide the tool bar for a screenshot: it is app chrome, not a mark.
      api.chrome = function(on) {
        if (bar) bar.style.display = on && api.drawing ? 'flex' : 'none';
        return true;
      };

      window.__fnAnn = api;
      return 'ok';
    })()
    """

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
final class BrowserPage: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
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
        // The annotation layer talks back through this: the moment a mark is
        // finished in the page, Swift hears about it and can ship the picture.
        let bridge = WKUserContentController()
        config.userContentController = bridge
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        bridge.add(self, name: "floatnote")
        webView.navigationDelegate = self
        // A tab opened while a device is selected has to start in that device,
        // not inherit the Mac UA until the next switch.
        webView.customUserAgent = sessions.device.userAgent
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

    // MARK: Page-initiated UI
    //
    // WKWebView asks the app to put these on screen and does NOTHING if the
    // delegate stays silent — a file input, an alert, a confirm and a prompt all
    // look like dead buttons in a pane that never implemented them.

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
            dbg("browser: file picker → \(response == .OK ? "\(panel.urls.count) file(s)" : "cancelled")")
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = webView.url?.host ?? "Page"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = webView.url?.host ?? "Page"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = webView.url?.host ?? "Page"
        alert.informativeText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "annotation":
            // "Add to chat": screenshot the page with the marks on it and drop
            // the picture into Claude Code's prompt.
            sessions?.sendAnnotations(tab: id)
        case "annotationMode":
            // The page's own Close button — the pencil in the toolbar has to
            // come back up, and only the panel knows about that.
            NotificationCenter.default.post(name: .floatnoteBrowserAnnotateModeOff, object: nil)
        default:
            break
        }
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
    /// The page asked to leave annotate mode (its own Close button).
    static let floatnoteBrowserAnnotateModeOff =
        Notification.Name("floatnoteBrowserAnnotateModeOff")
    /// An annotated screenshot is ready for whichever terminal is active.
    static let floatnoteBrowserAnnotationReady =
        Notification.Name("floatnoteBrowserAnnotationReady")
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
    /// Pencil state is per panel, not per page: the runtime it drives is
    /// reinstalled on every call, and navigating away drops the layer, so the
    /// button is reset whenever the active tab changes.
    @State private var annotating = false
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
            if !sessions.device.isResponsive { deviceBar }
            if let tab = activeTab {
                page(tab)
            } else {
                palette.backgroundColor
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .floatnoteTerminalPaletteChanged)) { _ in
            paletteGeneration &+= 1
        }
        .onAppear { syncURLField() }
        .onChange(of: sessions.activeTabId) { _, _ in
            syncURLField()
            annotating = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .floatnoteBrowserAnnotateModeOff)) { _ in
            annotating = false
        }
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

    /// The page, at the selected viewport. A device narrower than the panel is
    /// centred on a gutter; a wider one (an iPad in a 500pt panel) scrolls
    /// horizontally rather than being scaled — a scaled viewport reports the
    /// wrong CSS width and stops being an emulation.
    @ViewBuilder
    private func page(_ tab: BrowserTab) -> some View {
        let size = sessions.deviceSize
        if size == .zero {
            BrowserWebContainer(id: tab.id)
                .id(tab.id)
                .background(palette.backgroundColor)
        } else {
            GeometryReader { geo in
                ScrollView(size.width > geo.size.width ? .horizontal : [], showsIndicators: true) {
                    BrowserWebContainer(id: tab.id)
                        .id(tab.id)
                        .frame(width: size.width, height: geo.size.height)
                        .background(Color.white)
                        .shadow(color: .black.opacity(0.25), radius: 6)
                        .frame(minWidth: geo.size.width, alignment: .center)
                }
                .background(palette.backgroundColor.opacity(0.6))
            }
        }
    }

    /// States what you are looking at. Without it a mobile-width page in a wide
    /// panel just looks like a broken site.
    private var deviceBar: some View {
        HStack(spacing: 8) {
            Image(systemName: sessions.device.width >= 700 ? "ipad" : "iphone")
                .font(.system(size: 10))
            Text(sessions.device.label + (sessions.deviceLandscape ? " · landscape" : ""))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
            Spacer()
            Button(action: { sessions.setDevice(sessions.device, landscape: !sessions.deviceLandscape) }) {
                Image(systemName: "rotate.right").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("Rotate")
            Button(action: { sessions.setDevice(.responsive) }) {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .help("Back to the full panel width")
        }
        .foregroundColor(palette.foregroundColor.opacity(0.75))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(vm.theme.chromeBackground)
    }

    /// Buttons are a fixed cost; the field gets what is left. Layout priority
    /// alone did not do it — a `TextField` keeps asking for its ideal width, the
    /// row overflowed the panel and the trailing buttons were simply clipped
    /// away. So the width is measured and handed out explicitly.
    private var toolbar: some View {
        GeometryReader { geo in
            toolbarRow(width: geo.size.width)
        }
        .frame(height: 34)
    }

    /// 7 buttons at 23pt, plus the row's own padding and the gaps around the
    /// field. Kept in one place so adding a button can't silently re-break this.
    private static let toolbarButtonsWidth: CGFloat = 7 * 23 + 26

    private func toolbarRow(width: CGFloat) -> some View {
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
            // The field yields, the buttons don't. Left greedy, it pushed the
            // trailing group off the end of the panel — "open in default
            // browser" simply wasn't there at 500pt wide.
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
                .frame(width: max(56, width - Self.toolbarButtonsWidth))
            // Annotate: drag a box on the page and label it. The same list
            // Claude writes to over MCP, so a mark made here is a mark Claude
            // can read back — that is the point of having it in the pane.
            Button(action: {
                annotating.toggle()
                sessions.setAnnotating(annotating, tab: sessions.activeTabId)
            }) {
                Image(systemName: "pencil.tip.crop.circle")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 23, height: 24)
                    .foregroundColor(annotating ? .accentColor : palette.foregroundColor.opacity(0.8))
            }
            .buttonStyle(.plain)
            .disabled(activeTab == nil)
            .help(annotating ? "Stop annotating" : "Annotate the page — drag a box, type a note")

            HStack(spacing: 0) {
            Button(action: { showDeviceMenu() }) {
                Image(systemName: sessions.device.isResponsive ? "desktopcomputer" : "iphone")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 23, height: 24)
                    .foregroundColor(sessions.device.isResponsive
                                     ? palette.foregroundColor.opacity(0.8) : .accentColor)
            }
            .buttonStyle(.plain)
            .help("Device viewport — mobile, tablet or full width")

            navButton("paperplane", help: "Send this page (with annotations) to Claude",
                      enabled: activeTab != nil) {
                if let id = sessions.activeTabId { sessions.sendAnnotations(tab: id) }
            }
            navButton("arrow.up.forward.app", help: "Open in default browser",
                      enabled: activeTab != nil) {
                openExternally()
            }
            }
            .fixedSize()
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
                .frame(width: 23, height: 24)
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

    /// An `NSMenu`, not a SwiftUI Menu: the list is long, needs a checkmark on
    /// the current entry and a separated rotate item, and the tab bar already
    /// builds its Aa menu this way.
    private func showDeviceMenu() {
        let menu = NSMenu()
        for device in BrowserDevice.all {
            let item = NSMenuItem(title: device.label,
                                  action: #selector(BrowserDeviceMenuTarget.pick(_:)), keyEquivalent: "")
            item.target = BrowserDeviceMenuTarget.shared
            item.representedObject = device.name
            item.state = device.name == sessions.device.name ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let rotate = NSMenuItem(title: "Landscape",
                                action: #selector(BrowserDeviceMenuTarget.rotate(_:)), keyEquivalent: "")
        rotate.target = BrowserDeviceMenuTarget.shared
        rotate.state = sessions.deviceLandscape ? .on : .off
        rotate.isEnabled = !sessions.device.isResponsive
        menu.addItem(rotate)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
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
/// `NSMenuItem` needs an ObjC target; `HandsfreeMenuTarget` exists for the same
/// reason.
final class BrowserDeviceMenuTarget: NSObject {
    static let shared = BrowserDeviceMenuTarget()

    @objc func pick(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        BrowserSessions.shared.setDevice(BrowserDevice.named(name))
    }

    @objc func rotate(_ sender: NSMenuItem) {
        let sessions = BrowserSessions.shared
        sessions.setDevice(sessions.device, landscape: !sessions.deviceLandscape)
    }
}

struct BrowserResizeHandle: View {
    @EnvironmentObject var vm: EditorViewModel

    @State private var isDragging = false
    @State private var isHovering = false
    @State private var startWidth: CGFloat = 0

    private let minWidth: CGFloat = 280
    private let maxWidth: CGFloat = 1600
    private let hitWidth: CGFloat = 10

    /// The ceiling comes from the view model, which knows what the terminal
    /// panel is already using and what the editor must keep. Deriving it here
    /// from this panel's own width would shrink the cap as the drag grew it and
    /// fight the gesture.
    private var widthCap: CGFloat {
        min(maxWidth, max(minWidth, vm.maxBrowserWidth()))
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
                    // Drag-left → wider (subtract dx). The view model does the
                    // clamping AND takes the space out of the terminal panel when
                    // the pair would exceed the window — otherwise the renderer
                    // just scales both back and the drag has no visible effect.
                    vm.setBrowserWidth(min(maxWidth, max(minWidth, startWidth - value.translation.width)))
                }
                .onEnded { _ in isDragging = false }
        )
    }
}
