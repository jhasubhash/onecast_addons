import AppKit
import OnecastPluginKit
import SwiftUI
import WebKit

// MARK: - Plugin

final class GoogleAIModePlugin: NSObject, OnecastPlugin {
    static let metadata = PluginMetadata(
        name: "Google AI Mode", subtitle: "Ask Google's AI Mode inside the launcher",
        icon: "sparkle.magnifyingglass")

    override init() { super.init() }

    func rootSurface(context: PluginContext) -> AnyView? {
        let route = context.route ?? [:]
        if context.presentation == .window {
            guard let id = route[RouteKey.thread].flatMap(UUID.init(uuidString:)) else { return nil }
            return AnyView(ThreadWindowView(threadID: id))
        }
        let start: StartAction
        if let id = route[RouteKey.thread].flatMap(UUID.init(uuidString:)) {
            start = .open(id)
        } else if let query = route[RouteKey.query], !query.isEmpty {
            start = .ask(query)
        } else {
            start = .home
        }
        return AnyView(PaletteSurface(start: start))
    }
}

enum RouteKey {
    static let thread = "thread"
    static let query = "q"
}

enum StartAction: Equatable {
    case home
    case ask(String)
    case open(UUID)
}

@_cdecl("onecastPluginCreate")
public func onecastPluginCreate() -> UnsafeMutableRawPointer {
    OnecastPluginRuntime.export { GoogleAIModePlugin() }
}

// MARK: - Preferences

enum Prefs {
    static let store = PluginPreferences(pluginID: "com.sujha.googleaimode")

    static var zoom: CGFloat {
        let value = store.string("zoom").flatMap(Double.init) ?? 0.9
        return CGFloat(min(max(value, 0.5), 1.5))
    }

    static var keepThreads: Int { max(store.integer("keepThreads") ?? 50, 1) }

    static var chatOnly: Bool { store.bool("chatOnly") }
}

// MARK: - Threads

struct AIThread: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    /// The page's latest address; a follow-up rewrites it, so reopening lands on the newest turn.
    /// Nil once the conversation is cleared, until the next question.
    var url: URL?
    let created: Date
    var updated: Date

    var isBlank: Bool { url == nil }
}

/// Every thread the user started, newest first, in the host's defaults.
@MainActor
@Observable
final class ThreadStore {
    static let shared = ThreadStore()

