import SwiftUI
import WebKit

/// Signs the user in to claude.ai in an embedded web view and lifts the
/// `sessionKey` cookie out of the web view's cookie store, so nobody has to
/// copy it out of DevTools by hand.
@MainActor
enum SignInWindow {
    private static var window: NSWindow?

    static func show(onSuccess: @escaping (String) -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Sign in to Claude"
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.contentView = NSHostingView(rootView: AuthWebView { key in
            close()
            onSuccess(key)
        })

        window = panel
        panel.makeKeyAndOrderFront(nil)
        // The app is an LSUIElement agent, so it has to be activated explicitly
        // or the login window opens behind whatever is in front.
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        window?.close()
        window = nil
    }
}

// MARK: - Web view

private struct AuthWebView: NSViewRepresentable {
    let onCookieFound: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.startPolling(config.websiteDataStore)

        // Drop stale Claude cookies so a dead session can't silently auto-login.
        // Third-party SSO cookies stay so the Google popup still works.
        let store = config.websiteDataStore.httpCookieStore
        store.getAllCookies { cookies in
            let group = DispatchGroup()
            for cookie in cookies where cookie.domain.contains("claude") || cookie.domain.contains("anthropic") {
                group.enter()
                store.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main) {
                webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
            }
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCookieFound: onCookieFound) }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        private let onCookieFound: (String) -> Void
        private var found = false
        // nonisolated(unsafe): only ever touched on the main actor; the
        // annotation exists so deinit can stop the timer.
        private nonisolated(unsafe) var pollTimer: Timer?
        private var pollsSinceLoginLeft = 0
        private var reloadAttempts = 0
        private var popupWindow: NSWindow?
        private var popupWebView: WKWebView?
        weak var webView: WKWebView?

        init(onCookieFound: @escaping (String) -> Void) {
            self.onCookieFound = onCookieFound
        }

        deinit { pollTimer?.invalidate() }

        func startPolling(_ dataStore: WKWebsiteDataStore) {
            dataStore.httpCookieStore.add(self)

            // WKHTTPCookieStoreObserver does not fire for cookies the network
            // process sets via Set-Cookie on recent macOS, and claude.ai is an
            // SPA so didFinish never fires again after login. Poll as a
            // fallback, in .common mode so it keeps running during tracking.
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard !self.found else { return self.stopPolling() }
                    self.searchForCookie(in: dataStore.httpCookieStore)
                    self.reloadIfLoggedInWithoutCookie()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }

        private func stopPolling() {
            pollTimer?.invalidate()
            pollTimer = nil
        }

        /// The fresh cookie can stay invisible to `getAllCookies` until the next
        /// navigation. If login clearly succeeded but no cookie showed up,
        /// force a reload — the same workaround as reloading the page by hand.
        private func reloadIfLoggedInWithoutCookie() {
            guard !found, let webView else { return }
            guard let url = webView.url,
                  CookieJar.isClaudeDomain(url.host ?? ""),
                  !url.path.contains("login") else {
                pollsSinceLoginLeft = 0
                return
            }
            pollsSinceLoginLeft += 1
            if pollsSinceLoginLeft >= 3 && reloadAttempts < 3 {
                pollsSinceLoginLeft = 0
                reloadAttempts += 1
                webView.reloadFromOrigin()
            }
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            guard !found else { return }
            searchForCookie(in: cookieStore)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !found else { return }
            searchForCookie(in: webView.configuration.websiteDataStore.httpCookieStore)
        }

        private func searchForCookie(in store: WKHTTPCookieStore) {
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.found else { return }
                guard let cookie = cookies.first(where: {
                    $0.name == "sessionKey" && CookieJar.isClaudeDomain($0.domain)
                }) else { return }
                self.found = true
                let value = cookie.value
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.stopPolling()
                        self.onCookieFound(value)
                    }
                }
            }
        }

        // MARK: Google SSO popup

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Reuse the supplied configuration so window.opener and the shared
            // cookie store survive — Google SSO breaks without both.
            let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 600),
                                  configuration: configuration)
            popup.navigationDelegate = self
            popup.uiDelegate = self

            let panel = NSPanel(contentRect: popup.frame,
                                styleMask: [.titled, .closable, .resizable],
                                backing: .buffered, defer: false)
            panel.title = "Sign In"
            panel.contentView = popup
            panel.center()
            panel.makeKeyAndOrderFront(nil)

            popupWindow = panel
            popupWebView = popup
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            guard webView === popupWebView else { return }
            popupWindow?.close()
            popupWindow = nil
            popupWebView = nil
        }
    }
}
