# Codex Usage Menu Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing macOS menu-bar item display compact Codex weekly/monthly usage while its popover shows both Codex and Claude metrics.

**Architecture:** Add a Codex adapter that communicates with the installed CLI through the local app-server JSON-RPC protocol and maps its response into the existing `Usage`/`UsageLimit` display model. Keep one persistent subprocess, retry once after reconnecting, and hold Codex and Claude state independently in `UsageModel` so either provider can fail without blanking the other.

**Tech Stack:** Swift 6, SwiftUI, Foundation `Process`/`Pipe`, Codex app-server JSON-RPC, the existing executable parser checks, Swift Package Manager

**Spec:** `docs/superpowers/specs/2026-09-15-codex-usage-widget-design.md`

## Global Constraints

- macOS 14 remains the minimum deployment target.
- The menu bar contains one item and its label is Codex-only: `C weekly%(monthly%)`.
- The popover shows Codex before Claude and keeps the existing visual language.
- Codex authentication remains owned by Codex; never read or copy `~/.codex/auth.json`.
- Claude cookie handling and statusline cache behavior remain unchanged.
- Refresh both providers every 60 seconds and isolate their errors.
- Do not change the Windows tray application.
- Keep all commits local. Do not push a branch or open a pull request.
- Do not launch the built app during verification without separate user approval.

## File Structure

- Create `Sources/CodexUsageAPI.swift`: executable resolution, app-server process lifecycle, JSON-RPC line transport, response decoding, and Codex-to-`Usage` mapping.
- Create `Sources/CodexMenuLabel.swift`: pure compact-label formatting that can be compiled by the check executable without SwiftUI.
- Modify `Sources/App.swift`: independent Codex/Claude state and concurrent refresh orchestration.
- Modify `Sources/PopoverView.swift`: provider headings, Codex cards, isolated errors, and shared updated time.
- Modify `Checks/main.swift`: deterministic Codex parser, executable resolver, clamping, and label checks alongside the existing Claude checks.
- Modify `check.sh`: compile the two new Foundation-only source files into the existing parser-check executable.
- Modify `README.md`: explain the combined macOS behavior, Codex dependency, and local-auth privacy boundary.

---

### Task 1: Codex Response Mapping and Compact Label

**Files:**
- Create: `Sources/CodexUsageAPI.swift`
- Create: `Sources/CodexMenuLabel.swift`
- Modify: `Checks/main.swift`
- Modify: `check.sh`

**Interfaces:**
- Consumes: existing `Usage` and `UsageLimit` from `Sources/UsageAPI.swift`.
- Produces: `CodexUsageError`, `CodexUsageParser.parseResponse(_:fetchedAt:) -> Usage`, `CodexExecutableResolver.resolve(environmentPath:homeDirectory:isExecutable:) -> URL?`, and `CodexMenuLabel.make(from:) -> String`.
- Limit identifiers are exactly `codex-weekly` and `codex-monthly`; the UI and formatter use those identifiers rather than display titles.

- [ ] **Step 1: Add failing Codex mapping and label checks**

Append fixtures and assertions to `Checks/main.swift`. Use fixed timestamps so the checks remain deterministic:

```swift
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
```

Add three more compact fixtures:

```swift
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
```

Move the existing `print("parse check OK")` to the end of the file so it is
printed only after the new Codex checks have completed.

- [ ] **Step 2: Compile the check to verify it fails**

Update `check.sh` only enough to include the planned files, which do not exist yet:

```bash
swiftc \
  Sources/UsageAPI.swift \
  Sources/CookieJar.swift \
  Sources/CodexUsageAPI.swift \
  Sources/CodexMenuLabel.swift \
  Checks/main.swift \
  -o .build/parsecheck
```

Run: `./check.sh`

Expected: compilation fails because `Sources/CodexUsageAPI.swift` and `Sources/CodexMenuLabel.swift` do not exist.

- [ ] **Step 3: Implement the minimal response model and mapping**

Create `Sources/CodexUsageAPI.swift` with these externally visible declarations:

```swift
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
```

Define private `Decodable` types in the same file using the exact server keys:

```swift
private struct ResponseEnvelope: Decodable {
    let result: RateLimitsResult?
    let error: RPCError?
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
```

Also declare the executable resolver now so its stable interface is available to Task 2:

```swift
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
```

- [ ] **Step 4: Implement compact label formatting**

Create `Sources/CodexMenuLabel.swift`:

```swift
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
```

- [ ] **Step 5: Run focused checks**

Run: `./check.sh`

Expected: prints `parse check OK`, including all preconditions added above.

Run: `git diff --check`

Expected: no output and exit status 0.

- [ ] **Step 6: Commit the deterministic Codex mapping**

```bash
git add Sources/CodexUsageAPI.swift Sources/CodexMenuLabel.swift Checks/main.swift check.sh
git commit -m "feat: parse Codex weekly and monthly usage"
```

---

### Task 2: Persistent Codex App-Server Client

**Files:**
- Modify: `Sources/CodexUsageAPI.swift`
- Modify: `Checks/main.swift`

**Interfaces:**
- Consumes: `CodexUsageParser.parseResponse(_:fetchedAt:)` and `CodexExecutableResolver.resolve(...)` from Task 1.
- Produces: `CodexRequestEncoder.encode(id:method:params:) -> Data`, actor `CodexUsageAPI`, initializer `init(executableURL: URL? = nil)`, and async `fetch() throws -> Usage` for `UsageModel` in Task 3.
- The actor owns exactly one subprocess and permits exactly one in-flight usage request because `fetch()` is actor-isolated.

- [ ] **Step 1: Add failing request-encoding, resolver, and malformed-envelope checks**

Append these pure checks to `Checks/main.swift`:

```swift
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
```

- [ ] **Step 2: Run the check to verify the new transport seam fails**

Run: `./check.sh`

Expected: compilation fails with `cannot find 'CodexRequestEncoder' in scope`.

- [ ] **Step 3: Add the app-server actor and JSON-RPC codec**

First add the encoder to `Sources/CodexUsageAPI.swift`:

```swift
enum CodexRequestEncoder {
    static func encode(id: Int, method: String, params: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "method": method,
            "params": params,
        ])
        data.append(0x0A)
        return data
    }
}
```

Then add the actor shape:

```swift
actor CodexUsageAPI {
    private let suppliedExecutableURL: URL?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var readBuffer = Data()
    private var nextID = 1

    init(executableURL: URL? = nil) {
        suppliedExecutableURL = executableURL
    }

    func fetch() async throws -> Usage {
        do {
            return try await fetchOnce()
        } catch {
            stop()
            do {
                return try await fetchOnce()
            } catch let retryError as CodexUsageError {
                throw retryError
            } catch {
                throw CodexUsageError.connectionFailed
            }
        }
    }
}
```

Implement `startIfNeeded()` with `Process`, stdin/stdout `Pipe` instances, and
arguments `app-server --stdio`. Resolve the executable with the injected URL
first, then `CodexExecutableResolver.resolve()`. Set a termination handler that
schedules `stop()` back onto the actor:

```swift
private func startIfNeeded() async throws {
    if process?.isRunning == true { return }
    guard let executable = suppliedExecutableURL ?? CodexExecutableResolver.resolve() else {
        throw CodexUsageError.cliNotFound
    }

    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    process.executableURL = executable
    process.arguments = ["app-server", "--stdio"]
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    try process.run()

    self.process = process
    input = stdin.fileHandleForWriting
    output = stdout.fileHandleForReading
    readBuffer.removeAll(keepingCapacity: true)
    process.terminationHandler = { [weak self] _ in
        Task { await self?.stop() }
    }

    let initialize = try await request(
        id: 0,
        method: "initialize",
        params: ["clientInfo": ["name": "claude-usage-mini", "version": "0.1.0"]]
    )
    guard (try? JSONSerialization.jsonObject(with: initialize)) != nil else {
        throw CodexUsageError.connectionFailed
    }
}
```

Implement newline-delimited request writing through the tested encoder; do not
construct JSON by string interpolation:

```swift
private func write(id: Int, method: String, params: [String: Any]) throws {
    guard let input else { throw CodexUsageError.connectionFailed }
    let data = try CodexRequestEncoder.encode(id: id, method: method, params: params)
    try input.write(contentsOf: data)
}
```

Implement `request(id:method:params:)` by writing one request, then reading
newline-delimited stdout until an envelope with the same numeric `id` arrives.
Ignore app-server notifications such as `remoteControl/status/changed`. Use
`FileHandle.read(upToCount:)` inside `Task.detached` so blocking pipe reads do
not occupy the main actor, and retain bytes after the first newline in
`readBuffer` for the next response:

```swift
private func request(id: Int, method: String, params: [String: Any]) async throws -> Data {
    try write(id: id, method: method, params: params)
    while true {
        let line = try await readLine()
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            continue
        }
        if (object["id"] as? Int) == id { return line }
    }
}
```

`readLine()` must first consume a newline already present in `readBuffer`, then
read another chunk. An empty chunk means EOF and throws `.connectionFailed`.
Cap the buffer at 1 MiB and throw `.malformedResponse` if no newline arrives
before that limit:

```swift
private func readLine() async throws -> Data {
    while true {
        if let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = Data(readBuffer[..<newline])
            readBuffer.removeSubrange(...newline)
            if !line.isEmpty { return line }
        }
        guard readBuffer.count <= 1_048_576 else {
            throw CodexUsageError.malformedResponse
        }
        guard let output else { throw CodexUsageError.connectionFailed }
        let chunk = try await Task.detached {
            try output.read(upToCount: 8_192) ?? Data()
        }.value
        guard !chunk.isEmpty else { throw CodexUsageError.connectionFailed }
        readBuffer.append(chunk)
    }
}
```

Complete `fetchOnce()` and `stop()`:

```swift
private func fetchOnce() async throws -> Usage {
    try await startIfNeeded()
    let id = nextID
    nextID += 1
    let data = try await request(
        id: id,
        method: "account/rateLimits/read",
        params: ["excludeResetCreditDetails": true]
    )
    return try CodexUsageParser.parseResponse(data)
}

private func stop() {
    input?.closeFile()
    output?.closeFile()
    if process?.isRunning == true { process?.terminate() }
    process = nil
    input = nil
    output = nil
    readBuffer.removeAll(keepingCapacity: false)
}
```

Do not add token, cookie, or `auth.json` handling.

- [ ] **Step 4: Run parser checks and compile the complete application**

Run: `./check.sh`

Expected: prints `parse check OK`.

Run: `swift build -c release`

Expected: `Build complete!` with no Swift 6 actor-isolation or Sendable errors.

- [ ] **Step 5: Commit the app-server client**

```bash
git add Sources/CodexUsageAPI.swift Checks/main.swift
git commit -m "feat: read usage from the Codex app server"
```

---

### Task 3: Codex-First Application State and Combined Popover

**Files:**
- Modify: `Sources/App.swift`
- Modify: `Sources/PopoverView.swift`

**Interfaces:**
- Consumes: `CodexUsageAPI.fetch()`, `CodexMenuLabel.make(from:)`, and the existing Claude `UsageAPI.fetch()`.
- Produces: `UsageModel.codexUsage`, `UsageModel.claudeUsage`, provider-specific errors, `latestFetchedAt`, and a combined provider-section popover.
- Existing Claude sign-in methods and `StatuslineCache.write(_:)` continue to operate on Claude data only.

- [ ] **Step 1: Replace the menu label with the pure Codex formatter**

In `Sources/App.swift`, replace the old session/Fable/reset-time calculation:

```swift
var menuBarLabel: String {
    CodexMenuLabel.make(from: codexUsage)
}
```

Delete the now-unused `shortTime(_:)` helper. The application should fail to
compile at this point because `codexUsage` has not been added yet.

- [ ] **Step 2: Split model state by provider and refresh concurrently**

Replace the shared state with explicit provider state:

```swift
@Published private(set) var codexUsage: Usage?
@Published private(set) var claudeUsage: Usage?
@Published private(set) var codexError: String?
@Published private(set) var claudeError: String?
@Published private(set) var isLoading = false
@Published var sessionKeyDraft = ""

private let interval: TimeInterval = 60
private let claudeAPI = UsageAPI()
private let codexAPI = CodexUsageAPI()
private var timer: Timer?
```

Implement the refresh so both child operations start before either is awaited:

```swift
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
```

Add the shared footer timestamp:

```swift
var latestFetchedAt: Date? {
    [codexUsage?.fetchedAt, claudeUsage?.fetchedAt]
        .compactMap { $0 }
        .max()
}
```

Update `saveSessionKey()` to assign `claudeError`, not a shared error. Keep
`hasSessionKey`, `signIn()`, timer creation, launch-at-login behavior, and
Claude cache writes otherwise unchanged.

- [ ] **Step 3: Add provider sections and stale-data error behavior**

In `Sources/PopoverView.swift`, replace the single conditional content with:

```swift
VStack(spacing: 10) {
    ScrollView {
        VStack(spacing: 10) {
            ProviderHeading(title: "Codex")
            if let usage = model.codexUsage {
                ForEach(usage.limits) { LimitCard(limit: $0) }
            } else if model.codexError == nil {
                MessageCard(text: model.isLoading ? "Loading Codex usage…" : "No Codex usage reported yet.")
            }
            if let error = model.codexError {
                MessageCard(text: error)
            }

            ProviderHeading(title: "Claude")
            if let usage = model.claudeUsage, !usage.limits.isEmpty {
                ForEach(usage.limits) { LimitCard(limit: $0) }
                if let error = model.claudeError { MessageCard(text: error) }
            } else if !model.hasSessionKey {
                SessionKeyPrompt(model: model)
            } else if let error = model.claudeError {
                MessageCard(text: error)
                Button("Sign In Again") { model.signIn() }
            } else {
                MessageCard(text: model.isLoading ? "Loading Claude usage…" : "No Claude usage reported yet.")
            }
        }
    }
    .frame(maxHeight: 620)

    Footer(model: model)
}
```

Add a compact heading that does not introduce another card background:

```swift
private struct ProviderHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }
}
```

Change the footer from `model.usage?.fetchedAt` to
`model.latestFetchedAt`. Keep the existing 300-point width and card styling;
the bounded `ScrollView` prevents five or more cards from extending beyond a
laptop display while leaving Refresh and Quit visible.

- [ ] **Step 4: Compile and run the focused checks**

Run: `./check.sh`

Expected: prints `parse check OK` and proves the label strings used by the UI.

Run: `swift build -c release`

Expected: `Build complete!` with no SwiftUI or concurrency compiler errors.

Run: `git diff --check`

Expected: no output and exit status 0.

- [ ] **Step 5: Commit the combined menu-bar UI**

```bash
git add Sources/App.swift Sources/PopoverView.swift
git commit -m "feat: show Codex usage with Claude details"
```

---

### Task 4: Documentation and Local Release Bundle

**Files:**
- Modify: `README.md`
- Generated locally by existing script: `Claude Usage Mini.app/Contents/MacOS/ClaudeUsageMini` (ignored build artifact)

**Interfaces:**
- Consumes: completed Codex integration and UI from Tasks 1–3.
- Produces: accurate setup/privacy documentation and a locally rebuilt application bundle; no remote artifacts.

- [ ] **Step 1: Update the macOS behavior and requirements in README**

Change the opening description to say that macOS displays Codex in the menu
bar and shows both Codex and Claude in the popover, while Windows remains the
Claude-only tray application. Document the exact menu label:

```markdown
On macOS, the label reads `C 62%(0%)` — Codex weekly usage and monthly usage.
Click it for Codex Weekly and Monthly cards followed by the existing Claude
Session, All models, and per-model cards.
```

Add these macOS prerequisites and privacy notes:

```markdown
- Install and sign in to the Codex CLI (`codex login`). The app reads usage
  through `codex app-server`; it does not read `~/.codex/auth.json`.
- Sign in to Claude from the popover to populate the Claude detail section.
- Codex and Claude refresh independently every 60 seconds.
```

Retain the existing explanation that Claude's internal API is unofficial.
Clarify that the Codex app-server contract is supplied by the locally installed
CLI, so updating the CLI is the compatibility path if the protocol evolves.

- [ ] **Step 2: Run all targeted non-visual verification**

Run: `./check.sh`

Expected: prints `parse check OK`.

Run: `swift build -c release`

Expected: `Build complete!`.

Run: `git diff --check`

Expected: no output and exit status 0.

- [ ] **Step 3: Build and sign the local app bundle**

Run: `./build.sh`

Expected final line:

```text
Built /Users/yuhyeon/Documents/claude-usage-mini/Claude Usage Mini.app
```

Do not run `open`, terminate the currently running widget, or otherwise change
the visible desktop during this step.

- [ ] **Step 4: Confirm the branch remains local and clean except for user files**

Run:

```bash
git status --short --branch
git log -5 --oneline --decorate
```

Expected: branch `feat/codex-usage-widget`; only the user's pre-existing
untracked `.vscode/` may remain. There must be no push or upstream-setting
command in shell history for this task.

- [ ] **Step 5: Commit documentation locally**

```bash
git add README.md
git commit -m "docs: explain combined Codex and Claude usage"
```

Do not run `git push`, `gh pr create`, or any equivalent remote operation.
