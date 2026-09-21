//
//  ReadmeExampleCompileCheck.swift
//  LLVSProjectionTests
//
//  Created by Drew McCormack on 20/09/2026.
//

// The README's LLVSProjection example, kept here so it is compiled.
// The README's samples went stale once before and had to be rewritten wholesale
// (audit item 22); a sample that is built cannot drift unnoticed.
//
// Nothing calls this. It exists to fail the build if the example stops compiling.
// If you change it, change the README to match.
import Foundation
import LLVS
import LLVSModel
import LLVSProjection

struct Contact: StorableModel, Codable {
    static let modelTypeIdentifier = "Contact"
    var name: String = ""
    var age: Int = 0
}

func readmeExample(coordinator: StoreCoordinator, databaseURL: URL, value: Value) async throws {
    let contacts = ProjectedType(
        typeIdentifier: Contact.modelTypeIdentifier,
        tableName: "contacts",
        columns: [
            ProjectedColumn(name: "name", declaration: "TEXT"),
            ProjectedColumn(name: "age", declaration: "INTEGER"),
        ],
        extract: { value in
            let contact = try JSONDecoder().decode(Contact.self, from: value.data)
            return ["name": .text(contact.name), "age": .integer(Int64(contact.age))]
        }
    )

    let follower = try ProjectionFollower(
        databaseURL: databaseURL,
        coordinator: coordinator,
        types: [contacts],
        schemaVersion: 1)

    try coordinator.save(inserting: [value])
    await follower.projectCurrentVersion()

    let names = try await follower.query { database in
        var names: [String] = []
        try database.forEach(matchingQuery: "SELECT name FROM contacts WHERE age > 30 ORDER BY name") { row in
            if let name: String = row.value(inColumnAtIndex: 0) { names.append(name) }
        }
        return names
    }
    print(names)
}
