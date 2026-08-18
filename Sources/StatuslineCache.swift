import Foundation

/// Publishes per-model usage for the Claude Code statusline.
///
/// The upstream tracker owns `~/.claude/.statusline-usage-cache` and rewrites it
/// wholesale, so this writes a separate file instead of racing it for the same
/// keys. Format matches that cache — `KEY=value` lines, epoch `TIMESTAMP` — so
/// the statusline script reads both the same way.
enum StatuslineCache {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.statusline-fable-cache")

    static func write(_ limits: [UsageLimit]) {
        guard let fable = limits.first(where: { $0.id == "fable" }) else { return }

        var lines = [
            "FABLE_UTILIZATION=\(Int(fable.percent.rounded()))",
            "TIMESTAMP=\(Int(Date().timeIntervalSince1970))",
        ]
        if let resetsAt = fable.resetsAt {
            lines.insert("FABLE_RESETS_AT=\(ISO8601DateFormatter().string(from: resetsAt))", at: 1)
        }
        try? lines.joined(separator: "\n").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }
}
