# Local-First SQLite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an app write ordinary SQL against a SQLite table generated from its Swift model, and have those writes become LLVS versions that sync and merge per column.

**Architecture:** SQLite is the working copy at a version; LLVS is the object store. `@MergeableModel` gains a generated schema — a real column per scalar property, JSON for nested ones. Triggers record row and column changes into a changelog; a drain step turns that into a version whose predecessor is the version the table was at. Incoming versions apply back under a suppression flag so they cannot echo out. Merging is unchanged: a column is a property, and `MergeableArbiter` already merges property-wise.

**Tech Stack:** Swift 6 language mode, swift-tools-version 6.1, Swift Testing, SwiftSyntax for the macro, SQLite via `LLVSSQLite`.

**Spec:** `docs/superpowers/specs/2026-09-21-local-first-sqlite-design.md`

## Global Constraints

- Swift 6 language mode, strict concurrency, every target. Platforms: macOS 15, iOS 18, watchOS 11.
- Tests are Swift Testing (`@Suite`/`@Test`/`#expect`), no `test` prefix. Macro tests exercise generated *behaviour*, not expansion text — follow `Tests/LLVSModelTests/MergeableModelMacroTests.swift`.
- `LLVSProjection` depends on `LLVS` and `LLVSSQLite` only. The macro lives in `LLVSModelMacros` and must not gain non-SwiftSyntax dependencies.
- Never nest `store.queryHistory` calls; the `History` mutex is not recursive.
- Every write path that touches rows plus the version marker uses `SQLiteDatabase.inTransaction`.
- Record user-visible changes in `CHANGELOG.md` under `## Unreleased`.
- Run `swift test` before each commit.
- Table and column names must satisfy `ProjectedType.isPlainIdentifier`; SQLite has no binding for identifiers.

## Settled decisions this plan assumes

From the spec's "The three questions, settled" — do not re-litigate while implementing:

- **Migration is drain-then-rebuild.** A failed drain cancels the migration.
- **A delete is a removal**, and an edit on another device brings the row back via the existing arbiter.
- **Transaction boundaries need no mechanism.** Triggers fire inside the app's transaction; a rollback discards the changelog rows with it. Verified against SQLite.

---

### Task 1: Teach the macro each property's SQLite column type

`@MergeableModel` already walks stored properties and correctly skips `let`, `static` and computed ones, but keeps only the name (`MergeableModelMacro.swift:40-72`). `binding.typeAnnotation` is available and unused. This task extracts the declared type and maps it to a column, generating a schema description alongside the existing `Mergeable` conformance.

Two facts about the existing code matter. `var a = 0, b = 0` is legal and both bindings are kept, so each binding needs its own type. And `var first = 0` has **no** type annotation at all — the type is inferred, and a macro cannot see it. Such a property gets no column and is reported, rather than guessed at.

**Files:**
- Modify: `Sources/LLVSModelMacros/MergeableModelMacro.swift`
- Test: `Tests/LLVSModelTests/MergeableModelMacroTests.swift`

**Interfaces:**
- Consumes: SwiftSyntax `VariableDeclSyntax`, `PatternBindingSyntax.typeAnnotation`.
- Produces: the macro additionally generates a static `sqliteSchema` on the type:
  - `public struct ModelColumn: Sendable, Equatable` with `let propertyName: String`, `let columnName: String`, `let declaration: String`, `let storage: ColumnStorage`.
  - `public enum ColumnStorage: Sendable, Equatable` with cases `scalar`, `json`.
  - `public struct ModelSchema: Sendable, Equatable` with `let columns: [ModelColumn]`.
  - Both live in `Sources/LLVSModel/ModelSchema.swift` (created here), because generated code must reference them.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/LLVSModelTests/MergeableModelMacroTests.swift`. Declare the models at file scope beside the existing ones:

```swift
@MergeableModel
struct SchemaModel: Codable, Equatable {
    var title: String = ""
    var count: Int = 0
    var ratio: Double = 0
    var starred: Bool = false
    var when: Date = .init(timeIntervalSince1970: 0)
    var identifier: UUID = .init()
    var payload: Data = .init()
    var note: String? = nil
    var tags: [String] = []
}
```

And the tests inside the suite:

```swift
@Test func scalarPropertiesBecomeRealColumns() {
    let byProperty = Dictionary(uniqueKeysWithValues: SchemaModel.sqliteSchema.columns.map { ($0.propertyName, $0) })
    #expect(byProperty["title"]?.declaration == "TEXT")
    #expect(byProperty["count"]?.declaration == "INTEGER")
    #expect(byProperty["ratio"]?.declaration == "REAL")
    #expect(byProperty["starred"]?.declaration == "INTEGER")
    #expect(byProperty["when"]?.declaration == "INTEGER")
    #expect(byProperty["identifier"]?.declaration == "TEXT")
    #expect(byProperty["payload"]?.declaration == "BLOB")
    #expect(byProperty["title"]?.storage == .scalar)
}

@Test func optionalScalarsAreStillScalarColumns() {
    let byProperty = Dictionary(uniqueKeysWithValues: SchemaModel.sqliteSchema.columns.map { ($0.propertyName, $0) })
    #expect(byProperty["note"]?.declaration == "TEXT")
    #expect(byProperty["note"]?.storage == .scalar)
}

@Test func nestedPropertiesBecomeJSONColumns() {
    let byProperty = Dictionary(uniqueKeysWithValues: SchemaModel.sqliteSchema.columns.map { ($0.propertyName, $0) })
    #expect(byProperty["tags"]?.declaration == "TEXT")
    #expect(byProperty["tags"]?.storage == .json)
}

