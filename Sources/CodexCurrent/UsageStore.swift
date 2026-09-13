import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .unavailable
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshIntervalIndex: Int
    @Published private(set) var automaticRefresh: Bool
    @Published private(set) var taskActivity: TaskActivity = .unknown
    static let activitySamplingSeconds: Double = 5
    private let activityProvider: (any TaskActivityProviding)?
    private var activityTask: Task<Void, Never>?
    var effectiveRefreshSeconds: Double {
        automaticRefresh ? taskActivity.refreshSeconds : RefreshInterval.seconds[refreshIntervalIndex]
    }
    private let provider: any CodexUsageProviding
    private let defaults: UserDefaults
    private var refreshTask: Task<Void, Never>?
    private var pendingActivityRefresh = false

    init(provider: any CodexUsageProviding, defaults: UserDefaults = .standard, activityProvider: (any TaskActivityProviding)? = nil) {
        self.provider = provider
        self.activityProvider = activityProvider
        automaticRefresh = defaults.object(forKey: "automaticRefreshEnabled") as? Bool ?? true
        self.defaults = defaults
        refreshIntervalIndex = RefreshInterval.index(for: defaults.double(forKey: RefreshInterval.defaultsKey))
        refresh()
        scheduleRefresh()
        activityTask = Task { [weak self, activityProvider] in
            guard let activityProvider else { return }
            while !Task.isCancelled {
                let activity = await activityProvider.readActivity()
                guard !Task.isCancelled else { return }
                self?.updateActivity(activity)
                do { try await Task.sleep(for: .seconds(Self.activitySamplingSeconds)) }
                catch { return }
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        activityTask?.cancel()
    }

    func setAutomaticRefresh(_ enabled: Bool) {
        guard enabled != automaticRefresh else { return }
        automaticRefresh = enabled
        defaults.set(enabled, forKey: "automaticRefreshEnabled")
        scheduleRefresh()
        if enabled { refresh() }
    }

    func updateActivity(_ activity: TaskActivity) {
        guard activity != taskActivity else { return }
        let previous = taskActivity
        let previousInterval = effectiveRefreshSeconds
        taskActivity = activity
        guard automaticRefresh else { return }
        if effectiveRefreshSeconds != previousInterval { scheduleRefresh() }
        // Fetch at both boundaries so a finished task's final usage isn't delayed by 15 minutes.
        if activity == .active || previous == .active {
            if isRefreshing { pendingActivityRefresh = true }
            else { refresh() }
        }
    }

    func setRefreshInterval(index: Int) {
        guard RefreshInterval.seconds.indices.contains(index), index != refreshIntervalIndex else { return }
        refreshIntervalIndex = index
        defaults.set(RefreshInterval.seconds[index], forKey: RefreshInterval.defaultsKey)
        if !automaticRefresh { scheduleRefresh() }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        let interval = effectiveRefreshSeconds
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { [provider] in
            snapshot = await provider.fetchSnapshot()
            isRefreshing = false
            if pendingActivityRefresh {
                pendingActivityRefresh = false
                refresh()
            }
        }
    }
}

struct CLIUsageProvider: CodexUsageProviding {
    private let timeout: Duration

    init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    func fetchSnapshot() async -> UsageSnapshot {
        do {
            let executable = try CLIExecutableResolver().resolve()
            let version = try await CodexCLIInspector(executable: executable).version()
            guard try await CodexCLIInspector(executable: executable).isLoggedIn() else {
                return .failure(.loginRequired(version: version.description), version: version.description)
            }
            return try await AppServerUsageClient(
                executable: executable,
                timeout: timeout
            ).readRateLimits(version: version.description)
        } catch CLIUsageError.notInstalled {
            return .failure(.cliNotInstalled)
        } catch CLIUsageError.versionUnavailable {
            return .failure(.versionUnavailable)
        } catch CLIUsageError.timedOut {
            return .failure(.timedOut)
        } catch let CLIUsageError.incompatible(version) {
            return .failure(.incompatible(version: version), version: version)
        } catch {
            return .failure(.serviceUnavailable)
        }
    }
}

enum CLIUsageError: Error, Equatable {
    case notInstalled
    case versionUnavailable
    case incompatible(String?)
    case timedOut
    case rpc(String)
}

struct CodexCLIVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    var description: String { "\(major).\(minor).\(patch)" }

    init?(output: String) {
        let components = output
            .split(whereSeparator: { !$0.isNumber && $0 != "." })
            .first(where: { $0.contains(".") })?
            .split(separator: ".")
        guard let components, components.count >= 2,
              let major = Int(components[0]),
              let minor = Int(components[1]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = components.count > 2 ? Int(components[2]) ?? 0 : 0
    }

    static func < (lhs: CodexCLIVersion, rhs: CodexCLIVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct CLIExecutableResolver {
    var homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    var environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    var isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }

    func resolve() throws -> URL {
        var paths = environmentPath
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path }
        paths.append(contentsOf: [
            homeDirectory.appendingPathComponent(".local/bin/codex").path,
            homeDirectory.appendingPathComponent(".npm-global/bin/codex").path,
            homeDirectory.appendingPathComponent(".npm/bin/codex").path,
            homeDirectory.appendingPathComponent(".volta/bin/codex").path,
            homeDirectory.appendingPathComponent(".asdf/shims/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ])

        var seen = Set<String>()
        if let path = paths.first(where: { seen.insert($0).inserted && isExecutable($0) }) {
            return URL(fileURLWithPath: path)
        }
        throw CLIUsageError.notInstalled
    }
}

private struct CodexCLIInspector {
    let executable: URL

    func version() async throws -> CodexCLIVersion {
        let result = try await ProcessRunner.run(executable, arguments: ["--version"], timeout: .seconds(3))
        guard result.exitCode == 0, let version = CodexCLIVersion(output: result.standardOutput) else {
            throw CLIUsageError.versionUnavailable
        }
        return version
    }

    func isLoggedIn() async throws -> Bool {
        let result = try await ProcessRunner.run(
            executable,
            arguments: ["login", "status"],
            timeout: .seconds(3)
        )
        return result.exitCode == 0
    }
}

private struct ProcessResult: Sendable {
    let exitCode: Int32
    let standardOutput: String
}

private final class ProcessTerminator: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func register(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func unregister() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let process = process
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

private enum ProcessRunner {
    static func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessResult {
        let terminator = ProcessTerminator()
        return try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask {
                let process = Process()
                let output = Pipe()
                terminator.register(process)
                defer { terminator.unregister() }
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = Pipe()
                try process.run()
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                return ProcessResult(
                    exitCode: process.terminationStatus,
                    standardOutput: String(decoding: data, as: UTF8.self)
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                terminator.terminate()
                throw CLIUsageError.timedOut
            }
            guard let result = try await group.next() else { throw CLIUsageError.timedOut }
            group.cancelAll()
            return result
        }
    }
}

/// A deliberately small client for the local App Server surface. It requests only the account
/// rate-limit snapshot and never reads threads, prompts, or task metadata.
private struct AppServerUsageClient: Sendable {
    let executable: URL
    let timeout: Duration

    func readRateLimits(version: String) async throws -> UsageSnapshot {
        let terminator = ProcessTerminator()
        do {
            return try await withThrowingTaskGroup(of: UsageSnapshot.self) { group in
                group.addTask { try await performRead(version: version, terminator: terminator) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    terminator.terminate()
                    throw CLIUsageError.timedOut
                }
                guard let snapshot = try await group.next() else { throw CLIUsageError.timedOut }
                group.cancelAll()
                return snapshot
            }
        } catch is DecodingError {
            throw CLIUsageError.incompatible(version)
        }
    }

    private func performRead(version: String, terminator: ProcessTerminator) async throws -> UsageSnapshot {
        let process = Process()
        terminator.register(process)
        defer { terminator.unregister() }
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        try send([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "CodexCurrent", "version": "1.0.0"],
                "capabilities": ["experimentalApi": true]
            ]
        ], to: input.fileHandleForWriting)

        var lines = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
        while let line = try await lines.next() {
            guard let envelope = try? JSONDecoder().decode(RPCEnvelope.self, from: Data(line.utf8)) else {
                continue
            }
            guard envelope.id == 1 else { continue }
            if let error = envelope.error { throw CLIUsageError.rpc(error.message) }
            try send(["method": "initialized"], to: input.fileHandleForWriting)
            try send(["id": 2, "method": "account/rateLimits/read", "params": NSNull()], to: input.fileHandleForWriting)
            break
        }

        while let line = try await lines.next() {
            guard let envelope = try? JSONDecoder().decode(RPCEnvelope.self, from: Data(line.utf8)),
                  envelope.id == 2 else { continue }
            if let error = envelope.error {
                if error.message.localizedCaseInsensitiveContains("method") {
                    throw CLIUsageError.incompatible(version)
                }
                throw CLIUsageError.rpc(error.message)
            }
            let response = try JSONDecoder().decode(RateLimitsResponseEnvelope.self, from: Data(line.utf8))
            return RateLimitMapper.snapshot(from: response.result, version: version)
        }

        throw CocoaError(.fileReadUnknown)
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }
}

private struct RPCEnvelope: Decodable {
    let id: Int?
    let error: RPCError?
}

private struct RPCError: Decodable {
    let message: String
}

private struct RateLimitsResponseEnvelope: Decodable { let result: RateLimitsPayload }

struct RateLimitsPayload: Decodable {
    let rateLimits: RateLimitBucket
    let rateLimitsByLimitId: [String: RateLimitBucket]?
    let rateLimitResetCredits: RateLimitResetCredits?
}

struct RateLimitBucket: Decodable {
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

struct RateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?
}

struct RateLimitResetCredits: Decodable {
    let availableCount: Int?
    var credits: [RateLimitResetCredit]? = nil
}

struct RateLimitResetCredit: Decodable {
    let id: String
    let expiresAt: TimeInterval?
    let status: String
    let title: String?
}

enum RateLimitMapper {
    static func snapshot(from payload: RateLimitsPayload, version: String) -> UsageSnapshot {
        // Prefer Codex's named bucket when the server supplies a multi-bucket response.
        let bucket = payload.rateLimitsByLimitId?["codex"] ?? payload.rateLimits
        guard bucket.primary != nil || bucket.secondary != nil else {
            return UsageSnapshot(primaryWindow: nil, secondaryWindow: nil,
                                 availableResetCount: availableResetCount(from: payload),
                                 status: .idle,
                                 source: .live, updatedAt: .now,
                                 message: L10n.text("usage.noWindows"),
                                 cliVersion: version, problem: nil, resetCredits: resetCredits(from: payload))
        }
        return UsageSnapshot(
            primaryWindow: bucket.primary.map(mapWindow),
            secondaryWindow: bucket.secondary.map(mapWindow),
            availableResetCount: availableResetCount(from: payload),
            status: .idle, source: .live, updatedAt: .now, message: nil,
            cliVersion: version, problem: nil, resetCredits: resetCredits(from: payload)
        )
    }

    private static func mapWindow(_ window: RateLimitWindow) -> UsageLimitWindow {
        UsageLimitWindow(
            remainingPercent: max(0, min(100, 100 - window.usedPercent)),
            resetDate: window.resetsAt.map { Date(timeIntervalSince1970: $0) },
            durationMinutes: window.windowDurationMins
        )
    }

    private static func resetCredits(from payload: RateLimitsPayload) -> [ResetCredit]? {
        payload.rateLimitResetCredits?.credits?.filter { $0.status == "available" }.map {
            ResetCredit(id: $0.id, expiresAt: $0.expiresAt.map { Date(timeIntervalSince1970: $0) }, title: $0.title)
        }.sorted {
            let lhs = $0.expiresAt ?? .distantFuture
            let rhs = $1.expiresAt ?? .distantFuture
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
    }

    private static func availableResetCount(from payload: RateLimitsPayload) -> Int? {
        guard let count = payload.rateLimitResetCredits?.availableCount, count >= 0 else { return nil }
        return count
    }
}
