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
    @Published private(set) var codexUsage: Usage?
    @Published private(set) var claudeUsage: Usage?
    @Published private(set) var codexError: String?
    @Published private(set) var claudeError: String?
    @Published private(set) var isLoading = false
    @Published var sessionKeyDraft = ""

    /// Refresh cadence. claude.ai rate-limits aggressive polling; 60s is what the
    /// upstream tracker settles on.
    private let interval: TimeInterval = 60
    private let claudeAPI = UsageAPI()
    private let codexAPI = CodexUsageAPI()
    private var timer: Timer?

    init() {
        LoginItem.enableIfUnset()
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    var menuBarLabel: String {
        CodexMenuLabel.make(from: codexUsage)
    }

    var hasSessionKey: Bool { SessionKeyStore.read() != nil }

    var latestFetchedAt: Date? {
        [codexUsage?.fetchedAt, claudeUsage?.fetchedAt]
            .compactMap { $0 }
            .max()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        async let codexRequest = codexAPI.fetch()
        async let claudeRequest = claudeAPI.fetch()

        do {
            codexUsage = try await codexRequest
            codexError = nil
        } catch {
            codexError = error.localizedDescription
        }

        do {
            let fetched = try await claudeRequest
            claudeUsage = fetched
            claudeError = nil
            StatuslineCache.write(fetched.limits)
        } catch {
            claudeError = error.localizedDescription
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
            claudeError = "Could not save the session key: \(error.localizedDescription)"
        }
    }
}