@Test func columnNamesAreSnakeCased() {
    // A property named in camelCase becomes a conventional SQL column name.
    #expect(SchemaModel.sqliteSchema.columns.contains { $0.propertyName == "when" && $0.columnName == "when_" })
}
```

`when` is a SQLite keyword, which is why that last test expects a trailing underscore. Read the SQLite keyword list and escape by suffix rather than by quoting, so the column stays a plain identifier.

- [ ] **Step 2: Add a test for a property whose type cannot be seen**

```swift
@MergeableModel
struct InferredTypeModel: Codable, Equatable {
    var typed: String = ""
    var inferred = 0
}
```

```swift
@Test func aPropertyWithNoTypeAnnotationGetsNoColumn() {
    // A macro cannot see an inferred type, so the column is omitted rather than guessed.
    let names = InferredTypeModel.sqliteSchema.columns.map(\.propertyName)
    #expect(names == ["typed"])
    #expect(InferredTypeModel.sqliteSchema.propertiesWithoutColumns == ["inferred"])
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter MergeableModelMacroTests`
Expected: FAIL to compile, "type 'SchemaModel' has no member 'sqliteSchema'".

- [ ] **Step 4: Create the schema types**

Create `Sources/LLVSModel/ModelSchema.swift`:

```swift
import Foundation

/// How a model property is stored in its SQLite column.
public enum ColumnStorage: Sendable, Equatable {
    /// A real column of the value's own type, directly indexable.
    case scalar
    /// A TEXT column holding JSON, for a property with no column-shaped type.
    /// Still queryable through `json_extract` and `json_each`.
    case json
}

/// One column of a model's generated table.
public struct ModelColumn: Sendable, Equatable {
    public let propertyName: String
    public let columnName: String
    /// The SQLite type, for example `"TEXT"` or `"INTEGER"`.
    public let declaration: String
    public let storage: ColumnStorage

    public init(propertyName: String, columnName: String, declaration: String, storage: ColumnStorage) {
        self.propertyName = propertyName
        self.columnName = columnName
        self.declaration = declaration
        self.storage = storage
    }
}

/// The table a model maps to, generated by `@MergeableModel`.
public struct ModelSchema: Sendable, Equatable {
    public let columns: [ModelColumn]

    /// Properties the macro could not give a column, because their type is inferred
    /// rather than written down. A macro sees only syntax, so `var x = 0` has no
    /// visible type. Annotate the property to get a column.
    public let propertiesWithoutColumns: [String]

    public init(columns: [ModelColumn], propertiesWithoutColumns: [String] = []) {
        self.columns = columns
        self.propertiesWithoutColumns = propertiesWithoutColumns
    }
}
```

- [ ] **Step 5: Extract the type in the macro**

In `Sources/LLVSModelMacros/MergeableModelMacro.swift`, the binding loop currently returns `pattern.identifier.text`. Change the collected element to carry the type too. Replace the `storedProperties` computation so each entry is a `(name: String, type: String?)`, where the type is `binding.typeAnnotation?.type.trimmedDescription`.

Keep every existing skip — `let`, `static`, computed in both forms — exactly as it is. Those are tested and one of them (`.getter` versus `.accessors`) was a past defect.

Then add the mapping, above the extension generation:

```swift
/// SQLite keywords that cannot be a bare column name. A name that collides gets a
/// trailing underscore rather than quoting, so the column stays a plain identifier.
let sqliteKeywords: Set<String> = [
    "abort", "action", "add", "after", "all", "alter", "always", "analyze", "and", "as",
    "asc", "attach", "autoincrement", "before", "begin", "between", "by", "cascade", "case",
    "cast", "check", "collate", "column", "commit", "conflict", "constraint", "create",
    "cross", "current", "database", "default", "deferrable", "deferred", "delete", "desc",
    "detach", "distinct", "do", "drop", "each", "else", "end", "escape", "except",
    "exclusive", "exists", "explain", "fail", "filter", "first", "following", "for",
    "foreign", "from", "full", "glob", "group", "having", "if", "ignore", "immediate",
    "in", "index", "indexed", "initially", "inner", "insert", "instead", "intersect",
    "into", "is", "isnull", "join", "key", "last", "left", "like", "limit", "match",
    "natural", "no", "not", "notnull", "null", "of", "offset", "on", "or", "order",
    "outer", "over", "plan", "pragma", "primary", "query", "raise", "range", "recursive",
    "references", "regexp", "reindex", "release", "rename", "replace", "restrict",
    "right", "rollback", "row", "savepoint", "select", "set", "table", "temp", "temporary",
    "then", "to", "transaction", "trigger", "union", "unique", "update", "using",
    "vacuum", "values", "view", "virtual", "when", "where", "window", "with", "without",
]

/// camelCase to snake_case, then escaped if it collides with a keyword.
func columnName(forProperty property: String) -> String {
    var result = ""
    for character in property {
        if character.isUppercase {
            if !result.isEmpty { result.append("_") }
            result.append(Character(character.lowercased()))
        } else {
            result.append(character)
        }
    }
    return sqliteKeywords.contains(result) ? result + "_" : result
}

/// The SQLite type for a declared Swift type, or nil when it has no column shape.
/// An optional is the same column, nullable, so the wrapped type decides.
func sqliteDeclaration(forSwiftType swiftType: String) -> String? {
    var bare = swiftType.trimmingCharacters(in: .whitespaces)
    if bare.hasSuffix("?") { bare = String(bare.dropLast()) }
    if bare.hasPrefix("Optional<") && bare.hasSuffix(">") {
        bare = String(bare.dropFirst("Optional<".count).dropLast())
    }
    switch bare {
    case "String": return "TEXT"
    case "Int", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32": return "INTEGER"
    case "Double", "Float": return "REAL"
    case "Bool": return "INTEGER"
    case "Date": return "INTEGER"
    case "UUID": return "TEXT"
    case "Data": return "BLOB"
    default: return nil
    }
}
```

`Bool` and `Date` both become `INTEGER`, which is how SQLite stores them: a boolean is 0 or 1, and a date is seconds since 1970.

- [ ] **Step 6: Generate the schema**

Still in the macro, build the schema declaration from the collected properties and append it to the generated extension:

```swift
var columnLiterals: [String] = []
var withoutColumns: [String] = []
for property in storedProperties {
    guard let declaredType = property.type,
          let declaration = sqliteDeclaration(forSwiftType: declaredType) else {
        if property.type == nil {
            withoutColumns.append(property.name)
        } else {
            // A type that is written down but has no column shape: store it as JSON.
            columnLiterals.append("""
                LLVSModel.ModelColumn(propertyName: "\\(property.name)", columnName: "\\(columnName(forProperty: property.name))", declaration: "TEXT", storage: .json)
                """)
        }
        continue
    }
    columnLiterals.append("""
        LLVSModel.ModelColumn(propertyName: "\\(property.name)", columnName: "\\(columnName(forProperty: property.name))", declaration: "\\(declaration)", storage: .scalar)
        """)
}
```

Then include in the generated extension, alongside the existing two methods:

```swift
\(raw: access)static var sqliteSchema: LLVSModel.ModelSchema {
    LLVSModel.ModelSchema(
        columns: [\(raw: columnLiterals.joined(separator: ", "))],
        propertiesWithoutColumns: [\(raw: withoutColumns.map { "\"\($0)\"" }.joined(separator: ", "))])
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter MergeableModelMacroTests`
Expected: PASS, including the existing tests. If `MultipleBindingModel` now reports `first` and `second` in `propertiesWithoutColumns`, that is correct — they are declared `var first = 0` with no annotation.

- [ ] **Step 8: Run the full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 9: Changelog and commit**

Add under `## Unreleased`, `### Added`:

```markdown
- `@MergeableModel` also generates `sqliteSchema`, describing the table the model maps to: a real column per scalar property (`String`, `Int`, `Double`, `Bool`, `Date`, `UUID`, `Data`, and optionals of those), and a JSON `TEXT` column for a property whose type has no column shape. Column names are snake_cased, and one colliding with a SQLite keyword gets a trailing underscore so it stays a plain identifier. A property whose type is inferred rather than written down (`var x = 0`) gets no column and is listed in `propertiesWithoutColumns`, because a macro sees only syntax.
```

```bash
git add Sources/LLVSModel/ModelSchema.swift Sources/LLVSModelMacros/MergeableModelMacro.swift Tests/LLVSModelTests/MergeableModelMacroTests.swift CHANGELOG.md
git commit -m "Generate a SQLite schema from the model declaration"
```

---

### Task 2: Create an owned table with its capture triggers

Turns a `ModelSchema` into a real table, a changelog, and the triggers that record changes. No LLVS involvement yet — this task is about SQLite alone, so it can be verified directly.

All four trigger behaviours were checked against SQLite before the spec was written, and the tests below assert each one.

**Files:**
- Create: `Sources/LLVSProjection/OwnedTable.swift`
- Create: `Tests/LLVSProjectionTests/OwnedTableTests.swift`
- Modify: `Package.swift` (add `LLVSModel` to the `LLVSProjection` target's dependencies)

**Interfaces:**
- Consumes: `ModelSchema`, `ModelColumn`, `ColumnStorage` (Task 1); `SQLiteDatabase.execute(statement:withBindingsList:)`, `forEach(matchingQuery:withBindings:rowHandler:)`, `inTransaction(_:)`.
- Produces:
  - `public struct OwnedTable: Sendable` with `init(typeIdentifier:tableName:schema:)`, and `let typeIdentifier: String`, `let tableName: String`, `let schema: ModelSchema`.
  - `func createStatements() -> [String]` — the table, the changelog, the suppression table, and the three triggers, in the order they must run.
  - `public struct ChangelogEntry: Sendable, Equatable` with `let sequence: Int64`, `let valueId: Value.ID`, `let columnName: String?`, `let operation: Operation`, and `enum Operation: Sendable { case insert, update, remove }`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LLVSProjectionTests/OwnedTableTests.swift`, following the `@Suite class` + `init()`/`deinit` pattern used by the other suites in this target:

```swift
import Testing
import Foundation
@testable import LLVS
@testable import LLVSSQLite
@testable import LLVSModel
@testable import LLVSProjection

@Suite class OwnedTableTests {

    let database: SQLiteDatabase
    let databaseURL: URL
    let table: OwnedTable

    init() throws {
        databaseURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".sqlite")
        database = try SQLiteDatabase(fileURL: databaseURL)
        table = OwnedTable(
            typeIdentifier: "Note",
            tableName: "notes",
            schema: ModelSchema(columns: [
                ModelColumn(propertyName: "title", columnName: "title", declaration: "TEXT", storage: .scalar),
                ModelColumn(propertyName: "body", columnName: "body", declaration: "TEXT", storage: .scalar),
            ]))
        for statement in table.createStatements() {
            try database.execute(statement: statement)
        }
    }

    deinit {
        try? database.close()
        try? FileManager.default.removeItem(at: databaseURL)
    }

    private func entries() throws -> [ChangelogEntry] {
        try table.changelogEntries(in: database)
    }

    @Test func anInsertIsCaptured() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1", "Hello", "Body"]])
        let captured = try entries()
        #expect(captured.count == 1)
        #expect(captured.first?.valueId.rawValue == "n1")
        #expect(captured.first?.operation == .insert)
    }

    /// The point of per-column capture: an update names the column that changed, which is
    /// what lets two devices editing different columns merge without losing either edit.
    @Test func anUpdateIsCapturedPerChangedColumn() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1", "Hello", "Body"]])
        try table.clearChangelog(in: database)

        try database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?",
            withBindingsList: [["Changed", "n1"]])

        let captured = try entries()
        #expect(captured.count == 1)
        #expect(captured.first?.columnName == "title")
        #expect(captured.first?.operation == .update)
    }

    @Test func anUpdateThatChangesNothingIsNotCaptured() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1", "Hello", "Body"]])
        try table.clearChangelog(in: database)

        try database.execute(statement: "UPDATE notes SET title = title WHERE llvs_id = ?",
            withBindingsList: [["n1"]])

        #expect(try entries().isEmpty)
    }

    /// One SQL statement touching many rows must yield one entry per row, or a bulk edit
    /// would collapse into a single change and lose the others.
    @Test func aMultiRowUpdateIsCapturedPerRow() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1", "A", "x"], ["n2", "B", "y"]])
        try table.clearChangelog(in: database)

        try database.execute(statement: "UPDATE notes SET title = title || '!'")

        let captured = try entries()
        #expect(captured.count == 2)
        #expect(Set(captured.map(\.valueId.rawValue)) == ["n1", "n2"])
    }

    @Test func aDeleteIsCaptured() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1", "Hello", "Body"]])
        try table.clearChangelog(in: database)

        try database.execute(statement: "DELETE FROM notes WHERE llvs_id = ?", withBindingsList: [["n1"]])

        let captured = try entries()
        #expect(captured.count == 1)
        #expect(captured.first?.operation == .remove)
        #expect(captured.first?.valueId.rawValue == "n1")
    }

    /// Applying a version from another device must not look like a local edit, or the change
    /// would be sent straight back out and the two devices would trade it forever.
    @Test func aWriteUnderSuppressionIsNotCaptured() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1", "Hello", "Body"]])
        try table.clearChangelog(in: database)

        try table.whileApplyingRemoteChanges(in: database) {
            try self.database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?",
                withBindingsList: [["From another device", "n1"]])
        }

        #expect(try entries().isEmpty)
        // The row really did change; only the capture was suppressed.
        var title: String?
        try database.forEach(matchingQuery: "SELECT title FROM notes WHERE llvs_id = 'n1'") { row in
            title = row.value(inColumnAtIndex: 0)
        }
        #expect(title == "From another device")
    }

    /// Triggers fire inside the app's transaction, so a rollback takes the changelog with it.
    /// This is what makes an app's own BEGIN/COMMIT the version boundary for free.
    @Test func aRolledBackWriteLeavesNoEntry() throws {
        try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
            withBindingsList: [["n1", "Hello", "Body"]])
        try table.clearChangelog(in: database)

        try? database.inTransaction {
            try self.database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?",
                withBindingsList: [["Doomed", "n1"]])
            throw CancellationError()
        }

        #expect(try entries().isEmpty)
        var title: String?
        try database.forEach(matchingQuery: "SELECT title FROM notes WHERE llvs_id = 'n1'") { row in
            title = row.value(inColumnAtIndex: 0)
        }
        #expect(title == "Hello")
    }

    @Test func suppressionIsLiftedAfterTheBlock() throws {
        try table.whileApplyingRemoteChanges(in: database) {
            try self.database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
                withBindingsList: [["n1", "Remote", "x"]])
        }
        try database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?",
            withBindingsList: [["Local", "n1"]])
        #expect(try entries().count == 1)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter OwnedTableTests`
