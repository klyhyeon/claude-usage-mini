import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        VStack(spacing: 10) {
            if let usage = model.usage, !usage.limits.isEmpty {
                ForEach(usage.limits) { LimitCard(limit: $0) }
            } else if !model.hasSessionKey {
                SessionKeyPrompt(model: model)
            } else if let error = model.error {
                MessageCard(text: error)
                Button("Sign In Again") { model.signIn() }
            } else {
                MessageCard(text: model.isLoading ? "Loading usage…" : "No usage reported yet.")
            }

            Footer(model: model)
        }
        .padding(12)
        .frame(width: 300)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }
}

/// Fixed dark palette matching the Windows mockup the user picked —
/// deliberately one look, not theme-following.
enum Theme {
    static let panel = Color(red: 40/255, green: 40/255, blue: 40/255)
    static let card = Color(red: 51/255, green: 51/255, blue: 51/255)
    static let cardBorder = Color.white.opacity(0.06)
    static let title = Color.white
    static let dim = Color(red: 160/255, green: 160/255, blue: 160/255)
    static let faint = Color(red: 122/255, green: 122/255, blue: 122/255)
    static let track = Color.white.opacity(0.12)
    static let green = Color(red: 108/255, green: 203/255, blue: 95/255)
    static let badgeBg = Color.white.opacity(0.10)
}

private struct LimitCard: View {
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.title)
                if let badge = limit.badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.dim)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.badgeBg))
                }
                Spacer()
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }

            if let subtitle = limit.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }

            ProgressBar(fraction: limit.percent / 100, tint: tint)

            if let resetsAt = limit.resetsAt {
                Text("Resets \(Self.format(resetsAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.card)
                .stroke(Theme.cardBorder, lineWidth: 1)
        )
    }

    /// Green under 70, amber to 90, red past it — a glanceable severity ramp.
    private var tint: Color {
        switch limit.percent {
        case ..<70: Theme.green
        case ..<90: .orange
        default: .red
        }
    }

    private static func format(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if Calendar.current.isDateInToday(date) { return "Today \(time)" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }
}

private struct ProgressBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 4)
    }
}

private struct SessionKeyPrompt: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect your account")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.title)
            Text("Sign in to claude.ai and the session key is picked up automatically.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
            Button("Sign In") { model.signIn() }
                .buttonStyle(.borderedProminent)

            DisclosureGroup("Paste a key instead") {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("sk-ant-sid01-…", text: $model.sessionKeyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { Task { await model.saveSessionKey() } }
                        .disabled(model.sessionKeyDraft.isEmpty)
                }
                .padding(.top, 6)
            }
            .font(.system(size: 11))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
    }
}

private struct MessageCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
    }
}

private struct Footer: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        HStack {
            if let fetchedAt = model.usage?.fetchedAt {
                Text("Updated \(fetchedAt.formatted(.dateTime.hour().minute()))")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
            }
            Spacer()
            Button("Refresh") { Task { await model.refresh() } }
                .disabled(model.isLoading)
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
    }
}
