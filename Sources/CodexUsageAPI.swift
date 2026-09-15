import Foundation

enum CodexUsageError: LocalizedError, Equatable {
    case cliNotFound
    case notSignedIn
    case connectionFailed
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .cliNotFound: "Codex CLI was not found."
        case .notSignedIn: "Codex is not signed in. Run codex login."
        case .connectionFailed: "Could not connect to Codex."
        case .malformedResponse: "Codex returned an unsupported usage response."
        }
    }
}

enum CodexUsageParser {
    static func parseResponse(_ data: Data, fetchedAt: Date = Date()) throws -> Usage {
        let envelope: ResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        } catch {
            throw CodexUsageError.malformedResponse
        }
        if let message = envelope.error?.message.lowercased(),
           message.contains("login") || message.contains("auth") {
            throw CodexUsageError.notSignedIn
        }
        guard envelope.error == nil, let result = envelope.result else {
            throw CodexUsageError.malformedResponse
        }
        let bucket = result.rateLimitsByLimitId?["codex"] ?? result.rateLimits
        guard bucket.limitId == nil || bucket.limitId == "codex" else {
            throw CodexUsageError.malformedResponse
        }

        let windows = [bucket.primary, bucket.secondary].compactMap { $0 }
        var limits: [UsageLimit] = []
        if let weekly = windows.first(where: { $0.windowDurationMins == 10_080 }) {
            limits.append(UsageLimit(
                id: "codex-weekly",
                title: "Weekly Usage",
                badge: nil,
                subtitle: "7-day window",
                percent: clamp(weekly.usedPercent),
                resetsAt: weekly.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ))
        }
        if let monthly = bucket.individualLimit {
            limits.append(UsageLimit(
                id: "codex-monthly",
                title: "Monthly Usage",
                badge: nil,
                subtitle: "Monthly allowance",
                percent: clamp(100 - monthly.remainingPercent),
                resetsAt: Date(timeIntervalSince1970: TimeInterval(monthly.resetsAt))
            ))
        }
        guard !limits.isEmpty else { throw CodexUsageError.malformedResponse }
        return Usage(limits: limits, fetchedAt: fetchedAt)
    }

    private static func clamp(_ value: Int) -> Double {
        Double(max(0, min(100, value)))
    }
}

private struct ResponseEnvelope: Decodable {
    let result: RateLimitsResult?
    let error: RPCError?

    private enum CodingKeys: String, CodingKey {
        case result
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decodeIfPresent(RateLimitsResult.self, forKey: .result)
        error = try container.decodeIfPresent(RPCError.self, forKey: .error)
    }
}

private struct RPCError: Decodable { let message: String }

private struct RateLimitsResult: Decodable {
    let rateLimits: RateLimitBucket
    let rateLimitsByLimitId: [String: RateLimitBucket]?
}

private struct RateLimitBucket: Decodable {
    let limitId: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let individualLimit: IndividualLimit?
}

private struct RateLimitWindow: Decodable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int?
}

private struct IndividualLimit: Decodable {
    let remainingPercent: Int
    let resetsAt: Int
}

enum CodexExecutableResolver {
    static func resolve(
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        let pathCandidates = (environmentPath ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") }
        let fixedCandidates = [
            homeDirectory.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]
        return (pathCandidates + fixedCandidates).first { isExecutable($0.path) }
    }
}
