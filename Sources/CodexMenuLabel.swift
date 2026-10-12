import Foundation

enum CodexMenuLabel {
    static func make(from usage: Usage?) -> String {
        guard let weekly = usage?.limits.first(where: { $0.id == "codex-weekly" }) else {
            return "C —"
        }
        var label = "C \(Int(weekly.percent.rounded()))%"
        if let monthly = usage?.limits.first(where: { $0.id == "codex-monthly" }) {
            label += "(\(Int(monthly.percent.rounded()))%)"
        }
        return label
    }
}