Expected: FAIL to compile, "cannot find 'OwnedTable' in scope".

- [ ] **Step 3: Add LLVSModel to the target**

In `Package.swift`, the `LLVSProjection` target's dependencies become `["LLVS", "LLVSSQLite", "LLVSModel"]`. Keep the `swiftSettings: [.swiftLanguageMode(.v6)]` line as it is.

- [ ] **Step 4: Write the implementation**

Create `Sources/LLVSProjection/OwnedTable.swift`:

```swift
import Foundation
import LLVS
import LLVSModel
import LLVSSQLite

/// One row change recorded by the capture triggers.
public struct ChangelogEntry: Sendable, Equatable {
    public enum Operation: String, Sendable, Equatable {
        case insert = "i"
        case update = "u"
        case remove = "d"
    }

    public let sequence: Int64
    public let valueId: Value.ID
    /// Which column changed, for an update. Nil for an insert or a remove, which concern
    /// the whole row.
    public let columnName: String?
    public let operation: Operation
}

/// A SQLite table an app writes directly, whose changes become LLVS versions.
///
/// The table is ordinary: a real column per scalar property, `llvs_id` as the primary key,
/// and nothing else announcing LLVS. Index it, query it and write it as any SQLite table.
///
/// Three triggers record what changes into a changelog, per row and — for an update — per
/// column. That granularity is what lets two devices editing different columns of one row
/// merge without either edit being lost.
public struct OwnedTable: Sendable {
    public let typeIdentifier: String
    public let tableName: String
    public let schema: ModelSchema

    public init(typeIdentifier: String, tableName: String, schema: ModelSchema) {
        precondition(ProjectedType.isPlainIdentifier(tableName),
            "Owned table name is not a plain SQL identifier: \"\(tableName)\"")
        for column in schema.columns {
            precondition(ProjectedType.isPlainIdentifier(column.columnName),
                "Owned table column name is not a plain SQL identifier: \"\(column.columnName)\"")
        }
        self.typeIdentifier = typeIdentifier
        self.tableName = tableName
        self.schema = schema
    }

    var changelogName: String { "\(tableName)_changelog" }
    var suppressionName: String { "\(tableName)_applying" }

    /// Everything needed to stand the table up, in the order it must run.
    public func createStatements() -> [String] {
        var statements: [String] = []

        let columnDeclarations = schema.columns.map { "\($0.columnName) \($0.declaration)" }
        statements.append("""
            CREATE TABLE IF NOT EXISTS \(tableName) (
                llvs_id TEXT PRIMARY KEY\(columnDeclarations.isEmpty ? "" : ", " + columnDeclarations.joined(separator: ", "))
            )
            """)

        statements.append("""
            CREATE TABLE IF NOT EXISTS \(changelogName) (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                llvs_id TEXT NOT NULL,
                column_name TEXT,
                op TEXT NOT NULL
            )
            """)

        // A single row holding whether capture is suppressed. A table rather than a Swift
        // property because the trigger's WHEN clause is SQL and can only consult the database.
        statements.append("CREATE TABLE IF NOT EXISTS \(suppressionName) (flag INTEGER NOT NULL)")
        statements.append("INSERT INTO \(suppressionName) (flag) SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM \(suppressionName))")

        let notSuppressed = "(SELECT flag FROM \(suppressionName)) = 0"

        statements.append("""
            CREATE TRIGGER IF NOT EXISTS \(tableName)_capture_insert AFTER INSERT ON \(tableName)
            WHEN \(notSuppressed)
            BEGIN
                INSERT INTO \(changelogName) (llvs_id, column_name, op) VALUES (NEW.llvs_id, NULL, 'i');
            END
            """)

        // One statement per column, each guarded so an unchanged column records nothing.
        // `IS NOT` rather than `<>` so that a change to or from NULL is seen.
        var updateBody = ""
        for column in schema.columns {
            updateBody += """
                INSERT INTO \(changelogName) (llvs_id, column_name, op)
                    SELECT NEW.llvs_id, '\(column.columnName)', 'u'
                    WHERE OLD.\(column.columnName) IS NOT NEW.\(column.columnName);

                """
        }
        statements.append("""
            CREATE TRIGGER IF NOT EXISTS \(tableName)_capture_update AFTER UPDATE ON \(tableName)
            WHEN \(notSuppressed)
            BEGIN
                \(updateBody)
            END
            """)

        statements.append("""
            CREATE TRIGGER IF NOT EXISTS \(tableName)_capture_delete AFTER DELETE ON \(tableName)
            WHEN \(notSuppressed)
            BEGIN
                INSERT INTO \(changelogName) (llvs_id, column_name, op) VALUES (OLD.llvs_id, NULL, 'd');
            END
            """)

        return statements
    }

    /// Everything captured so far, oldest first.
    public func changelogEntries(in database: SQLiteDatabase) throws -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        try database.forEach(matchingQuery: "SELECT seq, llvs_id, column_name, op FROM \(changelogName) ORDER BY seq") { row in
            guard let sequence: Int64 = row.value(inColumnAtIndex: 0),
                  let rawId: String = row.value(inColumnAtIndex: 1),
                  let rawOperation: String = row.value(inColumnAtIndex: 3),
                  let operation = ChangelogEntry.Operation(rawValue: rawOperation) else { return }
            entries.append(ChangelogEntry(
                sequence: sequence,
                valueId: .init(rawId),
                columnName: row.value(inColumnAtIndex: 2),
                operation: operation))
        }
        return entries
    }

    /// Removes every captured entry. Call only once the entries are safely in LLVS.
    public func clearChangelog(in database: SQLiteDatabase) throws {
        try database.execute(statement: "DELETE FROM \(changelogName)")
    }

    /// Removes entries up to and including `sequence`, leaving anything captured since.
    /// Draining takes a snapshot of the changelog, and the app may write while that is
    /// being turned into a version; those later writes must survive.
    public func clearChangelog(in database: SQLiteDatabase, throughSequence sequence: Int64) throws {
        try database.execute(statement: "DELETE FROM \(changelogName) WHERE seq <= ?",
            withBindingsList: [[sequence]])
    }

    /// Runs `block` with capture suppressed, for applying a version from elsewhere.
    /// Without this an applied change would be recorded as a local edit and sent straight
    /// back out, and two devices would trade it indefinitely.
    public func whileApplyingRemoteChanges(in database: SQLiteDatabase, _ block: () throws -> Void) throws {
        try database.execute(statement: "UPDATE \(suppressionName) SET flag = 1")
        defer { try? database.execute(statement: "UPDATE \(suppressionName) SET flag = 0") }
        try block()
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter OwnedTableTests`
Expected: PASS, all eight tests.

