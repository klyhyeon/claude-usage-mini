import AppKit
import SwiftUI

@main
struct ClaudeUsageMiniApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            Text(model.menuBarLabel)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var usage: Usage?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    @Published var sessionKeyDraft = ""

    /// Refresh cadence. claude.ai rate-limits aggressive polling; 60s is what the
    /// upstream tracker settles on.
    private let interval: TimeInterval = 60
    private let api = UsageAPI()
    private var timer: Timer?

    init() {
        LoginItem.enableIfUnset()
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// Session percentage, Fable weekly in parentheses, session reset time —
    /// "25%(1%) · 2:00pm". Kept monochrome — the menu bar renders label text as
    /// a template, so it follows the system tint like every other extra.
    var menuBarLabel: String {
        guard let limits = usage?.limits, !limits.isEmpty else { return "—" }
        let session = limits.first { $0.id == "session" }
        let pct = session?.percent ?? limits.map(\.percent).max() ?? 0
        var label = "\(Int(pct.rounded()))%"
        if let fable = limits.first(where: { $0.id == "fable" })?.percent {
            label += "(\(Int(fable.rounded()))%)"
        }
        if let reset = session?.resetsAt {
            label += " · " + Self.shortTime(reset)
        }
        return label
    }

    /// "2:00pm" — always with minutes.
    private static func shortTime(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour24 = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let suffix = hour24 < 12 ? "am" : "pm"
        var hour = hour24 % 12
        if hour == 0 { hour = 12 }
        return "\(hour):\(String(format: "%02d", minute))\(suffix)"
    }

    var hasSessionKey: Bool { SessionKeyStore.read() != nil }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await api.fetch()
            usage = fetched
            error = nil
            StatuslineCache.write(fetched.limits)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Opens the claude.ai login window and stores the cookie it hands back.
    func signIn() {
        SignInWindow.show { [weak self] key in
            Task { @MainActor in
                guard let self else { return }
                self.sessionKeyDraft = key
                await self.saveSessionKey()
            }
        }
    }

    func saveSessionKey() async {
        do {
            try SessionKeyStore.write(sessionKeyDraft)
            sessionKeyDraft = ""
            await refresh()
        } catch {
            self.error = "Could not save the session key: \(error.localizedDescription)"
        }
    }
}
