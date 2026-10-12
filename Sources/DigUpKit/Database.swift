import Foundation
#if canImport(SQLite3)
import SQLite3   // the system's (3.51 on macOS 26, FTS5 built in)
#else
import CSQLite   // the amalgamation in Vendor/sqlite, with FTS5 (scripts/fetch-vendor.sh)
#endif

/// A thin wrapper over SQLite. One connection, used from one thread.
public final class Database {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    let handle: OpaquePointer
    /// Nesting depth of `transaction(_:)`; only the outermost call begins/commits the SQL transaction.
    private var transactionDepth = 0
    /// Prepared statements keyed by SQL text, reused across queries.
    private var statementCache: [String: Statement] = [:]

    public init(path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(db)
            throw Failure(message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        // Two processes opening a new index at once (a shell starts its search and index helpers together): the switch
        // to WAL can fail at once with "database is locked" rather than wait (SQLite's rule against deadlocks), so it's
        // tried again for up to five seconds.
        var tries = 0
        while true {
            do {
                try execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;")
                break
            } catch where sqlite3_errcode(db) == SQLITE_BUSY && tries < 50 {
                tries += 1
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    deinit { sqlite3_close_v2(handle) }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw Failure(message: "\(message) (in: \(sql.prefix(120)))")
        }
    }

    /// Runs `sql` with `values` bound and calls `row` for each result row.
    public func query(_ sql: String, _ values: [SQLValue] = [], row: (Statement) throws -> Void = { _ in }) throws {
        let statement = try cachedStatement(sql)
        try statement.reset()
        try statement.bind(values)
        while try statement.step() { try row(statement) }
    }

    /// Returns a cached prepared statement for `sql`, preparing (and caching) it on first use.
    /// Statements hold only the raw handle, so the cache never keeps `self` alive.
    private func cachedStatement(_ sql: String) throws -> Statement {
        if let cached = statementCache[sql] { return cached }
        let statement = try Statement(handle: handle, sql: sql)
        statementCache[sql] = statement
        return statement
    }

    public func run(_ sql: String, _ values: [SQLValue] = []) throws { try query(sql, values) }

    /// Reentrant: nested calls run their body inside the outermost transaction.
    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        guard transactionDepth == 0 else {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }
        try execute("BEGIN IMMEDIATE")
        transactionDepth = 1
        do {
            let result = try body()
            try execute("COMMIT")
            transactionDepth = 0
            return result
        } catch {
            try? execute("ROLLBACK")
            transactionDepth = 0
            throw error
        }
    }

    public var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }
    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }
}

public enum SQLValue {
    case int(Int64), double(Double), text(String), blob(Data), null

    static func optional(_ text: String?) -> SQLValue { text.map { .text($0) } ?? .null }
    static func optional(_ number: Double?) -> SQLValue { number.map { .double($0) } ?? .null }
}

public final class Statement {
    private let statement: OpaquePointer
    /// Raw connection handle (not the Database object) so a Database-owned statement cache
    /// cannot form a retain cycle that prevents Database.deinit from running.
    private let handle: OpaquePointer

    init(handle: OpaquePointer, sql: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Database.Failure(message: "\(String(cString: sqlite3_errmsg(handle))) (in: \(sql.prefix(160)))")
        }
        self.statement = statement
        self.handle = handle
    }

    deinit { sqlite3_finalize(statement) }

    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    /// Resets the statement and clears previous bindings so it can be reused from the cache.
    func reset() throws {
        let status = sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        guard status == SQLITE_OK else { throw Database.Failure(message: errorMessage) }
    }

    func bind(_ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .int(let number): status = sqlite3_bind_int64(statement, index, number)
            case .double(let number): status = sqlite3_bind_double(statement, index, number)
            case .text(let text): status = sqlite3_bind_text(statement, index, text, -1, transient)
            case .blob(let data):
                status = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw Database.Failure(message: errorMessage) }
        }
    }

    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw Database.Failure(message: errorMessage)
        }
    }

    public func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    public func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    public func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

    public func text(_ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    public func blob(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}

/// SQLITE_TRANSIENT: SQLite copies bound text/blobs, so Swift's temporary buffers are safe to pass.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
