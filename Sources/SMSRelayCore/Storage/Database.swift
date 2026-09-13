import Foundation
import SQLite3

/// Minimal, thread-safe SQLite wrapper. All access is serialized on one queue;
/// this app's write volume is tiny so a single connection is plenty.
public final class Database: @unchecked Sendable {
    public struct Error: Swift.Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    private let queue = DispatchQueue(label: "smsrelay.sqlite")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var db: OpaquePointer?

    public init(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw Error(message: "cannot open database: \(msg)")
        }
        db = handle
        queue.setSpecific(key: queueKey, value: 1)
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA foreign_keys = ON")
        try exec("PRAGMA busy_timeout = 5000")
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    public func exec(_ sql: String) throws {
        try serialized {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let msg = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw Error(message: msg)
            }
        }
    }

    /// Runs `body` with a prepared statement. Bind parameters with `Statement.bind`, iterate with `step()`.
    public func withStatement<T>(_ sql: String, _ body: (Statement) throws -> T) throws -> T {
        try serialized {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw Error(message: "prepare failed: \(String(cString: sqlite3_errmsg(db))) — \(sql)")
            }
            defer { sqlite3_finalize(stmt) }
            return try body(Statement(stmt, db: db))
        }
    }

    public func run(_ sql: String, _ params: [SQLValue] = []) throws {
        try withStatement(sql) { s in
            try s.bind(params)
            _ = try s.step()
        }
    }

    /// Executes one statement and returns sqlite3_changes() without allowing another
    /// database operation to interleave and overwrite the connection-wide count.
    public func runChanges(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        try serialized {
            try withStatement(sql) { s in
                try s.bind(params)
                _ = try s.step()
            }
            return Int(sqlite3_changes(db))
        }
    }

    public func scalarInt(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        try withStatement(sql) { s in
            try s.bind(params)
            return try s.step() ? s.int(0) : 0
        }
    }

    public func lastInsertRowID() -> Int64 {
        serialized { sqlite3_last_insert_rowid(db) }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try serialized {
            try exec("BEGIN IMMEDIATE")
            do {
                let r = try body()
                try exec("COMMIT")
                return r
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    /// Transactions keep the queue for their entire body. Calls made by that body are
    /// re-entrant and execute directly instead of deadlocking on queue.sync.
    private func serialized<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }
}

public enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null

    public static func int(_ v: Int) -> SQLValue { .int(Int64(v)) }
    public static func date(_ d: Date?) -> SQLValue { d.map { .double($0.timeIntervalSince1970) } ?? .null }
    public static func optionalText(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
}

public struct Statement {
    fileprivate let stmt: OpaquePointer
    fileprivate let db: OpaquePointer?

    fileprivate init(_ stmt: OpaquePointer, db: OpaquePointer?) {
        self.stmt = stmt
        self.db = db
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public func bind(_ params: [SQLValue]) throws {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch p {
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case .null: rc = sqlite3_bind_null(stmt, idx)
            }
            guard rc == SQLITE_OK else { throw Database.Error(message: "bind failed at \(idx)") }
        }
    }

    /// Returns true when a row is available.
    public func step() throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw Database.Error(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    public func int(_ col: Int) -> Int { Int(sqlite3_column_int64(stmt, Int32(col))) }
    public func int64(_ col: Int) -> Int64 { sqlite3_column_int64(stmt, Int32(col)) }
    public func double(_ col: Int) -> Double { sqlite3_column_double(stmt, Int32(col)) }
    public func isNull(_ col: Int) -> Bool { sqlite3_column_type(stmt, Int32(col)) == SQLITE_NULL }
    public func text(_ col: Int) -> String? {
        guard let c = sqlite3_column_text(stmt, Int32(col)) else { return nil }
        return String(cString: c)
    }
    public func date(_ col: Int) -> Date? {
        isNull(col) ? nil : Date(timeIntervalSince1970: double(col))
    }
}
