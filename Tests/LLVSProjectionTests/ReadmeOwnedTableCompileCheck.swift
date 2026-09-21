//
//  ReadmeOwnedTableCompileCheck.swift
//  LLVSProjectionTests
//
//  Created by Drew McCormack on 21/09/2026.
//

// The README's Local-First SQLite example, kept here so it is compiled.
// The README's samples went stale once before and had to be rewritten wholesale
// (audit item 22); a sample that is built cannot drift unnoticed.
//
// Nothing calls this. It exists to fail the build if the example stops compiling.
// If you change it, change the README to match.

import Foundation
import LLVS
import LLVSModel
import LLVSSQLite
import LLVSProjection

@MergeableModel
struct ReadmeNote: StorableModel, Codable, Equatable {
    static let modelTypeIdentifier = "Note"
    var title: String = ""
    var body: String = ""
    var updatedAt: Date = .now
    var tags: [String] = []
}

func readmeOwnedTableExample(
    database: SQLiteDatabase,
    store: Store,
    coordinator: StoreCoordinator,
    currentVersion: Version.ID?,
    noteId: String,
    cutoff: Int64,
    oldVersion: Version.ID,
    newVersion: Version.ID
) throws {
    let table = OwnedTable(
        typeIdentifier: ReadmeNote.modelTypeIdentifier,
        tableName: "notes",
        schema: ReadmeNote.sqliteSchema)
    for statement in table.createStatements() {
        try database.execute(statement: statement)
    }

    try database.execute(statement: "CREATE INDEX notes_updated ON notes(updated_at)")

    try database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?",
                         withBindingsList: [["New title", noteId]])

    let result = try table.drain(in: database, store: store)
    _ = result
    _ = try table.currentVersion(in: database)
    _ = currentVersion

    let rows = try table.fetch(ReadmeNote.self, in: database, where: "updated_at > ?", bindings: [cutoff])
    for row in rows { print(row.model.title, row.id) }

    let changes = try store.valueChanges(updatingFrom: oldVersion, to: newVersion)
    try table.apply(changes, in: database, atVersion: newVersion)

    let arbiter = MergeableArbiter()
    arbiter.register(ReadmeNote.self)
    coordinator.mergeArbiter = arbiter
}
