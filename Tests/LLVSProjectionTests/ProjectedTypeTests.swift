//
//  ProjectedTypeTests.swift
//  LLVSProjectionTests
//
//  Created by Drew McCormack on 20/09/2026.
//

import Testing
import Foundation
@testable import LLVS
@testable import LLVSProjection

@Suite struct ProjectedTypeTests {

    @Test func buildsACreateTableStatement() {
        let type = ProjectedType(
            typeIdentifier: "Note",
            tableName: "notes",
            columns: [
                ProjectedColumn(name: "title", declaration: "TEXT"),
                ProjectedColumn(name: "updated_at", declaration: "INTEGER"),
            ],
            extract: { _ in [:] }
        )
        #expect(type.createTableStatement() ==
            "CREATE TABLE IF NOT EXISTS notes (llvs_id TEXT PRIMARY KEY, title TEXT, updated_at INTEGER)")
    }

    @Test func aTableWithNoColumnsStillCarriesTheIdentifier() {
        let type = ProjectedType(typeIdentifier: "Note", tableName: "notes", columns: [], extract: { _ in [:] })
        #expect(type.createTableStatement() == "CREATE TABLE IF NOT EXISTS notes (llvs_id TEXT PRIMARY KEY)")
    }

    @Test func acceptsPlainIdentifiers() {
        #expect(ProjectedType.isPlainIdentifier("notes"))
        #expect(ProjectedType.isPlainIdentifier("_private"))
        #expect(ProjectedType.isPlainIdentifier("updated_at2"))
    }

    @Test func rejectsIdentifiersSQLiteWouldNotTakeUnquoted() {
        #expect(!ProjectedType.isPlainIdentifier(""))
        #expect(!ProjectedType.isPlainIdentifier("2fast"))          // leading digit
        #expect(!ProjectedType.isPlainIdentifier("my table"))       // space
        #expect(!ProjectedType.isPlainIdentifier("notes-archive"))  // hyphen
        #expect(!ProjectedType.isPlainIdentifier("notes\"; DROP"))  // quote
        #expect(!ProjectedType.isPlainIdentifier("notas_españolas")) // non-ASCII letter
    }

    @Test func extractReturnsTheColumnValues() throws {
        let type = ProjectedType(
            typeIdentifier: "Note",
            tableName: "notes",
            columns: [ProjectedColumn(name: "title", declaration: "TEXT")],
            extract: { value in ["title": .text(String(decoding: value.data, as: UTF8.self))] }
        )
        let row = try type.extract(Value(id: .init("abc/Note"), data: "Hello".data(using: .utf8)!))
        #expect(row["title"] == .text("Hello"))
    }
}
