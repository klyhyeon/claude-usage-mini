import Foundation

// Shape taken from a real claude.ai /usage response, with the numbers changed.
let json: [String: Any] = [
    "five_hour": ["utilization": 16.0, "resets_at": "2026-08-18T05:00:00.324039+00:00"],
    "seven_day": ["utilization": 2.0, "resets_at": "2026-08-23T04:00:00.324062+00:00"],
    "seven_day_fable": ["utilization": 11],
    "limits": [
        ["kind": "session", "group": "session", "percent": 7,
         "resets_at": "2026-08-18T05:00:00.324039+00:00", "scope": NSNull()],
        ["kind": "weekly_all", "group": "weekly", "percent": 24,
         "resets_at": "2026-08-23T04:00:00.324062+00:00", "scope": NSNull()],
        ["kind": "weekly_scoped", "group": "weekly", "percent": 43,
         "resets_at": "2026-08-23T04:00:00.324062+00:00",
         "scope": ["model": ["id": NSNull(), "display_name": "Fable"]]],
        ["kind": "weekly_scoped", "group": "weekly", "percent": 0, "resets_at": NSNull(),
         "scope": ["model": ["id": NSNull(), "display_name": "Opus"]]],
    ],
]

let rows = UsageAPI.parse(json)

// limits[] is the source of truth: it overrides the legacy five_hour /
// seven_day / seven_day_fable fields, which newer responses null out.
precondition(rows[0].id == "session" && rows[0].percent == 7, "session: \(rows[0])")
precondition(rows[1].id == "all" && rows[1].percent == 24, "all: \(rows[1])")
precondition(rows[0].resetsAt != nil, "fractional-second offset timestamp failed to parse")

// A model the API reports is listed even at 0% — hiding it reads as a bug.
let models = Array(rows.dropFirst(2))
precondition(models.map(\.id) == ["fable", "opus"], "models: \(models.map(\.id))")
precondition(models.first?.percent == 43, "fable: \(models.first as Any)")
precondition(models.allSatisfy { $0.badge == "Weekly" })

// An org with nothing recorded still parses, so the caller can move on to the
// next org rather than treating zeros as the answer.
let empty = UsageAPI.parse(["limits": [] as [[String: Any]]])
precondition(empty.isEmpty, "empty payload produced rows: \(empty)")

let codexJSON = #"""
{"id":1,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":62,"windowDurationMins":10080,"resetsAt":1789954384},"secondary":null,"individualLimit":{"limit":"1000","used":"0.0","remainingPercent":100,"resetsAt":1790812800}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":62,"windowDurationMins":10080,"resetsAt":1789954384},"secondary":null,"individualLimit":{"limit":"1000","used":"0.0","remainingPercent":100,"resetsAt":1790812800}}}}}
"""#.data(using: .utf8)!
let fetchedAt = Date(timeIntervalSince1970: 1_789_450_000)
let codexUsage = try CodexUsageParser.parseResponse(codexJSON, fetchedAt: fetchedAt)

let weekly = codexUsage.limits.first { $0.id == "codex-weekly" }
let monthly = codexUsage.limits.first { $0.id == "codex-monthly" }
precondition(weekly?.percent == 62)
precondition(weekly?.resetsAt == Date(timeIntervalSince1970: 1_789_954_384))
precondition(monthly?.percent == 0, "monthly must show used, not remaining")
precondition(monthly?.resetsAt == Date(timeIntervalSince1970: 1_790_812_800))
precondition(codexUsage.fetchedAt == fetchedAt)
precondition(CodexMenuLabel.make(from: codexUsage) == "C 62%(0%)")
precondition(CodexMenuLabel.make(from: nil) == "C —")

let weeklyOnlyJSON = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":41,"windowDurationMins":10080,"resetsAt":null},"secondary":null,"individualLimit":null},"rateLimitsByLimitId":null}}"#.data(using: .utf8)!
let weeklyOnly = try CodexUsageParser.parseResponse(weeklyOnlyJSON, fetchedAt: fetchedAt)
precondition(weeklyOnly.limits.map(\.id) == ["codex-weekly"])
precondition(CodexMenuLabel.make(from: weeklyOnly) == "C 41%")

let clampedJSON = #"{"id":3,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":140,"windowDurationMins":10080,"resetsAt":null},"secondary":null,"individualLimit":{"limit":"1000","used":"2000","remainingPercent":-20,"resetsAt":1790812800}},"rateLimitsByLimitId":null}}"#.data(using: .utf8)!
let clamped = try CodexUsageParser.parseResponse(clampedJSON, fetchedAt: fetchedAt)
precondition(clamped.limits.allSatisfy { $0.percent == 100 })

let wrongBucketJSON = #"{"id":4,"result":{"rateLimits":{"limitId":"other","primary":{"usedPercent":99,"windowDurationMins":10080,"resetsAt":null},"secondary":null,"individualLimit":null},"rateLimitsByLimitId":{"other":{"limitId":"other","primary":{"usedPercent":99,"windowDurationMins":10080,"resetsAt":null},"secondary":null,"individualLimit":null}}}}"#.data(using: .utf8)!
do {
    _ = try CodexUsageParser.parseResponse(wrongBucketJSON, fetchedAt: fetchedAt)
    preconditionFailure("an unrelated bucket must not be displayed as Codex")
} catch CodexUsageError.malformedResponse {}

let loginErrorJSON = #"{"id":5,"error":{"code":-32000,"message":"authentication required; run codex login"}}"#.data(using: .utf8)!
do {
    _ = try CodexUsageParser.parseResponse(loginErrorJSON, fetchedAt: fetchedAt)
    preconditionFailure("authentication errors should become notSignedIn")
} catch CodexUsageError.notSignedIn {}

let fakeHome = URL(fileURLWithPath: "/Users/example")
let resolved = CodexExecutableResolver.resolve(
    environmentPath: "/bin:/custom/bin",
    homeDirectory: fakeHome,
    isExecutable: { $0 == "/Users/example/.local/bin/codex" }
)
precondition(resolved?.path == "/Users/example/.local/bin/codex")

let pathResolved = CodexExecutableResolver.resolve(
    environmentPath: "/bin:/custom/bin",
    homeDirectory: fakeHome,
    isExecutable: { $0 == "/custom/bin/codex" }
)
precondition(pathResolved?.path == "/custom/bin/codex")

let malformed = #"{"id":9,"result":{"unexpected":true}}"#.data(using: .utf8)!
do {
    _ = try CodexUsageParser.parseResponse(malformed, fetchedAt: fetchedAt)
    preconditionFailure("malformed result should fail")
} catch CodexUsageError.malformedResponse {}

let encodedRequest = try CodexRequestEncoder.encode(
    id: 7,
    method: "account/rateLimits/read",
    params: ["excludeResetCreditDetails": true]
)
precondition(encodedRequest.last == 0x0A, "JSON-RPC requests need newline framing")
let encodedObject = try JSONSerialization.jsonObject(with: Data(encodedRequest.dropLast())) as? [String: Any]
precondition(encodedObject?["id"] as? Int == 7)
precondition(encodedObject?["method"] as? String == "account/rateLimits/read")

print("parse check OK")
