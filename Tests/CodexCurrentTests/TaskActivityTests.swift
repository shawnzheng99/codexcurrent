import Foundation
import SQLite3
import Testing
@testable import CodexCurrent

@Test func activityDatabaseHandlesCompletionMultipleTasksAndOldSessions() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: path) }
    var db: OpaquePointer?
    #expect(sqlite3_open(path.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
    try execute("CREATE TABLE thread_turns(thread_id TEXT, rollout_ordinal INTEGER, status TEXT, started_at INTEGER, completed_at INTEGER)")
    let launch = Date(timeIntervalSince1970: 100)
    #expect(TaskActivityDatabase.read(at: path, since: launch) == .idle)
    try execute("INSERT INTO thread_turns VALUES('old',0,'inProgress',50,NULL)")
    #expect(TaskActivityDatabase.read(at: path, since: launch) == .idle)
    try execute("INSERT INTO thread_turns VALUES('a',0,'inProgress',110,NULL),('b',0,'inProgress',120,NULL)")
    #expect(TaskActivityDatabase.read(at: path, since: launch) == .active)
    try execute("UPDATE thread_turns SET status='completed',completed_at=130 WHERE thread_id='a'")
    #expect(TaskActivityDatabase.read(at: path, since: launch) == .active)
    try execute("UPDATE thread_turns SET status='interrupted',completed_at=140 WHERE thread_id='b'")
    #expect(TaskActivityDatabase.read(at: path, since: launch) == .idle)
    try execute("INSERT INTO thread_turns VALUES('a',1,'inProgress',150,NULL),('a',2,'completed',160,170)")
    #expect(TaskActivityDatabase.read(at: path, since: launch) == .idle)
    try execute("INSERT INTO thread_turns VALUES('c',0,'futureStatus',180,NULL)")
    #expect(TaskActivityDatabase.read(at: path, since: launch) == .unknown)
}

@Test func activityDatabaseDoesNotCreateMissingFile() {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    #expect(TaskActivityDatabase.read(at: missing, since: .distantPast) == .unknown)
    #expect(!FileManager.default.fileExists(atPath: missing.path))
}
