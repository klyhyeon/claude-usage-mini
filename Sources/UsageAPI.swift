import Foundation

/// One usage limit row as the popover renders it.
struct UsageLimit: Identifiable, Equatable {
    let id: String
    let title: String
    let badge: String?
    let subtitle: String?
    let percent: Double
    let resetsAt: Date?
}

struct Usage: Equatable {
    var limits: [UsageLimit]
    var fetchedAt: Date
}

enum UsageError: LocalizedError {
    case noSessionKey
    case unauthorized
    case http(Int)
    case noOrganization

    var errorDescription: String? {
        switch self {
        case .noSessionKey: "No session key. Open Settings and paste your claude.ai sessionKey."
        case .unauthorized: "Session key rejected. Paste a fresh one from claude.ai."
        case .http(let code): "claude.ai returned HTTP \(code)."
        case .noOrganization: "No organization on this account."
        }
    }
}

/// Reads the same `~/.claude-session-key` file the upstream tracker uses, so the
/// two apps share one credential.
enum SessionKeyStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude-session-key")

    static func read() -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static func write(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try key.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

actor UsageAPI {
    private var cachedOrgID: String?

    func fetch() async throws -> Usage {
        guard let cookies = await CookieJar.header() else { throw UsageError.noSessionKey }
        await CookieJar.syncStoredKey()

        // Accounts can carry more than one organization and only one of them
        // reports usage, so fall through the list instead of trusting the first.
        for orgID in try await organizationIDs(cookies: cookies) {
            let json = try await get("/organizations/\(orgID)/usage", cookies: cookies)
            let limits = Self.parse(json)
            if !limits.isEmpty {
                cachedOrgID = orgID
                return Usage(limits: limits, fetchedAt: Date())
            }
        }
        cachedOrgID = nil
        return Usage(limits: [], fetchedAt: Date())
    }

    private func organizationIDs(cookies: String) async throws -> [String] {
        if let cachedOrgID { return [cachedOrgID] }
        let orgs = try await getArray("/organizations", cookies: cookies)
        // The subscription lives on the org whose capabilities include "raven";
        // a personal org sits alongside it and reports a flat 0% for everything.
        let ids = (orgs.filter(Self.isSubscription) + orgs.filter { !Self.isSubscription($0) })
            .compactMap { $0["uuid"] as? String }
        guard !ids.isEmpty else { throw UsageError.noOrganization }
        return ids
    }

    private static func isSubscription(_ org: [String: Any]) -> Bool {
        (org["capabilities"] as? [String])?.contains("raven") ?? false
    }

    // MARK: - Transport

    private func request(_ path: String, cookies: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://claude.ai/api" + path)!)
        r.setValue(cookies, forHTTPHeaderField: "Cookie")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(CookieJar.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        r.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        r.timeoutInterval = 20
        return r
    }

    private func data(_ path: String, cookies: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(path, cookies: cookies))
        guard let http = response as? HTTPURLResponse else { throw UsageError.http(0) }
        if ProcessInfo.processInfo.environment["CUM_DEBUG"] == "1" {
            FileHandle.standardError.write(Data(
                "[\(path)] HTTP \(http.statusCode)\n\(String(data: data, encoding: .utf8) ?? "")\n".utf8))
        }
        switch http.statusCode {
        case 200: return data
        case 401, 403: throw UsageError.unauthorized
        default: throw UsageError.http(http.statusCode)
        }
    }

    private func get(_ path: String, cookies: String) async throws -> [String: Any] {
        let raw = try await data(path, cookies: cookies)
        return (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
    }

    private func getArray(_ path: String, cookies: String) async throws -> [[String: Any]] {
        let raw = try await data(path, cookies: cookies)
        return (try? JSONSerialization.jsonObject(with: raw)) as? [[String: Any]] ?? []
    }

    // MARK: - Parsing

    /// `utilization` / `percent` arrive as either a number or a numeric string.
    private static func percent(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func block(_ json: [String: Any], _ key: String,
                              _ iso: ISO8601DateFormatter) -> (Double, Date?)? {
        guard let dict = json[key] as? [String: Any],
              let pct = percent(dict["utilization"]) else { return nil }
        let reset = (dict["resets_at"] as? String).flatMap { iso.date(from: $0) }
        return (pct, reset)
    }

    static func parse(_ json: [String: Any]) -> [UsageLimit] {
        // ISO8601DateFormatter is not Sendable, so it is built per parse rather
        // than shared as a static.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var session = block(json, "five_hour", iso)
        var all = block(json, "seven_day", iso)
        // Legacy per-model fields; newer responses null these out and report the
        // same numbers in `limits[]`, which overrides whatever lands here.
        var models: [String: (title: String, pct: Double, reset: Date?)] = [:]
        for (key, title) in [("seven_day_fable", "Fable"), ("seven_day_opus", "Opus"),
                             ("seven_day_sonnet", "Sonnet"), ("seven_day_omelette", "Design")] {
            if let (pct, reset) = block(json, key, iso) {
                models[title.lowercased()] = (title, pct, reset)
            }
        }

        for limit in json["limits"] as? [[String: Any]] ?? [] {
            guard let pct = percent(limit["percent"]) else { continue }
            let reset = (limit["resets_at"] as? String).flatMap { iso.date(from: $0) }
            switch limit["kind"] as? String {
            case "session":
                session = (pct, reset)
            case "weekly_all":
                all = (pct, reset)
            case "weekly_scoped":
                guard let scope = limit["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any] else { continue }
                // Match the stable model id when there is one; display_name is a
                // rename-prone human label kept as the fallback.
                let modelID = (model["id"] as? String)?.lowercased() ?? ""
                let name = (model["display_name"] as? String) ?? ""
                var key = name.lowercased()
                var title = name
                for (aliases, canonical) in [(["fable", "mythos"], "Fable"), (["opus"], "Opus"),
                                             (["sonnet"], "Sonnet"), (["design", "omelette"], "Design")]
                where aliases.contains(where: { name.lowercased() == $0 || modelID.contains($0) }) {
                    key = aliases[0]
                    title = canonical
                }
                guard !key.isEmpty else { continue }
                models[key] = (title, pct, reset)
            default:
                continue
            }
        }

        var rows: [UsageLimit] = []
        if let session {
            rows.append(UsageLimit(id: "session", title: "Session Usage", badge: nil,
                                   subtitle: "5-hour rolling window",
                                   percent: session.0, resetsAt: session.1))
        }
        if let all {
            rows.append(UsageLimit(id: "all", title: "All models", badge: "Weekly",
                                   subtitle: nil, percent: all.0, resetsAt: all.1))
        }
        // Every model the API reports is shown, 0% included — a model missing
        // from the popover reads as a bug, not as "nothing used yet".
        rows += models
            .map { UsageLimit(id: $0.key, title: $0.value.title, badge: "Weekly",
                              subtitle: nil, percent: $0.value.pct, resetsAt: $0.value.reset) }
            .sorted { $0.percent == $1.percent ? $0.title < $1.title : $0.percent > $1.percent }
        return rows
    }
}
