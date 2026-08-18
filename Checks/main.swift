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

print("parse check OK")
