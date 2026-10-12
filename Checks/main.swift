import Darwin
import Dispatch
import Foundation

if CommandLine.arguments.dropFirst() == ["app-server", "--stdio"] {
    FakeCodexAppServer.run()
    exit(0)
}

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

let lowerClampedJSON = #"{"id":30,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":-12,"windowDurationMins":10080,"resetsAt":null},"secondary":null,"individualLimit":{"limit":"1000","used":"0","remainingPercent":135,"resetsAt":1790812800}},"rateLimitsByLimitId":null}}"#.data(using: .utf8)!
let lowerClamped = try CodexUsageParser.parseResponse(lowerClampedJSON, fetchedAt: fetchedAt)
precondition(
    lowerClamped.limits.allSatisfy { $0.percent == 0 },
    "negative effective usage must clamp to zero: \(lowerClamped.limits)"
)

if CommandLine.arguments.dropFirst() == ["--lower-clamp-only"] {
    print("lower clamp check OK")
    exit(0)
}

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

if CommandLine.arguments.dropFirst() == ["--timeout-restart-only"] {
    try await checkCodexTimeoutRestart(mode: "silent-rate-first")
    try await checkCodexTimeoutRestart(mode: "silent-initialize-first")
    print("timeout/restart checks OK")
    exit(0)
}
if CommandLine.arguments.dropFirst() == ["--terminal-error-only"] {
    try await checkTerminalCodexErrorDoesNotRestart()
    print("terminal error check OK")
    exit(0)
}

try await checkConcurrentCodexFetches()
try await checkCodexTimeoutRestart(mode: "silent-rate-first")
try await checkCodexTimeoutRestart(mode: "silent-initialize-first")
try await checkTerminalCodexErrorDoesNotRestart()

print("parse check OK")