If `aRolledBackWriteLeavesNoEntry` fails because `AUTOINCREMENT` keeps its counter across a rollback, that is expected and harmless — the test asserts on entries, not sequence numbers. If it fails on entries, the trigger is running outside the transaction, which would be a real finding: report it rather than adjusting the test.

- [ ] **Step 6: Run the full suite and commit**

Run: `swift test`
Expected: PASS.

Add under `## Unreleased`, `### Added`:

```markdown
- `OwnedTable` in `LLVSProjection`: a SQLite table an app writes directly with ordinary SQL, whose changes are captured by triggers for turning into LLVS versions. An insert or delete is recorded per row and an update per changed column, which is the granularity that lets two devices editing different columns of one row merge without losing either edit. An update that changes nothing records nothing, a rolled-back transaction records nothing because the triggers run inside it, and applying a remote change can be suppressed so it is not sent straight back out.
```

```bash
git add Package.swift Sources/LLVSProjection/OwnedTable.swift Tests/LLVSProjectionTests/OwnedTableTests.swift CHANGELOG.md
git commit -m "Capture SQL writes to an owned table"
```

---

### Task 3: Turn captured changes into an LLVS version

The drain step. Reads the changelog, assembles each touched row into a value, and writes one version whose predecessor is the version the table was at.

A row becomes JSON keyed by **property** name, not column name, so it is the same shape `@MergeableModel` merges and `StorableModel` decodes. The column name exists only inside SQLite.

**Files:**
- Create: `Sources/LLVSProjection/OwnedTableDrain.swift`
- Create: `Tests/LLVSProjectionTests/OwnedTableDrainTests.swift`

**Interfaces:**
- Consumes: `OwnedTable`, `ChangelogEntry` (Task 2); `Store.makeVersion(basedOnPredecessor:storing:)`; `Value.Change`.
- Produces:
  - `extension OwnedTable` with `func drain(in database: SQLiteDatabase, store: Store, basedOn predecessor: Version.ID?) throws -> DrainResult`.
  - `public struct DrainResult: Sendable` with `let version: Version.ID?` (nil when nothing was captured) and `let changeCount: Int`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LLVSProjectionTests/OwnedTableDrainTests.swift`. Build a store and a database in `init()` as the other suites do, with the same two-column `notes` table as Task 2.

```swift
@Test func anInsertBecomesAVersionHoldingTheRow() throws {
    try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
        withBindingsList: [["n1/Note", "Hello", "Body"]])

    let result = try table.drain(in: database, store: store, basedOn: nil)

    let versionId = try #require(result.version)
    let value = try #require(try store.value(id: .init("n1/Note"), at: versionId))
    let json = try #require(try JSONSerialization.jsonObject(with: value.data) as? [String: Any])
    #expect(json["title"] as? String == "Hello")
    #expect(json["body"] as? String == "Body")
}

/// The JSON is keyed by property name, because that is what the model decodes from.
/// The column name is SQLite's business and stops at the table.
@Test func theValueIsKeyedByPropertyName() throws {
    let table = OwnedTable(typeIdentifier: "Note", tableName: "notes2",
        schema: ModelSchema(columns: [
            ModelColumn(propertyName: "updatedAt", columnName: "updated_at", declaration: "INTEGER", storage: .scalar),
        ]))
    for statement in table.createStatements() { try database.execute(statement: statement) }
    try database.execute(statement: "INSERT INTO notes2 (llvs_id, updated_at) VALUES (?, ?)",
        withBindingsList: [["n9/Note", Int64(1758400000)]])

    let result = try table.drain(in: database, store: store, basedOn: nil)

    let versionId = try #require(result.version)
    let value = try #require(try store.value(id: .init("n9/Note"), at: versionId))
    let json = try #require(try JSONSerialization.jsonObject(with: value.data) as? [String: Any])
    #expect(json["updatedAt"] != nil)
    #expect(json["updated_at"] == nil)
}

@Test func aDeleteBecomesARemoval() throws {
    try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
        withBindingsList: [["n1/Note", "Hello", "Body"]])
    let first = try table.drain(in: database, store: store, basedOn: nil)

    try database.execute(statement: "DELETE FROM notes WHERE llvs_id = ?", withBindingsList: [["n1/Note"]])
    let second = try table.drain(in: database, store: store, basedOn: first.version)

    let versionId = try #require(second.version)
    #expect(try store.value(id: .init("n1/Note"), at: versionId) == nil)
}

@Test func severalEditsToOneRowBecomeOneChange() throws {
    try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
        withBindingsList: [["n1/Note", "Hello", "Body"]])
    let first = try table.drain(in: database, store: store, basedOn: nil)

    try database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?", withBindingsList: [["One", "n1/Note"]])
    try database.execute(statement: "UPDATE notes SET body = ? WHERE llvs_id = ?", withBindingsList: [["Two", "n1/Note"]])
    let second = try table.drain(in: database, store: store, basedOn: first.version)

    // Two captured entries, but one row, so one change carrying the row as it now stands.
    #expect(second.changeCount == 1)
    let versionId = try #require(second.version)
    let value = try #require(try store.value(id: .init("n1/Note"), at: versionId))
    let json = try #require(try JSONSerialization.jsonObject(with: value.data) as? [String: Any])
    #expect(json["title"] as? String == "One")
    #expect(json["body"] as? String == "Two")
}

@Test func drainingNothingMakesNoVersion() throws {
    let result = try table.drain(in: database, store: store, basedOn: nil)
    #expect(result.version == nil)
    #expect(result.changeCount == 0)
}

@Test func drainingClearsWhatItTook() throws {
    try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
        withBindingsList: [["n1/Note", "Hello", "Body"]])
    _ = try table.drain(in: database, store: store, basedOn: nil)
    #expect(try table.changelogEntries(in: database).isEmpty)
}

/// A row inserted and deleted between two drains never reaches LLVS, and must not arrive
/// as a removal of something that was never there.
@Test func aRowCreatedAndDeletedBeforeDrainingIsNotReported() throws {
    try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
        withBindingsList: [["n1/Note", "Hello", "Body"]])
    try database.execute(statement: "DELETE FROM notes WHERE llvs_id = ?", withBindingsList: [["n1/Note"]])

    let result = try table.drain(in: database, store: store, basedOn: nil)

    // The row is gone and was never stored, so there is nothing to say.
    #expect(result.changeCount == 0)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter OwnedTableDrainTests`
Expected: FAIL to compile, "value of type 'OwnedTable' has no member 'drain'".

- [ ] **Step 3: Write the implementation**

Create `Sources/LLVSProjection/OwnedTableDrain.swift`:

