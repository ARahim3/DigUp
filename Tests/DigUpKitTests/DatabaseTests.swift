import Foundation
import Testing
@testable import DigUpKit

@Suite struct DatabaseTests {
    @Test func reusedStatementsClearBindingsAndRecoverFromErrors() throws {
        let db = try Database(path: ":memory:")
        try db.execute("CREATE TABLE items(id INTEGER PRIMARY KEY, value TEXT)")
        try db.run("INSERT INTO items VALUES(?, ?)", [.int(1), .text("first")])
        #expect(throws: Database.Failure.self) {
            try db.run("INSERT INTO items VALUES(?, ?)", [.int(1), .text("duplicate")])
        }
        #expect(throws: Database.Failure.self) {
            try db.run("INSERT INTO items VALUES(?, ?)", [.int(2)])
        }
        try db.run("INSERT INTO items VALUES(?, ?)", [.int(2), .null])
        var rows: [String?] = []
        try db.query("SELECT value FROM items ORDER BY id") { rows.append($0.text(0)) }
        #expect(rows == ["first", nil])
        #expect(throws: Database.Failure.self) {
            try db.transaction {
                try db.run("INSERT INTO items VALUES(?, ?)", [.int(3), .text("rolled back")])
                try db.run("INSERT INTO items VALUES(?, ?)", [.int(2), .text("duplicate")])
            }
        }
        try db.transaction { try db.run("INSERT INTO items VALUES(?, ?)", [.int(3), .text("committed")]) }
        try db.query("SELECT value FROM items WHERE id = ?", [.int(3)]) { #expect($0.text(0) == "committed") }
    }

    @Test func recursiveQueriesAndRetainedRowsKeepTheirOwnStatements() throws {
        let db = try Database(path: ":memory:")
        for _ in 0..<2 {
            try db.query("SELECT ?", [.text("outer")]) { outer in
                try db.query("SELECT ?", [.text("inner")]) { #expect($0.text(0) == "inner") }
                #expect(outer.text(0) == "outer")
            }
        }
        var saved: Statement?
        struct Stop: Error {}
        #expect(throws: Stop.self) {
            try db.query("SELECT ?", [.text("saved")]) { saved = $0; throw Stop() }
        }
        try db.query("SELECT ?", [.text("next")]) { #expect($0.text(0) == "next") }
        #expect(saved?.text(0) == "saved")
    }

    @Test func cachedQueriesRecompileAfterSchemaChanges() throws {
        let db = try Database(path: ":memory:")
        try db.execute("CREATE TABLE items(value TEXT); INSERT INTO items VALUES('old')")
        try db.query("SELECT * FROM items") { #expect($0.text(0) == "old") }
        try db.execute("ALTER TABLE items ADD COLUMN extra TEXT; UPDATE items SET extra = 'new'")
        try db.query("SELECT * FROM items") { #expect($0.text(1) == "new") }
        // More distinct queries than the cache holds, followed by another use of the original query.
        for i in 0..<100 { try db.query("SELECT \(i)") { #expect($0.int(0) == Int64(i)) } }
        try db.query("SELECT * FROM items") { #expect($0.text(1) == "new") }
    }
}
