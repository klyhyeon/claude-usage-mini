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

private struct ResponseEnvelope: Decodable {
    let result: RateLimitsResult?
    let error: RPCError?

    private enum CodingKeys: String, CodingKey {
        case result
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decodeIfPresent(RateLimitsResult.self, forKey: .result)
        error = try container.decodeIfPresent(RPCError.self, forKey: .error)
    }
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

    private func startIfNeeded() async throws {
        if process?.isRunning == true { return }
        if let process {
            clearState(for: process)
        }
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
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { [weak self] in
                await self?.handleTermination(of: terminatedProcess)
            }
        }

        let initialize = try await request(
            id: 0,
            method: "initialize",
            params: ["clientInfo": ["name": "claude-usage-mini", "version": "0.1.0"]]
        )
        guard let initializeResponse = try JSONSerialization.jsonObject(with: initialize) as? [String: Any],
              initializeResponse["result"] != nil,
              initializeResponse["error"] == nil else {
            throw CodexUsageError.connectionFailed
        }
    }

    private func write(id: Int, method: String, params: [String: Any]) throws {
        guard let input else { throw CodexUsageError.connectionFailed }
        let data = try CodexRequestEncoder.encode(id: id, method: method, params: params)
        try input.write(contentsOf: data)
    }

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
        guard let process else {
            input?.closeFile()
            output?.closeFile()
            input = nil
            output = nil
            readBuffer.removeAll(keepingCapacity: false)
            return
        }
        if process.isRunning { process.terminate() }
        clearState(for: process)
    }

    private func handleTermination(of terminatedProcess: Process) {
        clearState(for: terminatedProcess)
    }

    private func clearState(for terminatedProcess: Process) {
        guard process === terminatedProcess else { return }
        input?.closeFile()
        output?.closeFile()
        process = nil
        input = nil
        output = nil
        readBuffer.removeAll(keepingCapacity: false)
    }
}