```swift
import Foundation
import LLVS
import LLVSModel
import LLVSSQLite

/// What one drain did.
public struct DrainResult: Sendable {
    /// The version the captured changes became, or nil when nothing was captured.
    public let version: Version.ID?
    public let changeCount: Int
}

extension OwnedTable {

    /// Turns everything captured so far into one LLVS version, based on `predecessor`.
    ///
    /// Several edits to one row become one change carrying the row as it now stands: the
    /// changelog says *which* rows and columns were touched, and the row itself says what
    /// they now hold. Per-column capture earns its keep in the merge, not here.
    ///
    /// The changelog is read, turned into a version, and only then cleared — and only up to
    /// the sequence that was read, so a write arriving mid-drain is kept for the next one.
    public func drain(in database: SQLiteDatabase, store: Store, basedOn predecessor: Version.ID?) throws -> DrainResult {
        let entries = try changelogEntries(in: database)
        guard let highestSequence = entries.last?.sequence else {
            return DrainResult(version: nil, changeCount: 0)
        }

        // One entry per row, latest wins: a row edited three times needs saying once.
        var operationsByValueId: [Value.ID: ChangelogEntry.Operation] = [:]
        for entry in entries {
            operationsByValueId[entry.valueId] = entry.operation
        }

        var changes: [Value.Change] = []
        for (valueId, operation) in operationsByValueId {
            switch operation {
            case .insert, .update:
                guard let data = try rowData(for: valueId, in: database) else {
                    // Inserted and deleted again before this drain: nothing was ever stored,
                    // so there is nothing to remove either.
                    continue
                }
                let value = Value(id: valueId, data: data)
                let exists = try predecessor.flatMap { try store.valueReference(id: valueId, at: $0) } != nil
                changes.append(exists ? .update(value) : .insert(value))
            case .remove:
                let exists = try predecessor.flatMap { try store.valueReference(id: valueId, at: $0) } != nil
                if exists { changes.append(.remove(valueId)) }
            }
        }

        guard !changes.isEmpty else {
            try clearChangelog(in: database, throughSequence: highestSequence)
            return DrainResult(version: nil, changeCount: 0)
        }

        let version = try store.makeVersion(basedOnPredecessor: predecessor, storing: changes)
        try clearChangelog(in: database, throughSequence: highestSequence)
        return DrainResult(version: version.id, changeCount: changes.count)
    }

    /// The row as JSON, keyed by property name. The column name stops at the table: what
    /// LLVS stores must be what the model decodes from.
    private func rowData(for valueId: Value.ID, in database: SQLiteDatabase) throws -> Data? {
        let columnList = schema.columns.map(\.columnName).joined(separator: ", ")
        let query = columnList.isEmpty
            ? "SELECT llvs_id FROM \(tableName) WHERE llvs_id = ?"
            : "SELECT \(columnList) FROM \(tableName) WHERE llvs_id = ?"

        var object: [String: Any]?
        try database.forEach(matchingQuery: query, withBindings: [valueId.rawValue]) { row in
            var result: [String: Any] = [:]
            for (index, column) in self.schema.columns.enumerated() {
                switch column.storage {
                case .json:
                    if let text: String = row.value(inColumnAtIndex: index),
                       let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
                        result[column.propertyName] = parsed
                    }
                case .scalar:
                    switch column.declaration {
                    case "TEXT":
                        if let text: String = row.value(inColumnAtIndex: index) { result[column.propertyName] = text }
                    case "INTEGER":
                        if let number: Int64 = row.value(inColumnAtIndex: index) { result[column.propertyName] = number }
                    case "REAL":
                        if let number: Double = row.value(inColumnAtIndex: index) { result[column.propertyName] = number }
                    case "BLOB":
                        if let data: Data = row.value(inColumnAtIndex: index) {
                            result[column.propertyName] = data.base64EncodedString()
                        }
                    default:
                        break
                    }
                }
            }
            object = result
        }

        guard let object else { return nil }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
```

`.sortedKeys` keeps the bytes stable for an unchanged row, so an identical row does not look like a change to anything comparing data.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter OwnedTableDrainTests`
Expected: PASS, all seven tests.

- [ ] **Step 5: Run the full suite and commit**

Run: `swift test`
Expected: PASS.

Add under `## Unreleased`, `### Added`:

```markdown
- `OwnedTable.drain(in:store:basedOn:)`, which turns everything captured from an owned table into one LLVS version. Several edits to one row become a single change carrying the row as it now stands, a delete becomes a removal, and a row created and deleted between drains is reported as neither. The changelog is cleared only up to what was read, so a write arriving mid-drain is kept for the next one. The value is JSON keyed by property name rather than column name, so it is what the model decodes from.
```

```bash
git add Sources/LLVSProjection/OwnedTableDrain.swift Tests/LLVSProjectionTests/OwnedTableDrainTests.swift CHANGELOG.md
git commit -m "Turn captured SQL writes into LLVS versions"
```

---

### Task 4: Apply incoming versions back into the owned table

Closes the loop. A version arriving from another device, or produced by a merge, must land in the table without being captured as a local edit.

**Files:**
- Create: `Sources/LLVSProjection/OwnedTableApply.swift`
- Create: `Tests/LLVSProjectionTests/OwnedTableApplyTests.swift`

**Interfaces:**
- Consumes: `OwnedTable`, `whileApplyingRemoteChanges(in:_:)` (Task 2); `Store.valueChanges(updatingFrom:to:)`; `SQLiteDatabase.inTransaction(_:)`.
- Produces: `extension OwnedTable` with `func apply(_ changes: [Value.Change], in database: SQLiteDatabase) throws -> Int`, returning rows written or deleted.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LLVSProjectionTests/OwnedTableApplyTests.swift`, with the same suite setup as Task 3.

```swift
private func title(of id: String) throws -> String? {
    var result: String?
    try database.forEach(matchingQuery: "SELECT title FROM notes WHERE llvs_id = ?", withBindings: [id]) { row in
        result = row.value(inColumnAtIndex: 0)
    }
    return result
}

@Test func anInsertedValueBecomesARow() throws {
    let data = try JSONSerialization.data(withJSONObject: ["title": "From elsewhere", "body": "b"])
    let applied = try table.apply([.insert(Value(id: .init("n1/Note"), data: data))], in: database)

    #expect(applied == 1)
    #expect(try title(of: "n1/Note") == "From elsewhere")
}

@Test func anUpdatedValueReplacesTheRow() throws {
    try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
        withBindingsList: [["n1/Note", "Old", "b"]])
    try table.clearChangelog(in: database)

    let data = try JSONSerialization.data(withJSONObject: ["title": "New", "body": "b"])
    _ = try table.apply([.update(Value(id: .init("n1/Note"), data: data))], in: database)

    #expect(try title(of: "n1/Note") == "New")
}

@Test func aRemovedValueDeletesTheRow() throws {
    try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
        withBindingsList: [["n1/Note", "Old", "b"]])
    try table.clearChangelog(in: database)

    _ = try table.apply([.remove(.init("n1/Note"))], in: database)

    #expect(try title(of: "n1/Note") == nil)
}

/// The whole point of suppression: an applied change must not look like a local edit, or
/// it would be drained straight back out and the devices would trade it forever.
@Test func applyingRecordsNoLocalChange() throws {
    let data = try JSONSerialization.data(withJSONObject: ["title": "From elsewhere", "body": "b"])
    _ = try table.apply([.insert(Value(id: .init("n1/Note"), data: data))], in: database)

    #expect(try table.changelogEntries(in: database).isEmpty)
}

@Test func aValueMissingAPropertyLeavesThatColumnNull() throws {
    let data = try JSONSerialization.data(withJSONObject: ["title": "Only a title"])
    _ = try table.apply([.insert(Value(id: .init("n1/Note"), data: data))], in: database)

    var body: String? = "unset"
    try database.forEach(matchingQuery: "SELECT body FROM notes WHERE llvs_id = 'n1/Note'") { row in
        body = row.value(inColumnAtIndex: 0)
    }
    #expect(body == nil)
}

@Test func aValueThatIsNotAnObjectIsSkipped() throws {
    let data = Data("not json at all".utf8)
    let applied = try table.apply([.insert(Value(id: .init("n1/Note"), data: data))], in: database)

    // Skipped rather than throwing: one undecodable value must not stop the rest.
    #expect(applied == 0)
    #expect(try title(of: "n1/Note") == nil)
}

@Test func preserveChangesAreIgnored() throws {
    try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
        withBindingsList: [["n1/Note", "Kept", "b"]])
    try table.clearChangelog(in: database)

    let applied = try table.apply([.preserveRemoval(.init("other/Note"))], in: database)

    #expect(applied == 0)
    #expect(try title(of: "n1/Note") == "Kept")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter OwnedTableApplyTests`
Expected: FAIL to compile, "value of type 'OwnedTable' has no member 'apply'".

- [ ] **Step 3: Write the implementation**

Create `Sources/LLVSProjection/OwnedTableApply.swift`:

```swift
import Foundation
import LLVS
import LLVSModel
import LLVSSQLite

extension OwnedTable {

    /// Writes changes from LLVS into the table, without recording them as local edits.
    ///
    /// Returns how many rows were written or deleted. A value that is not a JSON object is
    /// skipped rather than throwing, because one value this build cannot read must not stop
    /// the rest — the same rule the read-only projection follows.
    @discardableResult
    public func apply(_ changes: [Value.Change], in database: SQLiteDatabase) throws -> Int {
        var applied = 0
        try whileApplyingRemoteChanges(in: database) {
            try database.inTransaction {
                for change in changes {
                    switch change {
                    case let .insert(value), let .update(value):
                        guard let object = try? JSONSerialization.jsonObject(with: value.data) as? [String: Any] else {
                            continue
                        }
                        try self.upsert(object, id: value.id, in: database)
                        applied += 1
                    case let .remove(valueId):
                        try database.execute(
                            statement: "DELETE FROM \(self.tableName) WHERE llvs_id = ?",
                            withBindingsList: [[valueId.rawValue]])
                        applied += 1
                    case .preserve, .preserveRemoval:
                        // The value was carried through a merge unchanged, so the row already
                        // holds what it should.
                        continue
                    }
                }
            }
        }
        return applied
    }

    private func upsert(_ object: [String: Any], id: Value.ID, in database: SQLiteDatabase) throws {
        let columnNames = ["llvs_id"] + schema.columns.map(\.columnName)
        let placeholders = Array(repeating: "?", count: columnNames.count).joined(separator: ", ")
        let bindings: [Any?] = [id.rawValue] + schema.columns.map { binding(for: object[$0.propertyName], column: $0) }

        let conflictClause: String
        if schema.columns.isEmpty {
            conflictClause = "ON CONFLICT(llvs_id) DO NOTHING"
        } else {
            let assignments = schema.columns.map { "\($0.columnName) = excluded.\($0.columnName)" }.joined(separator: ", ")
            conflictClause = "ON CONFLICT(llvs_id) DO UPDATE SET \(assignments)"
        }

        try database.execute(
            statement: """
                INSERT INTO \(tableName) (\(columnNames.joined(separator: ", "))) VALUES (\(placeholders))
                \(conflictClause)
                """,
            withBindingsList: [bindings])
    }

    /// A property the value does not carry binds as NULL, so a model that gained a property
    /// reads back with that column empty rather than failing.
    private func binding(for propertyValue: Any?, column: ModelColumn) -> Any? {
        guard let propertyValue, !(propertyValue is NSNull) else { return nil }

        switch column.storage {
        case .json:
            guard let data = try? JSONSerialization.data(withJSONObject: propertyValue, options: [.sortedKeys]) else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        case .scalar:
            switch column.declaration {
            case "TEXT":
                if let text = propertyValue as? String { return text }
                return nil
            case "INTEGER":
                if let number = propertyValue as? NSNumber { return number.int64Value }
                return nil
            case "REAL":
                if let number = propertyValue as? NSNumber { return number.doubleValue }
                return nil
            case "BLOB":
                if let text = propertyValue as? String { return Data(base64Encoded: text) }
                return nil
            default:
                return nil
            }
        }
    }
}
```

A `Bool` arriving from `JSONSerialization` is an `NSNumber`, so it binds through the `INTEGER` case as 0 or 1 without a special case.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter OwnedTableApplyTests`
Expected: PASS, all seven tests.

- [ ] **Step 5: Run the full suite and commit**

Run: `swift test`
Expected: PASS.

Add under `## Unreleased`, `### Added`:

```markdown
- `OwnedTable.apply(_:in:)`, which writes changes from LLVS into an owned table under suppression, so an applied change is not recorded as a local edit and sent straight back out. A value that is not a JSON object is skipped rather than failing the batch, and a property the value does not carry leaves its column null.
```

```bash
git add Sources/LLVSProjection/OwnedTableApply.swift Tests/LLVSProjectionTests/OwnedTableApplyTests.swift CHANGELOG.md
git commit -m "Apply incoming versions into an owned table"
```

---

### Task 5: A round trip, and two devices merging per column

The tasks so far each cover one half. This one proves the whole thing, including the claim the design rests on: two devices editing different columns of one row both keep their edit.

Nothing new is built. If a test here fails, the fault is in Tasks 1-4.

**Files:**
- Create: `Tests/LLVSProjectionTests/OwnedTableRoundTripTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1-4, plus `MergeableArbiter`, `Store.merge(version:with:resolvingWith:)`.

- [ ] **Step 1: Write the tests**

Create `Tests/LLVSProjectionTests/OwnedTableRoundTripTests.swift`. Declare the model at file scope:

```swift
@MergeableModel
struct RoundTripNote: StorableModel, Codable, Equatable {
    static let modelTypeIdentifier = "RoundTripNote"
    var title: String = ""
    var body: String = ""
}
```

The suite builds two stores and two databases, standing in for two devices.

```swift
@Test func aWriteSurvivesTheRoundTrip() throws {
    try deviceA.database.execute(
        statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
        withBindingsList: [["n1/RoundTripNote", "Hello", "World"]])

    let drained = try deviceA.table.drain(in: deviceA.database, store: deviceA.store, basedOn: nil)
    let versionId = try #require(drained.version)

    // Read it back as the model, which is what the app would decode.
    let value = try #require(try deviceA.store.value(id: .init("n1/RoundTripNote"), at: versionId))
    let note = try JSONDecoder().decode(RoundTripNote.self, from: value.data)
    #expect(note == RoundTripNote(title: "Hello", body: "World"))
}

/// The claim the whole design rests on. Two devices edit different columns of one row,
/// with no coordination, and both edits survive the merge.
@Test func twoDevicesEditingDifferentColumnsBothKeepTheirEdit() throws {
    // A common ancestor both devices share.
    try deviceA.database.execute(
        statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
        withBindingsList: [["n1/RoundTripNote", "Original", "Original body"]])
    let base = try #require(try deviceA.table.drain(in: deviceA.database, store: deviceA.store, basedOn: nil).version)

    // Device A edits the title.
    try deviceA.database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?",
        withBindingsList: [["A's title", "n1/RoundTripNote"]])
    let versionA = try #require(try deviceA.table.drain(in: deviceA.database, store: deviceA.store, basedOn: base).version)

    // Device B, from the same base, edits the body. Same store, so the merge can see both.
    let changesForB = try deviceA.store.valueChanges(updatingFrom: base, to: base)
    _ = changesForB
    try deviceA.database.execute(statement: "UPDATE notes SET title = ?, body = ? WHERE llvs_id = ?",
        withBindingsList: [["Original", "B's body", "n1/RoundTripNote"]])
    let versionB = try #require(try deviceA.table.drain(in: deviceA.database, store: deviceA.store, basedOn: base).version)

    let arbiter = MergeableArbiter()
    arbiter.register(RoundTripNote.self)
    let merged = try deviceA.store.merge(version: versionA, with: versionB, resolvingWith: arbiter)

    let value = try #require(try deviceA.store.value(id: .init("n1/RoundTripNote"), at: merged.id))
    let note = try JSONDecoder().decode(RoundTripNote.self, from: value.data)
    #expect(note.title == "A's title")
    #expect(note.body == "B's body")
}

/// Applying the merged result puts both edits back in the table, which is what the user sees.
@Test func theMergedResultLandsBackInTheTable() throws {
    try deviceA.database.execute(
        statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
        withBindingsList: [["n1/RoundTripNote", "Original", "Original body"]])
    let base = try #require(try deviceA.table.drain(in: deviceA.database, store: deviceA.store, basedOn: nil).version)

    try deviceA.database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?",
        withBindingsList: [["A's title", "n1/RoundTripNote"]])
    let versionA = try #require(try deviceA.table.drain(in: deviceA.database, store: deviceA.store, basedOn: base).version)

    try deviceA.database.execute(statement: "UPDATE notes SET title = ?, body = ? WHERE llvs_id = ?",
        withBindingsList: [["Original", "B's body", "n1/RoundTripNote"]])
    let versionB = try #require(try deviceA.table.drain(in: deviceA.database, store: deviceA.store, basedOn: base).version)

    let arbiter = MergeableArbiter()
    arbiter.register(RoundTripNote.self)
    let merged = try deviceA.store.merge(version: versionA, with: versionB, resolvingWith: arbiter)

    let changes = try deviceA.store.valueChanges(updatingFrom: versionB, to: merged.id)
    try deviceA.table.apply(changes, in: deviceA.database)

    var title: String?
    var body: String?
    try deviceA.database.forEach(matchingQuery: "SELECT title, body FROM notes WHERE llvs_id = 'n1/RoundTripNote'") { row in
        title = row.value(inColumnAtIndex: 0)
        body = row.value(inColumnAtIndex: 1)
    }
    #expect(title == "A's title")
    #expect(body == "B's body")
    // And it did not come back out as a local edit.
    #expect(try deviceA.table.changelogEntries(in: deviceA.database).isEmpty)
}

