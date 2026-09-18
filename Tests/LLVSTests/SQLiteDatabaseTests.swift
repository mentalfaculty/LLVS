import Testing
import Foundation
@testable import LLVSSQLite

@Suite class SQLiteDatabaseTests {

    let fileURL: URL
    let database: SQLiteDatabase

    init() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".sqlite")
        database = try SQLiteDatabase(fileURL: fileURL)
        try database.execute(statement: "CREATE TABLE T (a TEXT, b TEXT, d BLOB)")
    }

    deinit {
        try? database.close()
        try? FileManager.default.removeItem(at: fileURL)
    }

    @Test func emptyBlobReadsAsEmptyData() throws {
        try database.execute(statement: "INSERT INTO T (a, d) VALUES (?, ?)", withBindingsList: [["x", Data()]])
        var result: Data?
        try database.forEach(matchingQuery: "SELECT d FROM T") { row in
            result = row.value(inColumnAtIndex: 0)
        }
        #expect(result == Data())
    }

    @Test func nullIsDetectedInTheRequestedColumn() throws {
        try database.execute(statement: "INSERT INTO T (a, b) VALUES (?, ?)", withBindingsList: [[nil, "second"]])
        var first: String? = "unset"
        var second: String?
        try database.forEach(matchingQuery: "SELECT a, b FROM T") { row in
            first = row.value(inColumnAtIndex: 0)
            second = row.value(inColumnAtIndex: 1)
        }
        #expect(first == nil)
        #expect(second == "second")
    }

    @Test func nullInALaterColumnReadsAsNil() throws {
        try database.execute(statement: "INSERT INTO T (a, b) VALUES (?, ?)", withBindingsList: [["first", nil]])
        var second: String? = "unset"
        try database.forEach(matchingQuery: "SELECT a, b FROM T") { row in
            second = row.value(inColumnAtIndex: 1)
        }
        #expect(second == nil)
    }

    @Test func errorWhileSteppingThroughRowsIsThrown() throws {
        // abs() of the most negative integer overflows. SQLite reports that when the row is stepped, not when prepared.
        #expect(throws: (any Error).self) {
            try self.database.forEach(matchingQuery: "SELECT abs(-9223372036854775807 - 1)") { _ in }
        }
    }
}