    private(set) var threads: [AIThread] = []
    private static let defaultsKey = "googleaimode.threads"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
            let saved = try? JSONDecoder().decode([AIThread].self, from: data)
        {
            threads = saved
        }
    }

    func thread(_ id: UUID) -> AIThread? { threads.first { $0.id == id } }

    /// The threads worth listing: a cleared one with no question yet has nothing to reopen.
    var listed: [AIThread] { threads.filter { !$0.isBlank } }

    func start(_ query: String) -> AIThread {
        let now = Date()
        let thread = AIThread(
            id: UUID(), title: query, url: GoogleURL.aiMode(query), created: now, updated: now)
        threads.insert(thread, at: 0)
        trimAndSave()
        return thread
    }

    func record(url: URL, for id: UUID) {
        guard GoogleURL.isAIModePage(url), let index = threads.firstIndex(where: { $0.id == id }),
            threads[index].url != url
        else { return }
        var thread = threads.remove(at: index)
        thread.url = url
        thread.updated = Date()
        threads.insert(thread, at: 0)
        save()
    }

    /// Empties a conversation in place, keeping its id so a pop-out or pinned link still finds it.
    func clear(_ id: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        WebViewRegistry.shared.discard(id)
        threads[index].url = nil
        threads[index].title = "New Conversation"
        threads[index].updated = Date()
        save()
    }

    /// Starts a new conversation in a cleared thread.
    func ask(_ query: String, in id: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        var thread = threads.remove(at: index)
        thread.title = query
        thread.url = GoogleURL.aiMode(query)
        thread.updated = Date()
        threads.insert(thread, at: 0)
        save()
    }

    func delete(_ id: UUID) {
        threads.removeAll { $0.id == id }
        WebViewRegistry.shared.discard(id)
        save()
    }

    func deleteAll() {
        for thread in threads { WebViewRegistry.shared.discard(thread.id) }
        threads = []
        save()
    }

    private func trimAndSave() {
        let keep = Prefs.keepThreads
        if threads.count > keep {
            for dropped in threads[keep...] { WebViewRegistry.shared.discard(dropped.id) }
            threads.removeLast(threads.count - keep)
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(threads) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

enum GoogleURL {
    static func aiMode(_ query: String) -> URL {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [
            URLQueryItem(name: "udm", value: "50"), URLQueryItem(name: "q", value: query),
        ]
        return components.url!
    }

    static let signIn = URL(string: "https://accounts.google.com/ServiceLogin?continue=https://www.google.com/")!

    static func isGoogle(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let parts = host.split(separator: ".")
        return parts.contains("google") || host.hasSuffix("gstatic.com")
            || host.hasSuffix("googleusercontent.com")
    }

    static func isAIModePage(_ url: URL) -> Bool {
        guard isGoogle(url), url.path() == "/search" else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains { $0.name == "udm" && $0.value == "50" } ?? false
    }

    /// A result link Google routes through its own `/url?q=` redirect, unwrapped to the target.
    static func outboundTarget(_ url: URL) -> URL? {
        guard isGoogle(url), url.path() == "/url",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let raw = items.first(where: { $0.name == "q" || $0.name == "url" })?.value
        else { return nil }
        return URL(string: raw)
    }
}

// MARK: - Live pages

/// One live page per recently used thread, shared by the launcher and pop-out windows (plugin
/// instances share this module's statics), so popping out moves the conversation, not a reload.
@MainActor
@Observable
final class WebViewRegistry {
    static let shared = WebViewRegistry()

    private static let liveLimit = 6
    @ObservationIgnored private var pages: [UUID: ThreadPage] = [:]
    @ObservationIgnored private var recent: [UUID] = []
    /// Threads a pop-out window is showing right now.
    private(set) var windowed: Set<UUID> = []
    @ObservationIgnored private var signInPage: ThreadPage?

    /// A stable identifier, so cookies and the Google sign-in survive relaunches and rebuilds.
    private static let storeID = UUID(uuidString: "8B4F2D71-3C1E-4E7A-9D2B-6A0C5F1E7B93")!
    @ObservationIgnored let dataStore = WKWebsiteDataStore(forIdentifier: WebViewRegistry.storeID)

    func page(for thread: AIThread) -> ThreadPage {
        let page = pages[thread.id] ?? makePage(for: thread)
        page.webView.pageZoom = Prefs.zoom
        touch(thread.id)
        evict()
        return page
    }

    private func makePage(for thread: AIThread) -> ThreadPage {
        let page = ThreadPage(threadID: thread.id, dataStore: dataStore)
        if let url = thread.url { page.load(url) }
        pages[thread.id] = page
        return page
    }

    func signIn() -> ThreadPage {
        if let signInPage { return signInPage }
        let page = ThreadPage(threadID: nil, dataStore: dataStore)
        page.load(GoogleURL.signIn)
        signInPage = page
        return page
    }

    func closeSignIn() { signInPage = nil }

    func setWindowed(_ id: UUID, _ on: Bool) {
        if on { windowed.insert(id) } else { windowed.remove(id) }
    }

    func discard(_ id: UUID) {
        pages[id]?.webView.removeFromSuperview()
        pages[id] = nil
        recent.removeAll { $0 == id }
    }

    /// After a sign-in or sign-out, so every open thread picks up the new account.
    func reloadAll() {
        for page in pages.values { page.webView.reload() }
    }

    func signOut() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await dataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
        signInPage = nil
        reloadAll()
    }

    private func touch(_ id: UUID) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
    }

    private func evict() {
        while recent.count > Self.liveLimit, let oldest = recent.last {
            if windowed.contains(oldest) { break }
            discard(oldest)
        }
    }
}