private func checkConcurrentCodexFetches() async throws {
    let executable = URL(
        fileURLWithPath: CommandLine.arguments[0],
        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ).standardizedFileURL
    let logURL = executable.deletingLastPathComponent()
        .appendingPathComponent("codex-usage-concurrency.log")
    try? FileManager.default.removeItem(at: logURL)
    FileManager.default.createFile(atPath: logURL.path, contents: Data())
    defer {
        try? FileManager.default.removeItem(at: logURL)
    }

    let timeout = DispatchWorkItem {
        fputs("concurrent Codex fetch check timed out\n", stderr)
        exit(1)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
    defer { timeout.cancel() }

    let api = CodexUsageAPI(executableURL: executable)

    let initial = try await api.fetch()
    precondition(initial.limits.first?.percent == 17, "initial fake response was not parsed")

    do {
        async let first = api.fetch()
        async let second = api.fetch()
        let (firstUsage, secondUsage) = try await (first, second)
        precondition(firstUsage.limits.first?.percent == 17)
        precondition(secondUsage.limits.first?.percent == 17)
    } catch {
        preconditionFailure("concurrent fetches must complete together: \(error)")
    }

    let events = try String(contentsOf: logURL, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    precondition(events == ["initialize", "rate", "rate"], "overlapping requests: \(events)")
}

private func checkCodexTimeoutRestart(mode: String) async throws {
    let executable = URL(
        fileURLWithPath: CommandLine.arguments[0],
        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ).standardizedFileURL
    let logURL = executable.deletingLastPathComponent()
        .appendingPathComponent("codex-usage-\(mode).log")
    try? FileManager.default.removeItem(at: logURL)
    FileManager.default.createFile(atPath: logURL.path, contents: Data())
    setenv("CODEX_USAGE_FAKE_MODE", mode, 1)
    defer {
        unsetenv("CODEX_USAGE_FAKE_MODE")
        try? FileManager.default.removeItem(at: logURL)
    }

    let watchdog = DispatchWorkItem {
        fputs("Codex timeout/restart check exceeded its outer bound\n", stderr)
        exit(1)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: watchdog)
    defer { watchdog.cancel() }

    let startedAt = Date()
    let usage: Usage
    do {
        usage = try await CodexUsageAPI(
            executableURL: executable,
            requestTimeout: .milliseconds(100)
        ).fetch()
    } catch {
        let events = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "<unreadable>"
        fputs("timeout/restart failure for \(mode): \(error); events: \(events)\n", stderr)
        throw error
    }
    let elapsed = Date().timeIntervalSince(startedAt)
    precondition(usage.limits.first?.percent == 17, "restarted server response was not parsed")
    precondition(elapsed < 0.5, "silent \(mode) server was not bounded: \(elapsed)s")

    let events = try String(contentsOf: logURL, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    let expected = mode == "silent-rate-first"
        ? ["launch", "initialize", "rate", "launch", "initialize", "rate"]
        : ["launch", "initialize", "launch", "initialize", "rate"]
    precondition(events == expected, "timeout/restart events for \(mode): \(events)")
}

private func checkTerminalCodexErrorDoesNotRestart() async throws {
    let executable = URL(
        fileURLWithPath: CommandLine.arguments[0],
        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ).standardizedFileURL
    let mode = "not-signed-in"
    let logURL = executable.deletingLastPathComponent()
        .appendingPathComponent("codex-usage-\(mode).log")
    try? FileManager.default.removeItem(at: logURL)
    FileManager.default.createFile(atPath: logURL.path, contents: Data())
    setenv("CODEX_USAGE_FAKE_MODE", mode, 1)
    defer {
        unsetenv("CODEX_USAGE_FAKE_MODE")
        try? FileManager.default.removeItem(at: logURL)
    }

    do {
        _ = try await CodexUsageAPI(executableURL: executable).fetch()
        preconditionFailure("not-signed-in response must fail")
    } catch CodexUsageError.notSignedIn {}

    let events = try String(contentsOf: logURL, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    precondition(
        events == ["launch", "initialize", "rate"],
        "terminal authentication failure restarted the app-server: \(events)"
    )
}

private enum FakeCodexAppServer {
    static func run() {
        signal(SIGPIPE, SIG_IGN)
        let input = FileHandle.standardInput
        var readBuffer = Data()

        let mode = ProcessInfo.processInfo.environment["CODEX_USAGE_FAKE_MODE"] ?? "concurrency"
        if mode != "concurrency" {
            appendLog("launch")
        }
        let launchNumber = mode == "concurrency" ? 1 : launchCount()

        guard let initialize = readLine(from: input, buffer: &readBuffer),
              isRequest(initialize, id: 0, method: "initialize") else {
            exit(1)
        }
        appendLog("initialize")
        if mode == "silent-initialize-first", launchNumber == 1 {
            Thread.sleep(forTimeInterval: 0.75)
            return
        }
        let emptyObject: [String: Any] = [:]
        var initializeResponses = encodedLine([
            "method": "remoteControl/status/changed",
            "params": emptyObject,
        ])
        initializeResponses.append(encodedLine(["id": 0, "result": emptyObject]))
        send(initializeResponses)

        guard let initialRate = readLine(from: input, buffer: &readBuffer),
              let initialID = requestID(initialRate),
              isRequest(initialRate, id: initialID, method: "account/rateLimits/read") else {
            exit(1)
        }
        appendLog("rate")
        if mode == "silent-rate-first", launchNumber == 1 {
            Thread.sleep(forTimeInterval: 0.75)
            return
        }
        if mode == "not-signed-in" {
            send(encodedLine([
                "id": initialID,
                "error": ["code": -32_000, "message": "authentication required"],
            ]))
            Thread.sleep(forTimeInterval: 0.5)
            return
        }
        writeRateLimitResponse(id: initialID)

        if mode != "concurrency" {
            Thread.sleep(forTimeInterval: 0.5)
            return
        }

        guard let concurrentRate = readLine(from: input, buffer: &readBuffer),
              let concurrentID = requestID(concurrentRate),
              isRequest(concurrentRate, id: concurrentID, method: "account/rateLimits/read") else {
            exit(1)
        }
        appendLog("rate")
        Thread.sleep(forTimeInterval: 0.2)
        let hasOverlap = hasAdditionalLine(from: input, buffer: &readBuffer)
        if hasOverlap {
            appendLog("overlap")
        }
        writeRateLimitResponse(id: concurrentID)

        if hasOverlap,
           let overlappingRate = readLine(from: input, buffer: &readBuffer),
           let overlappingID = requestID(overlappingRate),
           isRequest(overlappingRate, id: overlappingID, method: "account/rateLimits/read") {
            appendLog("rate")
            writeRateLimitResponse(id: overlappingID)
        }

        while let rate = readLine(from: input, buffer: &readBuffer),
              let id = requestID(rate),
              isRequest(rate, id: id, method: "account/rateLimits/read") {
            appendLog("rate")
            writeRateLimitResponse(id: id)
        }
    }

    private static func readLine(from input: FileHandle, buffer: inout Data) -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty { return line }
            }
            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = bytes.withUnsafeMutableBufferPointer {
                Darwin.read(Int32(input.fileDescriptor), $0.baseAddress, $0.count)
            }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: bytes.prefix(Int(count)))
        }
    }

    private static func hasAdditionalLine(from input: FileHandle, buffer: inout Data) -> Bool {
        if buffer.contains(0x0A) { return true }

        var descriptor = pollfd(
            fd: Int32(input.fileDescriptor),
            events: Int16(POLLIN),
            revents: 0
        )
        guard poll(&descriptor, 1, 0) > 0 else { return false }

        var bytes = [UInt8](repeating: 0, count: 8_192)
        let count = bytes.withUnsafeMutableBufferPointer {
            read(Int32(input.fileDescriptor), $0.baseAddress, $0.count)
        }
        guard count > 0 else { return false }
        buffer.append(contentsOf: bytes.prefix(Int(count)))
        return buffer.contains(0x0A)
    }

    private static func isRequest(_ data: Data, id: Int, method: String) -> Bool {
        guard let decoded = try? JSONSerialization.jsonObject(with: data),
              let object = decoded as? [String: Any] else {
            return false
        }
        return object["id"] as? Int == id && object["method"] as? String == method
    }

    private static func requestID(_ data: Data) -> Int? {
        guard let decoded = try? JSONSerialization.jsonObject(with: data),
              let object = decoded as? [String: Any] else {
            return nil
        }
        return object["id"] as? Int
    }

    private static func send(_ data: Data) {
        let count = data.withUnsafeBytes { bytes in
            Darwin.write(STDOUT_FILENO, bytes.baseAddress, bytes.count)
        }
        guard count == data.count else {
            appendLog("send-failed-\(errno)")
            exit(1)
        }
    }

    private static func encodedLine(_ object: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    private static func writeRateLimitResponse(id: Int) {
        send(encodedLine([
            "id": id,
            "result": [
                "rateLimits": [
                    "limitId": "codex",
                    "primary": [
                        "usedPercent": 17,
                        "windowDurationMins": 10_080,
                        "resetsAt": 1_789_954_384,
                    ],
                    "secondary": NSNull(),
                    "individualLimit": NSNull(),
                ],
                "rateLimitsByLimitId": NSNull(),
            ],
        ]))
    }

    private static func appendLog(_ event: String) {
        let logURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent(logFilename)
        guard let log = FileHandle(forWritingAtPath: logURL.path) else {
            exit(1)
        }
        defer { log.closeFile() }
        log.seekToEndOfFile()
        try! log.write(contentsOf: Data("\(event)\n".utf8))
    }

    private static var logFilename: String {
        let mode = ProcessInfo.processInfo.environment["CODEX_USAGE_FAKE_MODE"] ?? "concurrency"
        return "codex-usage-\(mode).log"
    }

    private static func launchCount() -> Int {
        let logURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent(logFilename)
        let events = (try? String(contentsOf: logURL, encoding: .utf8))?
            .split(separator: "\n") ?? []
        return events.filter { $0 == "launch" }.count
    }
}
