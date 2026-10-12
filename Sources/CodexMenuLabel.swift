import Foundation

enum CodexMenuLabel {
    static func make(from usage: Usage?) -> String {
        let session = usage?.limits.first(where: { $0.id == "codex-session" })
        let weekly = usage?.limits.first(where: { $0.id == "codex-weekly" })
        let percentages = [session, weekly].compactMap { limit in
            limit.map { "\(Int($0.percent.rounded()))%" }
        }
        guard !percentages.isEmpty else {
            if let monthly = usage?.limits.first(where: { $0.id == "codex-monthly" }) {
                return "C M \(Int(monthly.percent.rounded()))%"
            }
            return "C —"
        }
        var label = "C " + percentages.joined(separator: " / ")
        if let monthly = usage?.limits.first(where: { $0.id == "codex-monthly" }) {
            label += "(\(Int(monthly.percent.rounded()))%)"
        }
        return label
    }
}

enum ClaudeMenuLabel {
    static func make(from usage: Usage?) -> String {
        let session = usage?.limits.first(where: { $0.id == "session" })
        let weekly = usage?.limits.first(where: { $0.id == "all" })
        let percentages = [session, weekly].compactMap { limit in
            limit.map { "\(Int($0.percent.rounded()))%" }
        }
        return percentages.isEmpty ? "Cl —" : "Cl " + percentages.joined(separator: " / ")
    }
}
