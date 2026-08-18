import Foundation

/// Publishes per-model usage for the Claude Code statusline.
///
/// The upstream tracker owns `~/.claude/.statusline-usage-cache` and rewrites it
/// wholesale, so this writes a separate file instead of racing it for the same
/// keys. Format matches that cache — `KEY=value` lines, epoch `TIMESTAMP` — so
/// the statusline script reads both the same way.
enum StatuslineCache {
    static let fableURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.statusline-fable-cache")
    /// The upstream tracker's cache — the statusline script reads Usage/Weekly
    /// from here. Writing it makes this app a drop-in replacement; if the
    /// upstream app also runs, both write the same numbers, so last-writer-wins
    /// is harmless.
    static let usageURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.statusline-usage-cache")

    static func write(_ limits: [UsageLimit]) {
        let now = Int(Date().timeIntervalSince1970)
        let iso = ISO8601DateFormatter()   // "2026-08-18T05:00:00Z" — the format the script's date -j parse expects

        func lines(_ pairs: [(String, String?)]) -> String {
            pairs.compactMap { key, value in value.map { "\(key)=\($0)" } }
                .joined(separator: "\n") + "\n"
        }

        if let fable = limits.first(where: { $0.id == "fable" }) {
            try? lines([
                ("FABLE_UTILIZATION", "\(Int(fable.percent.rounded()))"),
                ("FABLE_RESETS_AT", fable.resetsAt.map(iso.string(from:))),
                ("TIMESTAMP", "\(now)"),
            ]).write(to: fableURL, atomically: true, encoding: .utf8)
        }

        let session = limits.first { $0.id == "session" }
        let weekly = limits.first { $0.id == "all" }
        guard session != nil || weekly != nil else { return }
        try? lines([
            ("UTILIZATION", session.map { "\(Int($0.percent.rounded()))" }),
            ("RESETS_AT", session?.resetsAt.map(iso.string(from:))),
            ("TIMESTAMP", "\(now)"),
            ("WEEKLY_UTILIZATION", weekly.map { "\(Int($0.percent.rounded()))" }),
            ("WEEKLY_RESETS_AT", weekly?.resetsAt.map(iso.string(from:))),
        ]).write(to: usageURL, atomically: true, encoding: .utf8)
    }
}