/// Whether a page has been fitted to the launcher yet; the view shows a spinner until it has.
@MainActor
@Observable
final class PageStatus {
    var styled = true
}

/// A script message handler that does not retain its page: the configuration holds handlers strongly.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: ThreadPage?

    init(_ target: ThreadPage) { self.target = target }

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated { target?.status.styled = true }
    }
}

/// A web view for one thread, plus the navigation rules that keep it on Google.
@MainActor
final class ThreadPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    let threadID: UUID?
    let webView: WKWebView
    let status = PageStatus()
    private let fitsLauncher = Prefs.chatOnly
    private var urlObservation: NSKeyValueObservation?

    init(threadID: UUID?, dataStore: WKWebsiteDataStore) {
        self.threadID = threadID
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        // Google serves a bare WebKit agent its basic page; this is Safari's engine, so say so.
        config.applicationNameForUserAgent = "Version/\(Self.safariVersion) Safari/605.1.15"
        config.preferences.isElementFullscreenEnabled = false
        let scripts = config.userContentController
        if fitsLauncher {
            scripts.addUserScript(
                WKUserScript(source: ChatOnly.cloak, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            scripts.addUserScript(
                WKUserScript(source: ChatOnly.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        if fitsLauncher { scripts.add(WeakMessageHandler(self), name: ChatOnly.readyMessage) }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.pageZoom = Prefs.zoom
        // Lets the launcher's own backdrop show through once the page's background is cleared.
        if Prefs.chatOnly, webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            webView.setValue(false, forKey: "drawsBackground")
            webView.underPageBackgroundColor = .clear
        }
        if let threadID {
            urlObservation = webView.observe(\.url, options: [.new]) { webView, _ in
                Task { @MainActor in
                    guard let url = webView.url else { return }
                    ThreadStore.shared.record(url: url, for: threadID)
                }
            }
        }
    }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }

    private static let safariVersion: String = {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        let info = NSDictionary(contentsOf: plist)
        return info?["CFBundleShortVersionString"] as? String ?? "26.0"
    }()

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        if let target = GoogleURL.outboundTarget(url), !GoogleURL.isGoogle(target) {
            NSWorkspace.shared.open(target)
            return .cancel
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme != "http", scheme != "https", scheme != "about", scheme != "blob", scheme != "data" {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if isMainFrame, navigationAction.navigationType == .linkActivated, !GoogleURL.isGoogle(url) {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        if fitsLauncher, isMainFrame, GoogleURL.isAIModePage(url) { status.styled = false }
        return .allow
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        status.styled = true
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        status.styled = true
    }

    // MARK: WKUIDelegate

    /// A link meant for a new tab: Google stays here, anything else goes to the browser.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if let target = GoogleURL.outboundTarget(url) {
            NSWorkspace.shared.open(target)
        } else if GoogleURL.isGoogle(url) {
            webView.load(URLRequest(url: url))
        } else {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}

/// Fits an AI Mode conversation into the launcher: hides Google's chrome (logo, tab and account
/// bar, side rail, footer), clears the page background so the launcher's backdrop shows through,
/// and restyles what remains with the launcher's tokens: system font, translucent surfaces and
/// hairline strokes. Matched by ids, layout and computed style rather than Google's generated
/// class names, re-applied as the page streams in; any other Google page is left untouched.
enum ChatOnly {
    static let readyMessage = "onecastReady"

    /// Runs before Google's page parses: an AI Mode page stays unpainted until `script` has fitted
    /// it, so its own chrome never flashes. Hidden, not removed, so layout still runs for the sweep.
    static let cloak = """
        (() => {
          if (new URLSearchParams(location.search).get('udm') !== '50') return;
          const style = document.createElement('style');
          style.id = 'onecast-cloak';
          style.textContent = 'html { visibility: hidden !important; }';
          document.documentElement.appendChild(style);
        })();
        """

    static let script = """
        (() => {
          if (window.__onecastChatOnly) return;
          window.__onecastChatOnly = true;
          let revealed = false;
          const reveal = () => {
            if (revealed) return;
            revealed = true;
            document.getElementById('onecast-cloak')?.remove();
            window.webkit?.messageHandlers?.\(readyMessage)?.postMessage('ready');
          };
          // Never leave a page hidden: if Google's layout changes and nothing matches, show it anyway.
          setTimeout(reveal, 4000);
          const isAIMode = () => new URLSearchParams(location.search).get('udm') === '50';
          if (!isAIMode()) reveal();
          const mark = (el) => {
            if (el && !el.hasAttribute('data-onecast-hidden')) el.setAttribute('data-onecast-hidden', '');
          };
          const childOf = (el, parent) => {
            while (el && el.parentElement && el.parentElement !== parent) el = el.parentElement;
            return el && el.parentElement === parent ? el : null;
          };
          const rgba = (value) => {
            const m = /rgba?\\(([^)]+)\\)/.exec(value);
            if (!m) return null;
            const [r, g, b, a = 1] = m[1].split(',').map(Number);
            return { r, g, b, a };
          };
          const iconFont = /symbol|material|icon/i;
          let pageColor = null;
          const checked = new WeakSet();
          const set = (el, prop, value) => el.style.setProperty(prop, value, 'important');
          const restyle = (el, main) => {
            if (checked.has(el)) return;
            checked.add(el);
            const s = getComputedStyle(el);
            if (!iconFont.test(s.fontFamily)) set(el, 'font-family', 'var(--oc-font)');
            const solid = s.backgroundColor.replace(/\\s/g, '');
            if (solid === pageColor || (s.backgroundImage !== 'none'
                && s.backgroundImage.replace(/\\s/g, '').includes(pageColor.slice(4, -1)))) {
              set(el, 'background', 'transparent');
              return;
            }
            if (!main.contains(el)) return;
            const field = el.querySelector('textarea, [contenteditable="true"]') !== null;
            if (!field && (s.position === 'absolute' || s.position === 'fixed')) return;
            if (parseFloat(s.borderTopWidth) > 0) set(el, 'border-color', 'var(--oc-stroke)');
            const bg = rgba(s.backgroundColor);
            if (!bg || bg.a < 0.9) return;
            const r = el.getBoundingClientRect();
            if (field) {
              set(el, 'background', 'var(--oc-field)');
              set(el, 'border', '1px solid var(--oc-stroke)');
              set(el, 'border-radius', '12px');
              set(el, 'box-shadow', 'none');
            } else if (r.width <= 64 && r.height <= 64) {
              set(el, 'background', 'var(--oc-control)');
            } else {
              set(el, 'background', 'var(--oc-surface)');
              if (parseFloat(s.borderTopLeftRadius) > 12) set(el, 'border-radius', '12px');
            }
          };
          const sweep = () => {
            if (!isAIMode()) return;
            mark(document.querySelector('body > header'));
            const cnt = document.getElementById('cnt');
            const bar = document.getElementById('gb') || document.getElementById('og-te');
            if (cnt && bar) mark(childOf(bar, cnt));
            mark(document.getElementById('sfooter'));
            const main = document.querySelector('[role="main"]');
            if (!main) return;
            for (const child of main.children) {
              if (child.hasAttribute('data-onecast-hidden')) continue;
              if (child.querySelector('textarea, [contenteditable="true"]')) continue;
              const r = child.getBoundingClientRect();
              if (r.width > 0 && r.width < 120 && r.left < 40) mark(child);
            }
            if (!pageColor) {
              const bg = getComputedStyle(document.body).backgroundColor.replace(/\\s/g, '');
              if (!bg.startsWith('rgb(')) return;
              pageColor = bg;
              for (const el of [document.documentElement, document.body]) {
                set(el, 'background', 'transparent');
                checked.add(el);
              }
            }
            for (const el of document.body.querySelectorAll('*')) restyle(el, main);
            markComposer(main);
            reveal();
          };
          // Google paints the composer box on a `::before` of a sibling layer, not an ancestor.
          const isBoxLayer = (el) => {
            const r = el.getBoundingClientRect();
            if (r.width < 200 || r.height < 48) return false;
            const before = getComputedStyle(el, '::before');
            const layer = rgba(before.backgroundColor);
            return layer && layer.a >= 0.9 && parseFloat(before.borderTopLeftRadius) >= 16;
          };
          const markComposer = (main) => {
            const inputs = main.querySelectorAll('textarea, [contenteditable="true"]');
            for (const input of inputs) {
              if (input.getBoundingClientRect().width === 0) continue;
              let el = input.parentElement;
              for (let depth = 0; el && el !== main && depth < 8; depth++, el = el.parentElement) {
                if (el.querySelector('[data-onecast-field]')) break;
                const box = [el, ...el.querySelectorAll('*')].find(isBoxLayer);
                if (!box) continue;
                box.setAttribute('data-onecast-field', '');
                break;
              }
            }
          };
          const style = document.createElement('style');
          style.textContent = `
            :root {
              --oc-font: -apple-system, system-ui, "SF Pro Text", sans-serif;
              --oc-field: rgba(255, 255, 255, 0.08);
              --oc-surface: rgba(255, 255, 255, 0.10);
              --oc-control: rgba(255, 255, 255, 0.10);
              --oc-stroke: rgba(255, 255, 255, 0.10);
            }
            @media (prefers-color-scheme: light) {
              :root {
                --oc-field: rgba(0, 0, 0, 0.05);
                --oc-surface: rgba(0, 0, 0, 0.09);
                --oc-control: rgba(0, 0, 0, 0.08);
                --oc-stroke: rgba(0, 0, 0, 0.10);
              }
            }
            [data-onecast-hidden] { display: none !important; }
            [data-onecast-field]::before {
              background: var(--oc-field) !important;
              border-color: var(--oc-stroke) !important;
              border-radius: 12px !important;
              -webkit-backdrop-filter: blur(24px) saturate(1.4);
              backdrop-filter: blur(24px) saturate(1.4);
            }
            [data-onecast-field]::after { border-radius: 12px !important; box-shadow: none !important; }
            textarea, [contenteditable="true"] { caret-color: AccentColor !important; }
            ::selection { background: color-mix(in srgb, AccentColor 35%, transparent); }
          `;
          document.documentElement.appendChild(style);
          let queued = false;
          const schedule = () => {
            if (queued) return;
            queued = true;
            requestAnimationFrame(() => { queued = false; sweep(); });
          };
          sweep();
          new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
        })();
        """
}

// MARK: - Hosting

/// Hosts a shared web view without owning it: leaving the screen detaches it only if it is still
/// ours, so a pop-out that has already adopted it keeps it.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    var focusOnAppear = true

    func makeNSView(context: Context) -> HostView {
        let host = HostView()
        host.adopt(webView, focus: focusOnAppear)
        return host
    }

    func updateNSView(_ host: HostView, context: Context) {
        if webView.superview !== host { host.adopt(webView, focus: false) }
    }

    static func dismantleNSView(_ host: HostView, coordinator: ()) {
        host.release()
    }

    final class HostView: NSView {
        private weak var hosted: WKWebView?

        func adopt(_ webView: WKWebView, focus: Bool) {
            hosted = webView
            webView.removeFromSuperview()
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
            guard focus else { return }
            Task { @MainActor [weak self, weak webView] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, let webView, webView.superview === self else { return }
                webView.window?.makeFirstResponder(webView)
            }
        }

        func release() {
            if let hosted, hosted.superview === self { hosted.removeFromSuperview() }
        }
    }
}
