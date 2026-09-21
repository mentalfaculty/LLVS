//
//  AllColumnTypesTests.swift
//  LLVSProjectionTests
//
//  Created by Drew McCormack on 21/09/2026.
//

import Testing
import Foundation
@testable import LLVS
@testable import LLVSSQLite
@testable import LLVSModel
@testable import LLVSProjection

/// Every supported property type in one model, so no type reaches an app untested.
///
/// Two bugs got this far without such a test. A `Date` column held Codable's
/// seconds-since-2001, making ordinary SQL 31 years wrong, and a `Bool` was written to LLVS
/// as `1`, which `Codable` refuses, so the row silently vanished from every `fetch`. Both
/// were the same mistake: the SQLite type alone does not say how to convert, because `Int`,
/// `Bool` and `Date` are all `INTEGER`.
@MergeableModel
struct EveryType: StorableModel, Codable, Equatable {
    static let modelTypeIdentifier = "EveryType"
    var text: String = ""
    var count: Int = 0
    var ratio: Double = 0
    var flag: Bool = false
    var moment: Date = .init(timeIntervalSince1970: 0)
    var identifier: UUID = .init(uuidString: "00000000-0000-0000-0000-000000000000")!
    var payload: Data = .init()
    var optionalText: String? = nil
    var optionalFlag: Bool? = nil
    var tags: [String] = []
}

@Suite class AllColumnTypesTests {

    let store: Store
    let database: SQLiteDatabase
    let rootURL: URL
    let databaseURL: URL
    let table: OwnedTable

    /// Deliberately not round numbers, so a conversion that drops precision shows up.
    let sample = EveryType(
        text: "hello",
        count: -42,
        ratio: 3.5,
        flag: true,
        moment: Date(timeIntervalSince1970: 1758400000),
        identifier: UUID(uuidString: "A1B2C3D4-E5F6-4789-ABCD-1234567890AB")!,
        payload: Data([0x00, 0x01, 0xFE, 0xFF]),
        optionalText: "present",
        optionalFlag: true,
        tags: ["alpha", "beta"])

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try Store(rootDirectoryURL: rootURL)
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".sqlite")
        database = try SQLiteDatabase(fileURL: databaseURL)
        table = OwnedTable(
            typeIdentifier: EveryType.modelTypeIdentifier,
            tableName: "everything",
            schema: EveryType.sqliteSchema)
        for statement in table.createStatements() {
            try database.execute(statement: statement)
        }
    }

    deinit {
        try? database.close()
        try? FileManager.default.removeItem(at: databaseURL)
        try? FileManager.default.removeItem(at: rootURL)
    }

    @Test func everyPropertyGetsTheRightStorage() {
        let byProperty = Dictionary(uniqueKeysWithValues: EveryType.sqliteSchema.columns.map { ($0.propertyName, $0.storage) })
        #expect(byProperty["text"] == .text)
        #expect(byProperty["count"] == .integer)
        #expect(byProperty["ratio"] == .real)
        #expect(byProperty["flag"] == .boolean)
        #expect(byProperty["moment"] == .date)
        #expect(byProperty["identifier"] == .uuid)
        #expect(byProperty["payload"] == .blob)
        #expect(byProperty["optionalText"] == .text)
        #expect(byProperty["optionalFlag"] == .boolean)
        #expect(byProperty["tags"] == .json)
    }

    /// LLVS to the table and back: every value must survive unchanged.
    @Test func everyTypeSurvivesApplyThenFetch() throws {
        let data = try JSONEncoder().encode(sample)
        try table.apply([.insert(Value(id: .init("e1/EveryType"), data: data))], in: database)

        let rows = try table.fetch(EveryType.self, in: database)

        #expect(rows.count == 1, "a decode failure would silently return no rows")
        #expect(rows.first?.model == sample)
    }

    /// The table to LLVS: what a drain writes must decode as the same model.
    @Test func everyTypeSurvivesApplyThenDrain() throws {
        let data = try JSONEncoder().encode(sample)
        try table.apply([.insert(Value(id: .init("e1/EveryType"), data: data))], in: database)
        // The apply was suppressed, so make the row look like a local edit to drain it.
        try database.execute(statement: "UPDATE everything SET text = ? WHERE llvs_id = ?",
            withBindingsList: [["hello", "e1/EveryType"]])
        try database.execute(statement: "UPDATE everything SET text = ? WHERE llvs_id = ?",
            withBindingsList: [["changed", "e1/EveryType"]])

        let result = try table.drain(in: database, store: store, basedOn: nil)

        let versionId = try #require(result.version)
        let value = try #require(try store.value(id: .init("e1/EveryType"), at: versionId))
        let decoded = try JSONDecoder().decode(EveryType.self, from: value.data)

        var expected = sample
        expected.text = "changed"
        #expect(decoded == expected)
    }

    /// Nulls must reach optional properties as nil, not as a decode failure.
    @Test func optionalsSurviveAsNull() throws {
        var withoutOptionals = sample
        withoutOptionals.optionalText = nil
        withoutOptionals.optionalFlag = nil
        let data = try JSONEncoder().encode(withoutOptionals)

        try table.apply([.insert(Value(id: .init("e1/EveryType"), data: data))], in: database)

        var textIsNull = false
        var flagIsNull = false
        try database.forEach(matchingQuery: "SELECT optional_text IS NULL, optional_flag IS NULL FROM everything") { row in
            textIsNull = (row.value(inColumnAtIndex: 0) as Int64?) == 1
            flagIsNull = (row.value(inColumnAtIndex: 1) as Int64?) == 1
        }
        #expect(textIsNull)
        #expect(flagIsNull)

        let rows = try table.fetch(EveryType.self, in: database)
        #expect(rows.first?.model == withoutOptionals)
    }

    /// A Bool must be 0 or 1 in the column, so `WHERE flag = 1` works as anyone would expect.
    @Test func aBoolIsStoredAsZeroOrOne() throws {
        let data = try JSONEncoder().encode(sample)
        try table.apply([.insert(Value(id: .init("e1/EveryType"), data: data))], in: database)

        var matched = 0
        try database.forEach(matchingQuery: "SELECT llvs_id FROM everything WHERE flag = 1") { _ in matched += 1 }
        #expect(matched == 1)
    }

    /// A UUID is stored as its string, so it is readable and comparable in plain SQL.
    @Test func aUUIDIsStoredAsItsString() throws {
        let data = try JSONEncoder().encode(sample)
        try table.apply([.insert(Value(id: .init("e1/EveryType"), data: data))], in: database)

        var stored: String?
        try database.forEach(matchingQuery: "SELECT identifier FROM everything") { row in
            stored = row.value(inColumnAtIndex: 0)
        }
        #expect(stored == "A1B2C3D4-E5F6-4789-ABCD-1234567890AB")
    }

    /// Data is a real BLOB in the column, not base64 text, so SQL sees the bytes.
    @Test func dataIsStoredAsABlob() throws {
        let data = try JSONEncoder().encode(sample)
        try table.apply([.insert(Value(id: .init("e1/EveryType"), data: data))], in: database)

        var stored: Data?
        try database.forEach(matchingQuery: "SELECT payload FROM everything") { row in
            stored = row.value(inColumnAtIndex: 0)
        }
        #expect(stored == Data([0x00, 0x01, 0xFE, 0xFF]))
    }
}