/// A delete racing an edit: the spec's stated rule is that the row comes back carrying the
/// other device's edit, because a returning row is visible and fixable while a discarded
/// edit is neither.
@Test func aDeleteRacingAnEditBringsTheRowBack() throws {
    try deviceA.database.execute(
        statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
        withBindingsList: [["n1/RoundTripNote", "Original", "Original body"]])
    let base = try #require(try deviceA.table.drain(in: deviceA.database, store: deviceA.store, basedOn: nil).version)

    try deviceA.database.execute(statement: "DELETE FROM notes WHERE llvs_id = ?",
        withBindingsList: [["n1/RoundTripNote"]])
    let deleted = try #require(try deviceA.table.drain(in: deviceA.database, store: deviceA.store, basedOn: base).version)

    try deviceA.table.apply([.insert(Value(id: .init("n1/RoundTripNote"),
        data: try JSONEncoder().encode(RoundTripNote(title: "Original", body: "Edited"))))], in: deviceA.database)
    try deviceA.database.execute(statement: "UPDATE notes SET body = ? WHERE llvs_id = ?",
        withBindingsList: [["Edited", "n1/RoundTripNote"]])
    let edited = try #require(try deviceA.table.drain(in: deviceA.database, store: deviceA.store, basedOn: base).version)

    let arbiter = MergeableArbiter()
    arbiter.register(RoundTripNote.self)
    let merged = try deviceA.store.merge(version: deleted, with: edited, resolvingWith: arbiter)

    let value = try deviceA.store.value(id: .init("n1/RoundTripNote"), at: merged.id)
    #expect(value != nil, "the spec states an edit beats a delete; the row should return")
}
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter OwnedTableRoundTripTests`
Expected: PASS.

`twoDevicesEditingDifferentColumnsBothKeepTheirEdit` is the one that matters. If it fails, do not adjust it — work out which task is wrong. The likely causes, in order: the drain is writing the whole row when only one column changed and that is correct, so the fault is more likely that `MergeableArbiter` was not registered, or the two versions do not share the ancestor they should.

If `aDeleteRacingAnEditBringsTheRowBack` fails, check which arbiter resolved it: `MergeableArbiter` falls back to `MostRecentChangeFavoringArbiter` for unregistered types, and the spec's rule assumes that fallback. Report what it actually did rather than changing the expectation.

- [ ] **Step 3: Run the full suite and commit**

Run: `swift test`
Expected: PASS.

```bash
git add Tests/LLVSProjectionTests/OwnedTableRoundTripTests.swift
git commit -m "Test the owned table round trip and per-column merge"
```

---

### Task 6: Typed reads

Rows come back as the model, with the row's identity and version alongside. Writes stay SQL, for the reason in the spec: an `UPDATE` naming one column is what makes column-level merge work, and a whole-row typed write would throw that away.

**Files:**
- Create: `Sources/LLVSProjection/TypedRead.swift`
- Create: `Tests/LLVSProjectionTests/TypedReadTests.swift`

**Interfaces:**
- Consumes: `OwnedTable`, `ModelSchema`, `StorableModel`, `SQLiteDatabase.forEach(matchingQuery:withBindings:rowHandler:)`.
- Produces:
  - `public struct ModelRow<Model: StorableModel>: Sendable where Model: Sendable` with `let model: Model`, `let id: Value.ID`, `let version: Version.ID?`.
  - `extension OwnedTable` with `func fetch<Model: StorableModel & Sendable>(_ type: Model.Type, in database: SQLiteDatabase, where clause: String? = nil, bindings: [Any?] = [], atVersion version: Version.ID? = nil) throws -> [ModelRow<Model>]`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LLVSProjectionTests/TypedReadTests.swift`. Reuse `RoundTripNote` from Task 5 by declaring a similar model at file scope, named `TypedNote`.

```swift
@Test func fetchReturnsModels() throws {
    try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
        withBindingsList: [["n1/TypedNote", "Hello", "World"]])

    let rows = try table.fetch(TypedNote.self, in: database)

    #expect(rows.count == 1)
    #expect(rows.first?.model == TypedNote(title: "Hello", body: "World"))
    #expect(rows.first?.id.rawValue == "n1/TypedNote")
}

@Test func fetchAppliesAWhereClause() throws {
    try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
        withBindingsList: [["n1/TypedNote", "Keep", "a"], ["n2/TypedNote", "Drop", "b"]])

    let rows = try table.fetch(TypedNote.self, in: database, where: "title = ?", bindings: ["Keep"])

    #expect(rows.count == 1)
    #expect(rows.first?.model.title == "Keep")
}

@Test func fetchCarriesTheVersionItWasReadAt() throws {
    try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
        withBindingsList: [["n1/TypedNote", "Hello", "World"]])
    let version = Version.ID("some-version")

    let rows = try table.fetch(TypedNote.self, in: database, atVersion: version)

    #expect(rows.first?.version == version)
}

@Test func fetchReturnsNothingForAnEmptyTable() throws {
    #expect(try table.fetch(TypedNote.self, in: database).isEmpty)
}

/// A row that cannot be decoded is left out rather than failing the query, so one bad row
/// does not blank a list view.
@Test func anUndecodableRowIsSkipped() throws {
    try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
        withBindingsList: [["n1/TypedNote", "Fine", "a"]])
    // A NULL in a non-optional String property cannot decode.
    try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, NULL, ?)",
        withBindingsList: [["n2/TypedNote", "b"]])

    let rows = try table.fetch(TypedNote.self, in: database)

    #expect(rows.count == 1)
    #expect(rows.first?.model.title == "Fine")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TypedReadTests`
Expected: FAIL to compile, "value of type 'OwnedTable' has no member 'fetch'".

- [ ] **Step 3: Write the implementation**

Create `Sources/LLVSProjection/TypedRead.swift`:

```swift
import Foundation
import LLVS
import LLVSModel
import LLVSSQLite

/// A row read from an owned table, as the model plus where it came from.
///
/// The identity and version travel with the model rather than being dropped, so a row knows
/// which value it is and what it was read at. That is what a typed write would need for
/// optimistic concurrency, and it costs one level of nesting now rather than an API break later.
public struct ModelRow<Model: StorableModel & Sendable>: Sendable {
    public let model: Model
    public let id: Value.ID
    /// The version the table held when this was read, when the caller knows it.
    public let version: Version.ID?
}

extension OwnedTable {

    /// Reads rows and decodes them into the model.
    ///
    /// `clause` is appended after `WHERE`, with `bindings` bound to its placeholders. It is
    /// the caller's own SQL: bind values rather than interpolating them.
    ///
    /// A row that cannot be decoded is left out rather than throwing, so one bad row does not
    /// blank a list. This mirrors how the read-only projection treats a value it cannot read.
    public func fetch<Model: StorableModel & Sendable>(
        _ type: Model.Type,
        in database: SQLiteDatabase,
        where clause: String? = nil,
        bindings: [Any?] = [],
        atVersion version: Version.ID? = nil
    ) throws -> [ModelRow<Model>] {
        let columnList = (["llvs_id"] + schema.columns.map(\.columnName)).joined(separator: ", ")
        var query = "SELECT \(columnList) FROM \(tableName)"
        if let clause { query += " WHERE \(clause)" }

        var rows: [ModelRow<Model>] = []
        let decoder = JSONDecoder()

        try database.forEach(matchingQuery: query, withBindings: bindings) { row in
            guard let rawId: String = row.value(inColumnAtIndex: 0) else { return }

            var object: [String: Any] = [:]
            for (offset, column) in self.schema.columns.enumerated() {
                let index = offset + 1 // llvs_id occupies column 0
                switch column.storage {
                case .json:
                    if let text: String = row.value(inColumnAtIndex: index),
                       let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
                        object[column.propertyName] = parsed
                    }
                case .scalar:
                    switch column.declaration {
                    case "TEXT":
                        if let text: String = row.value(inColumnAtIndex: index) { object[column.propertyName] = text }
                    case "INTEGER":
                        if let number: Int64 = row.value(inColumnAtIndex: index) { object[column.propertyName] = number }
                    case "REAL":
                        if let number: Double = row.value(inColumnAtIndex: index) { object[column.propertyName] = number }
                    case "BLOB":
                        if let data: Data = row.value(inColumnAtIndex: index) {
                            object[column.propertyName] = data.base64EncodedString()
                        }
                    default:
                        break
                    }
                }
            }

            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let model = try? decoder.decode(Model.self, from: data) else {
                return
            }
            rows.append(ModelRow(model: model, id: .init(rawId), version: version))
        }

        return rows
    }
}
```

The column-to-JSON mapping here is the same shape as `OwnedTableDrain.rowData`. If a third copy appears, factor it out; two is not yet worth an abstraction that would have to serve both directions.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TypedReadTests`
Expected: PASS, all five tests.

- [ ] **Step 5: Run the full suite and commit**

Run: `swift test`
Expected: PASS.

Add under `## Unreleased`, `### Added`:

```markdown
- `OwnedTable.fetch(_:in:where:bindings:atVersion:)`, which reads rows as the model rather than as columns. Each result carries the model, its value ID and the version it was read at, so a row knows where it came from. A row that cannot be decoded is left out rather than failing the query. Writes stay ordinary SQL on purpose: an `UPDATE` naming one column is what lets two devices editing different columns of one row both keep their edit, and a whole-row typed write would claim every column changed.
```

