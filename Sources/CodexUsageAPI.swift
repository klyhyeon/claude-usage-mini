import Darwin
import Dispatch
import Foundation

enum CodexUsageError: LocalizedError, Equatable {
    case cliNotFound
    case notSignedIn
    case connectionFailed
    case malformedResponse
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .cliNotFound: "Codex CLI was not found."
        case .notSignedIn: "Codex is not signed in. Run codex login."
        case .connectionFailed: "Could not connect to Codex."
        case .malformedResponse: "Codex returned an unsupported usage response."
        case .requestTimedOut: "Codex did not respond in time."
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
        if let session = windows.first(where: { $0.windowDurationMins == 300 }) {
            limits.append(UsageLimit(
                id: "codex-session",
                title: "Session Usage",
                badge: nil,
                subtitle: "5-hour window",
                percent: clamp(session.usedPercent),
                resetsAt: session.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ))
        }
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

private final class CodexLineReader: @unchecked Sendable {
    private typealias Waiter = (
        id: UUID,
        continuation: CheckedContinuation<Data, any Error>
    )

    private static let maximumBufferSize = 1_048_576

    private let queue = DispatchQueue(label: "CodexLineReader")
    private let source: DispatchSourceRead
    private let descriptor: Int32
    private var buffer = Data()
    private var waiter: Waiter?
    private var cancelledWaiters: Set<UUID> = []
    private var terminalError: CodexUsageError?

    init(output: FileHandle) {
        descriptor = Int32(output.fileDescriptor)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)

        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }

        source.setEventHandler { [weak self] in
            self?.readAvailableBytes()
        }
        source.resume()
    }

    func nextLine() async throws -> Data {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: CodexUsageError.connectionFailed)
                        return
                    }
                    self.register(id: id, continuation: continuation)
                }
            }
        } onCancel: {
            self.queue.async { [weak self] in
                self?.cancelWaiter(id: id)
            }
        }
    }

    func cancel() {
        queue.sync {
            finish(with: .connectionFailed)
        }
    }

    private func register(
        id: UUID,
        continuation: CheckedContinuation<Data, any Error>
    ) {
        if cancelledWaiters.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }
        if let terminalError {
            continuation.resume(throwing: terminalError)
            return
        }
        guard waiter == nil else {
            continuation.resume(throwing: CodexUsageError.connectionFailed)
            return
        }
        waiter = (id, continuation)
        deliverBufferedLineIfPossible()
    }

    private func cancelWaiter(id: UUID) {
        guard waiter?.id == id else {
            cancelledWaiters.insert(id)
            return
        }
        let continuation = waiter?.continuation
        waiter = nil
        continuation?.resume(throwing: CancellationError())
    }

    private func readAvailableBytes() {
        guard terminalError == nil else { return }

        var bytes = [UInt8](repeating: 0, count: 8_192)
        let count = bytes.withUnsafeMutableBufferPointer {
            Darwin.read(descriptor, $0.baseAddress, $0.count)
        }
        if count > 0 {
            buffer.append(contentsOf: bytes.prefix(Int(count)))
            guard buffer.count <= Self.maximumBufferSize else {
                finish(with: .malformedResponse)
                return
            }
            deliverBufferedLineIfPossible()
        } else if count == 0 {
            finish(with: .connectionFailed)
        } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            finish(with: .connectionFailed)
        }
    }

    private func deliverBufferedLineIfPossible() {
        guard let waiter else { return }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }

            self.waiter = nil
            waiter.continuation.resume(returning: line)
            return
        }
    }

    private func finish(with error: CodexUsageError) {
        guard terminalError == nil else { return }
        terminalError = error
        source.cancel()
        let continuation = waiter?.continuation
        waiter = nil
        continuation?.resume(throwing: error)
    }
}

actor CodexUsageAPI {
    private let suppliedExecutableURL: URL?
    private let requestTimeout: Duration
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var input: FileHandle?
    private var output: FileHandle?
    private var lineReader: CodexLineReader?
    private var nextID = 1
    private var activeFetch: (id: UUID, task: Task<Usage, Error>)?

    init(executableURL: URL? = nil, requestTimeout: Duration = .seconds(8)) {
        suppliedExecutableURL = executableURL
        self.requestTimeout = requestTimeout
    }

    func fetch() async throws -> Usage {
        if let activeFetch {
            return try await awaitFetch(id: activeFetch.id, task: activeFetch.task)
        }

        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { throw CodexUsageError.connectionFailed }
            return try await self.fetchWithRetry()
        }
        activeFetch = (id, task)
        return try await awaitFetch(id: id, task: task)
    }

    private func awaitFetch(id: UUID, task: Task<Usage, Error>) async throws -> Usage {
        do {
            let usage = try await task.value
            clearActiveFetch(id: id)
            return usage
        } catch {
            clearActiveFetch(id: id)
            throw error
        }
    }

    private func clearActiveFetch(id: UUID) {
        guard activeFetch?.id == id else { return }
        activeFetch = nil
    }

    private func fetchWithRetry() async throws -> Usage {
        do {
            return try await fetchOnce()
        } catch {
            let firstError = Self.codexError(from: error)
            guard Self.shouldRetry(firstError) else { throw firstError }
            stop()
            do {
                return try await fetchOnce()
            } catch {
                let retryError = Self.codexError(from: error)
                if Self.shouldRetry(retryError) {
                    stop()
                }
                throw retryError
            }
        }
    }

    private static func codexError(from error: any Error) -> CodexUsageError {
        error as? CodexUsageError ?? .connectionFailed
    }

    private static func shouldRetry(_ error: CodexUsageError) -> Bool {
        switch error {
        case .cliNotFound, .notSignedIn:
            false
        case .connectionFailed, .malformedResponse, .requestTimedOut:
            true
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
        do {
            try process.run()
        } catch {
            stdin.fileHandleForReading.closeFile()
            stdin.fileHandleForWriting.closeFile()
            stdout.fileHandleForReading.closeFile()
            stdout.fileHandleForWriting.closeFile()
            throw CodexUsageError.connectionFailed
        }

        self.process = process
        stdinPipe = stdin
        stdoutPipe = stdout
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        lineReader = CodexLineReader(output: stdout.fileHandleForReading)
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
        do {
            try input.write(contentsOf: data)
        } catch {
            throw CodexUsageError.connectionFailed
        }
    }

    private func request(id: Int, method: String, params: [String: Any]) async throws -> Data {
        try write(id: id, method: method, params: params)
        guard let lineReader else { throw CodexUsageError.connectionFailed }

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await Self.response(id: id, from: lineReader)
            }
            group.addTask { [requestTimeout] in
                try await Task.sleep(for: requestTimeout)
                throw CodexUsageError.requestTimedOut
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else {
                throw CodexUsageError.connectionFailed
            }
            return response
        }
    }

    private static func response(id: Int, from lineReader: CodexLineReader) async throws -> Data {
        while true {
            let line = try await lineReader.nextLine()
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw CodexUsageError.malformedResponse
            }
            if (object["id"] as? Int) == id { return line }
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
            stdinPipe = nil
            stdoutPipe = nil
            input = nil
            output = nil
            lineReader?.cancel()
            lineReader = nil
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
        lineReader?.cancel()
        lineReader = nil
        input?.closeFile()
        output?.closeFile()
        stdinPipe = nil
        stdoutPipe = nil
        process = nil
        input = nil
        output = nil
    }
}
