import AppKit
import Foundation
import SQLite3

enum TaskActivity: Equatable, Sendable {
    case active, idle, unknown
    var label: String {
        switch self {
        case .active: "任务运行中"
        case .idle: "当前闲置"
        case .unknown: "任务状态未知"
        }
    }
    var refreshSeconds: Double { self == .active ? 10 : 900 }
}

protocol TaskActivityProviding: Sendable {
    func readActivity() async -> TaskActivity
}

/// Reads only turn lifecycle metadata, never thread items, prompts, or responses.
/// The history database is an internal Codex format; unsupported schemas fail to unknown.
struct DesktopTaskActivityProvider: TaskActivityProviding {
    func readActivity() async -> TaskActivity {
        let appState: (Bool, Date?) = await MainActor.run {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            return (!apps.isEmpty, apps.compactMap(\.launchDate).min())
        }
        guard appState.0 else { return .idle }
        guard let launchedAt = appState.1 else { return .unknown }
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return TaskActivityDatabase.read(at: home.appendingPathComponent("thread_history_1.sqlite"), since: launchedAt)
    }
}

enum TaskActivityDatabase {
    static func read(at url: URL, since launchDate: Date) -> TaskActivity {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return .unknown
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let query = """
            SELECT status FROM thread_turns AS current
            WHERE completed_at IS NULL AND (started_at >= ? OR started_at IS NULL)
              AND NOT EXISTS (
                SELECT 1 FROM thread_turns AS newer
                WHERE newer.thread_id = current.thread_id
                  AND newer.rollout_ordinal > current.rollout_ordinal
              )
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return .unknown }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(launchDate.timeIntervalSince1970))
        var unknown = false
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let value = sqlite3_column_text(statement, 0) else { return .unknown }
                let status = String(cString: value)
                if status == "inProgress" { return .active }
                if !["completed", "failed", "interrupted"].contains(status) { unknown = true }
            case SQLITE_DONE: return unknown ? .unknown : .idle
            default: return .unknown
            }
        }
    }
}