```bash
git add Sources/LLVSProjection/TypedRead.swift Tests/LLVSProjectionTests/TypedReadTests.swift CHANGELOG.md
git commit -m "Read owned table rows as models"
```

---

### Task 7: Drain before rebuild, and document the whole thing

The spec's migration rule: a rebuild must drain first, or local edits that never reached LLVS are discarded with the table. This wires that in and writes the README section.

**Files:**
- Modify: `Sources/LLVSProjection/Projector.swift` (the `rebuild(at:)` path)
- Create: `Tests/LLVSProjectionTests/OwnedTableMigrationTests.swift`
- Modify: `README.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: `OwnedTable.drain(in:store:basedOn:)` (Task 3).
- Produces: `Projector` gains `func registerOwnedTable(_ table: OwnedTable)` and drains every registered owned table before a rebuild discards its rows.

- [ ] **Step 1: Write the failing test**

Create `Tests/LLVSProjectionTests/OwnedTableMigrationTests.swift`:

```swift
/// The rule the spec states: rebuilding discards the table, so anything the app wrote that
/// has not yet reached LLVS must be drained first or it is lost.
@Test func aRebuildDrainsPendingLocalEditsFirst() throws {
    try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
        withBindingsList: [["n1/Note", "Unsynced", "Body"]])
    // Not drained: this edit exists only in SQLite.

    let projector = try makeProjector(registering: table)
    let version = try projector.rebuildOwnedTables(store: store, basedOn: nil)

    // The edit reached LLVS rather than being discarded with the table.
    let versionId = try #require(version)
    #expect(try store.value(id: .init("n1/Note"), at: versionId) != nil)
}

@Test func aFailedDrainCancelsTheRebuild() throws {
    try database.execute(statement: "INSERT INTO notes (llvs_id, title, body) VALUES (?, ?, ?)",
        withBindingsList: [["n1/Note", "Unsynced", "Body"]])

    // Make the drain fail by removing the table it reads from.
    try database.execute(statement: "DROP TABLE notes")

    let projector = try makeProjector(registering: table)
    #expect(throws: (any Swift.Error).self) {
        _ = try projector.rebuildOwnedTables(store: self.store, basedOn: nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter OwnedTableMigrationTests`
Expected: FAIL to compile, no `registerOwnedTable` or `rebuildOwnedTables`.

- [ ] **Step 3: Implement**

In `Sources/LLVSProjection/Projector.swift`, add storage for registered owned tables and the drain-then-rebuild entry point:

```swift
private var ownedTables: [OwnedTable] = []

/// Registers an owned table so its pending local edits are drained before a rebuild
/// discards its rows.
public func registerOwnedTable(_ table: OwnedTable) {
    ownedTables.append(table)
}

/// Drains every registered owned table into `store`, then returns the version that
/// resulted, or `basedOn` when nothing was pending.
///
/// Draining comes first and the order is forced: a rebuild throws the table away, so an
/// edit that has not reached LLVS would be lost. A drain that throws cancels the rebuild —
/// running on the old schema is better than losing a user's unsynced work.
@discardableResult
public func rebuildOwnedTables(store: Store, basedOn predecessor: Version.ID?) throws -> Version.ID? {
    var head = predecessor
    for table in ownedTables {
        let result = try table.drain(in: database, store: store, basedOn: head)
        if let version = result.version { head = version }
    }
    return head
}
```

Note `Projector` is a class with `let` fields today; `ownedTables` is the first `var`. It is documented as single-isolation and lives inside `ProjectionFollower`'s actor, so this does not change its safety story — but say so in the property's comment.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter OwnedTableMigrationTests`
Expected: PASS.

- [ ] **Step 5: Write the README section**

Add to `README.md` after the "Querying with LLVSProjection" section. Do not hard-wrap paragraphs.

````markdown
## Local-First SQLite

The section above is one-way: LLVS is the truth, the SQLite an index over it, and you write through `StoreCoordinator`. An owned table turns that around. You write ordinary SQL, and those writes become versions that sync and merge.

Think of it as a checkout: the SQLite holds the state at some version, and writing to it makes a new one.

```swift
@MergeableModel
struct Note: StorableModel, Codable, Equatable {
    static let modelTypeIdentifier = "Note"
    var title: String = ""
    var body: String = ""
    var updatedAt: Date = .now
}

let table = OwnedTable(
    typeIdentifier: Note.modelTypeIdentifier,
    tableName: "notes",
    schema: Note.sqliteSchema)
for statement in table.createStatements() { try database.execute(statement: statement) }
```

The table is ordinary. Index it however you like:

```sql
CREATE INDEX notes_updated ON notes(updated_at);
```

Write ordinary SQL. Triggers record what changed:

```swift
try database.execute(statement: "UPDATE notes SET title = ? WHERE llvs_id = ?",
                     withBindingsList: [["New title", noteId]])

let drained = try table.drain(in: database, store: store, basedOn: currentVersion)
```

Read rows as models:

```swift
let rows = try table.fetch(Note.self, in: database, where: "updated_at > ?", bindings: [cutoff])
for row in rows { print(row.model.title, row.id) }
```

### A column per property

`@MergeableModel` generates the schema. A property whose type is `String`, `Int`, `Double`, `Bool`, `Date`, `UUID` or `Data` — or an optional of one — becomes a real column you can index. Anything else becomes a `TEXT` column holding JSON, which is still queryable through `json_extract` and `json_each`.

Only the awkward property becomes JSON. A model with an array of tags still gets a plain indexed `TEXT` column for its title.

A property whose type is inferred rather than written down, such as `var count = 0`, gets no column, because a macro sees only syntax. Annotate it: `var count: Int = 0`.

### How conflicts resolve

The merge happens in LLVS, not in SQLite, which never sees a conflict. A row change becomes a value, and values merge the way they always have.

Because a column is a property, `MergeableArbiter` merges them independently: if you edit a note's title on your phone while a share extension edits its body, both survive. Register your types and that is the behaviour you get.

Two devices changing the *same* column is a genuine conflict, and it goes to your `MergeArbiter`, which is what it is for.

A delete racing an edit brings the row back carrying the edit, because the default arbiter favours the more recent change. A row that reappears is visible and fixable; an edit that silently vanished is neither. Change that in your arbiter if your app wants the opposite.

### Two rules worth knowing

**Writes are SQL, reads are typed.** That is deliberate. `UPDATE notes SET title = ?` says only the title changed, and that is what lets your edit and another device's merge. A `save(note)` writing every column would claim they all changed and throw that away.

**A rebuild drains first.** Raising `schemaVersion` rebuilds the table from LLVS, so anything written but not yet drained must reach LLVS before the table is discarded. `rebuildOwnedTables` does that, and a failed drain cancels the rebuild rather than losing the work.

Your own `BEGIN`/`COMMIT` needs nothing special: triggers fire inside your transaction, so a committed one yields a version and a rolled-back one yields nothing.
````

- [ ] **Step 6: Changelog, full suite, commit**

Add under `## Unreleased`, `### Added`:

```markdown
- `Projector.registerOwnedTable(_:)` and `rebuildOwnedTables(store:basedOn:)`. A rebuild discards a table's rows, so an owned table's pending local edits are drained into LLVS first; a drain that fails cancels the rebuild, because running on the old schema beats losing a user's unsynced work.
```

Run: `swift test` and `swift build --enable-all-traits`
Expected: PASS and Build complete.

```bash
git add Sources/LLVSProjection/Projector.swift Tests/LLVSProjectionTests/OwnedTableMigrationTests.swift README.md CHANGELOG.md
git commit -m "Drain owned tables before rebuilding, and document local-first SQLite"
```

---

## Deferred, deliberately

**Typed writes.** They need a diff of the model against the stored row to recover what a plain `UPDATE` states outright. Doing them the easy way — writing every column — would destroy the per-column granularity that makes concurrent edits merge. Worth building, separately, with that diff in it.

**Generating the `OwnedTable` from the type alone.** Today an app passes `typeIdentifier`, `tableName` and `Note.sqliteSchema` separately. A small convenience could take just `Note.self`. Left out until the shape has been used in an app.

**An owned table under `ProjectionFollower`.** The follower currently drives one-way projection. Wiring drain-and-apply into its loop is the natural next step, and is deliberately not in this plan: each of Tasks 3, 4 and 7 is independently testable without it, and the loop's policy questions — how often to drain, whether to drain before or after exchanging — deserve their own design pass.

**Measuring a drain against a large table.** The drain reads one row per touched value. That is proportional to what changed rather than to the table, which is the right shape, but it has not been measured. `PerformanceTests` is where that belongs.
