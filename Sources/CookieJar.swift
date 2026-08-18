import Foundation
import WebKit

/// Source of the cookies the API calls travel with.
///
/// A bare `sessionKey` is not enough: claude.ai sits behind Cloudflare, which
/// answers an unrecognised client with a 403 challenge page. The sign-in web
/// view already holds the `cf_clearance` / `__cf_bm` cookies that clear it, so
/// every request reuses the web view's cookie store rather than the file.
enum CookieJar {
    /// Exact-or-suffix match. `contains("claude.ai")` would also accept a
    /// registrable lookalike such as `notclaude.ai`, letting a hostile page
    /// plant a cookie this app would then treat as the real session.
    static func isClaudeDomain(_ domain: String) -> Bool {
        let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return d == "claude.ai" || d.hasSuffix(".claude.ai")
    }

    /// Browser UA — Cloudflare rejects the default URLSession agent string.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    @MainActor
    static func claudeCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies.filter { isClaudeDomain($0.domain) })
            }
        }
    }

    /// Cookie header for claude.ai, preferring the live web-view cookies and
    /// falling back to the stored key when the web view has been cleared.
    @MainActor
    static func header() async -> String? {
        let cookies = await claudeCookies()
        var pairs = cookies.map { "\($0.name)=\($0.value)" }

        if !cookies.contains(where: { $0.name == "sessionKey" }), let key = SessionKeyStore.read() {
            pairs.append("sessionKey=\(key)")
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    /// Keeps the on-disk key in step with the web view, so the fallback above
    /// stays usable and the upstream tracker sees the same credential.
    @MainActor
    static func syncStoredKey() async {
        guard let cookie = await claudeCookies().first(where: { $0.name == "sessionKey" }),
              cookie.value != SessionKeyStore.read() else { return }
        try? SessionKeyStore.write(cookie.value)
    }
}
