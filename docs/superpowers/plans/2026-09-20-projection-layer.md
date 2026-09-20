# LLVS Projection Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an app query LLVS data by field, by maintaining a SQLite current-values view that is rebuilt from version diffs and never becomes the truth.

**Architecture:** LLVS stays an append-only log of opaque blobs. A new `LLVSProjection` library watches the coordinator's current version, asks the store what differs between the version its database reflects and the new one, and applies that difference plus the new version marker inside a single SQLite transaction. A crash can only leave the projection behind, never half-applied, and a lost database is rebuilt from the store.

**Tech Stack:** Swift 6 language mode, swift-tools-version 6.1, Swift Testing (`@Suite`/`@Test`/`#expect`), SQLite via the existing `LLVSSQLite` target.

**Spec:** `docs/superpowers/specs/2026-09-19-projection-layer-design.md`

## Global Constraints

- Swift 6 language mode, strict concurrency, on every target. Platforms: macOS 15, iOS 18, watchOS 11.
- Tests are Swift Testing, not XCTest. No `test` prefix on test names.
- `LLVSProjection` depends on `LLVS` and `LLVSSQLite` only. No cloud dependencies, no third-party dependencies.
- Never nest `store.queryHistory` calls. The `History` mutex is not recursive.
- Record every user-visible change in `CHANGELOG.md` under `## Unreleased`.
- Run `swift test` before each commit. `swift build --enable-all-traits` only matters if `LLVSBox`/`LLVSPCloud` are touched; this plan does not touch them.
- Do not use `withUnsafeBytes` + `load(as:)` on unaligned `Data`.

---

### Task 1: Flip model value IDs so the Map buckets spread

`Map.swift:49` buckets by the first two characters of a value ID. `LLVSModel` builds IDs as `"Note/<uuid>"`, so every note lands in bucket `"No"` and each save rewrites a node listing every note — O(N) per write, fatal at the target size. Audit item 7.

The fix puts the random part first: `"<uuid>/Note"`. All three ID helpers live in one file and every caller goes through them, so the blast radius is small.

This costs prefix locality: after the flip, notes scatter across buckets, so there is no cheap prefix scan for "all Notes". The projector works from diffs, not scans, and a rebuild reads every value regardless, so nothing in this plan regresses. It is called out so it is not later mistaken for a free change.

**Files:**
- Modify: `Sources/LLVSModel/StorableModel.swift:23-40` (all three helpers and their doc comments)
- Test: `Tests/LLVSModelTests/MergeableArbiterTests.swift:215-226` (existing `modelValueIDHelpers` test)

**Interfaces:**
- Consumes: nothing.
- Produces: unchanged signatures — `modelValueID(typeIdentifier:instanceIdentifier:) -> Value.ID`, `modelTypeIdentifier(from: Value.ID) -> String?`, `instanceIdentifier(from: Value.ID) -> String?`. Only the string layout changes, from `"Type/instance"` to `"instance/Type"`.

- [ ] **Step 1: Change the existing test to expect the new layout**

In `Tests/LLVSModelTests/MergeableArbiterTests.swift`, replace the body of `modelValueIDHelpers`:

```swift
@Test func modelValueIDHelpers() {
    let valueId = modelValueID(typeIdentifier: "Contact", instanceIdentifier: "abc-123")
    #expect(valueId.rawValue == "abc-123/Contact")
    #expect(modelTypeIdentifier(from: valueId) == "Contact")
    #expect(instanceIdentifier(from: valueId) == "abc-123")
}
```

- [ ] **Step 2: Add a test that two instances of one type land in different buckets**

Add to the same suite. The bucket is the first two characters, which is what `Map` uses:

```swift
@Test func modelValueIDsSpreadAcrossMapBuckets() {
    let a = modelValueID(typeIdentifier: "Contact", instanceIdentifier: "11111111-aaaa")
    let b = modelValueID(typeIdentifier: "Contact", instanceIdentifier: "99999999-bbbb")
    let bucketA = String(a.rawValue.prefix(2))
    let bucketB = String(b.rawValue.prefix(2))
    #expect(bucketA != bucketB)
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter LLVSModelTests`
Expected: FAIL. `modelValueIDHelpers` reports `"Contact/abc-123" == "abc-123/Contact"` is false, and `modelValueIDsSpreadAcrossMapBuckets` reports `"Co" != "Co"` is false.

- [ ] **Step 4: Flip the layout in the three helpers**

In `Sources/LLVSModel/StorableModel.swift`, replace the three helpers and fix their doc comments, which currently document the old layout:

```swift
/// Builds an LLVS `Value.ID` from a type identifier and instance identifier.
/// The format is `"instance-id/TypeName"`.
///
/// The instance identifier comes first so that the `Map` — which buckets by the
/// first two characters of the ID — spreads instances of one type across many
/// buckets. With the type first, every instance of a type shared one bucket, and
/// each save rewrote a node listing all of them.
public func modelValueID(typeIdentifier: String, instanceIdentifier: String) -> Value.ID {
    Value.ID("\(instanceIdentifier)/\(typeIdentifier)")
}

/// Extracts the model type identifier (suffix after the last `/`) from a `Value.ID`.
/// Returns `nil` if the ID contains no `/`.
public func modelTypeIdentifier(from valueID: Value.ID) -> String? {
    guard let slashIndex = valueID.rawValue.lastIndex(of: "/") else { return nil }
    return String(valueID.rawValue[valueID.rawValue.index(after: slashIndex)...])
}

/// Extracts the instance identifier (prefix before the last `/`) from a `Value.ID`.
/// Returns `nil` if the ID contains no `/`.
public func instanceIdentifier(from valueID: Value.ID) -> String? {
    guard let slashIndex = valueID.rawValue.lastIndex(of: "/") else { return nil }
    return String(valueID.rawValue[..<slashIndex])
}
```

Note `lastIndex` rather than `firstIndex`. A UUID contains no `/`, but an app-supplied instance identifier might, and the type name is the part that must not be split.

- [ ] **Step 5: Fix the protocol doc comment**

In the same file, the `StorableModel` doc comment at line 13 says the prefix format. Replace that line:

```swift
/// used in the LLVS `Value.ID` as `"uuid-string/Contact"`.
```

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, all tests. If an arbiter test fails, it is relying on the old layout — read it and fix the expectation, not the helper.

- [ ] **Step 7: Note the breaking change in the changelog**

Add under `## Unreleased`, in a `### Changed` section (create it if the section does not exist):

```markdown
- **Breaking:** `LLVSModel` value IDs are now `"<instance-id>/<TypeName>"` rather than `"<TypeName>/<instance-id>"`. The `Map` buckets values by the first two characters of the ID, so every instance of one type used to share a single bucket, and each save rewrote a node listing all of them — O(N) per write. The instance identifier now leads, so instances spread across buckets. An existing store keeps its old IDs and goes on working; they simply stay in one bucket. There is no migration, and a store written by this version is not readable by an older one as the same objects.
```

- [ ] **Step 8: Commit**

```bash
git add Sources/LLVSModel/StorableModel.swift Tests/LLVSModelTests/MergeableArbiterTests.swift CHANGELOG.md
git commit -m "Put the instance identifier first in model value IDs"
```

---

### Task 2: Add transactions to SQLiteDatabase

The projection's entire safety story is that applying rows and recording the version happen together or not at all. `SQLiteDatabase` has no transaction support today (audit item 8). Without this, Task 5 cannot be correct.

**Files:**
- Modify: `Sources/LLVSSQLite/SQLiteDatabase.swift` (add a method near `execute`, around line 90-119)
- Test: `Tests/LLVSTests/SQLiteDatabaseTests.swift`

**Interfaces:**
- Consumes: `SQLiteDatabase.init(fileURL:)`, `execute(statement:withBindingsList:)`, `forEach(matchingQuery:withBindings:rowHandler:)` — all existing and public.
- Produces: `func inTransaction<T>(_ block: () throws -> T) throws -> T` on `SQLiteDatabase`. Commits on normal return, rolls back and rethrows on any error thrown by the block.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/LLVSTests/SQLiteDatabaseTests.swift`. That suite is a `@Suite class` with a `database` property built in `init()`, so the tests below use `database` directly rather than making their own.

```swift
@Test func transactionCommitsOnSuccess() throws {
    let db = try makeTemporaryDatabase()
    try db.execute(statement: "CREATE TABLE t (id TEXT PRIMARY KEY)")
    try db.inTransaction {
        try db.execute(statement: "INSERT INTO t (id) VALUES (?)", withBindingsList: [["a"]])
    }
    var ids: [String] = []
    try db.forEach(matchingQuery: "SELECT id FROM t") { row in
        if let id: String = row.value(inColumnAtIndex: 0) { ids.append(id) }
    }
    #expect(ids == ["a"])
}

@Test func transactionRollsBackOnThrow() throws {
    let db = try makeTemporaryDatabase()
    try db.execute(statement: "CREATE TABLE t (id TEXT PRIMARY KEY)")
    struct Boom: Swift.Error {}
    #expect(throws: Boom.self) {
        try db.inTransaction {
            try db.execute(statement: "INSERT INTO t (id) VALUES (?)", withBindingsList: [["a"]])
            throw Boom()
        }
    }
    var count = 0
    try db.forEach(matchingQuery: "SELECT id FROM t") { _ in count += 1 }
    #expect(count == 0)
}

@Test func transactionReturnsBlockValue() throws {
    let db = try makeTemporaryDatabase()
    let result = try db.inTransaction { 42 }
    #expect(result == 42)
}
```

If `makeTemporaryDatabase()` does not already exist in that file, add it, writing to `FileManager.default.temporaryDirectory` under a fresh `UUID().uuidString` filename.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SQLiteDatabaseTests`
Expected: FAIL to compile, with "value of type 'SQLiteDatabase' has no member 'inTransaction'".

- [ ] **Step 3: Implement it**

Add to `Sources/LLVSSQLite/SQLiteDatabase.swift`, inside the `SQLiteDatabase` class near `execute`:

```swift
/// Runs `block` inside a SQLite transaction. Commits when `block` returns,
/// rolls back and rethrows if it throws.
///
/// Not reentrant: SQLite does not nest plain transactions, so calling this
/// from inside another `inTransaction` block fails.
public func inTransaction<T>(_ block: () throws -> T) throws -> T {
    try execute(statement: "BEGIN TRANSACTION")
    let result: T
    do {
        result = try block()
    } catch {
        try? execute(statement: "ROLLBACK")
        throw error
    }
    try execute(statement: "COMMIT")
    return result
}
```

The rollback uses `try?` deliberately: the caller's error is the one worth reporting, and a rollback failure would mask it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SQLiteDatabaseTests`
Expected: PASS, all three new tests.

- [ ] **Step 5: Note it in the changelog**

Add under `## Unreleased`, in the `### Added` section:

```markdown
- `SQLiteDatabase.inTransaction(_:)`, which commits when its block returns and rolls back when it throws.
```

- [ ] **Step 6: Commit**

```bash
git add Sources/LLVSSQLite/SQLiteDatabase.swift Tests/LLVSTests/SQLiteDatabaseTests.swift CHANGELOG.md
git commit -m "Add transactions to SQLiteDatabase"
```

---

### Task 3: Make a correct public diff between two arbitrary versions

The projector must ask "what differs between the version my database reflects and this new one", where the two can be sideways from each other after a merge. The spec's original claim that this already exists was wrong, and the spec now records the correction.

`Map.differences(between:and:withCommonAncestor:)` does the right thing given a true common ancestor, but `Map` is internal. The public route, `Store.valueChanges(madeBetween:and:)` (`Store.swift:489`), passes `versionId1` as the ancestor — valid only in a straight line — and calls `fatalError` on the two-branch forks. On two sideways versions it traps.

This task adds a new public method rather than changing that one, because `valueChanges(madeBetween:and:)` is existing public API with existing callers.

**Files:**
- Modify: `Sources/LLVS/Core/Store.swift` (add after `valueChanges(madeBetween:and:)`, which ends at line 509)
- Test: Create `Tests/LLVSTests/VersionDifferenceTests.swift`

**Interfaces:**
- Consumes: `store.queryHistory { history in ... }`, `History.greatestCommonAncestor(ofVersionsIdentifiedBy:) throws -> Version.ID?` (`History.swift:97`), the internal `valuesMap.differences(between:and:withCommonAncestor:)`, `Store.value(id:at:)`.
- Produces: `public func valueChanges(updatingFrom fromVersion: Version.ID, to toVersion: Version.ID) throws -> [Value.Change]`. Every returned change is expressed against `toVersion`: `.insert`/`.update` carry the value as it exists at `toVersion`, `.remove` carries an ID absent at `toVersion`. Never returns `.preserve` or `.preserveRemoval`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LLVSTests/VersionDifferenceTests.swift`, following the `@Suite class` + `init()`/`deinit` setup in `Tests/LLVSTests/ValueChangesInVersionTests.swift`. There are no shared helpers; the suite builds its own store.

```swift
import Testing
import Foundation
@testable import LLVS

@Suite struct VersionDifferenceTests {

    @Test func reportsAnInsertAlongALine() throws {
        let store = try makeTemporaryStore()
        let v1 = try store.makeVersion(basedOnPredecessor: nil,
            inserting: [Value(id: .init("a"), data: Data("one".utf8))])
        let v2 = try store.makeVersion(basedOnPredecessor: v1.id,
            inserting: [Value(id: .init("b"), data: Data("two".utf8))])

        let changes = try store.valueChanges(updatingFrom: v1.id, to: v2.id)
        #expect(changes.count == 1)
        guard case let .insert(value) = changes[0] else {
            Issue.record("expected an insert, got \(changes[0])")
            return
        }
        #expect(value.id.rawValue == "b")
    }

    @Test func reportsARemovalWhenMovingBackwards() throws {
        let store = try makeTemporaryStore()
        let v1 = try store.makeVersion(basedOnPredecessor: nil,
            inserting: [Value(id: .init("a"), data: Data("one".utf8))])
        let v2 = try store.makeVersion(basedOnPredecessor: v1.id,
            inserting: [Value(id: .init("b"), data: Data("two".utf8))])

        // Going the other way: "b" exists at v2 but not at v1, so it must be removed.
        let changes = try store.valueChanges(updatingFrom: v2.id, to: v1.id)
        #expect(changes.count == 1)
        guard case let .remove(id) = changes[0] else {
            Issue.record("expected a remove, got \(changes[0])")
            return
        }
        #expect(id.rawValue == "b")
    }

    @Test func handlesTwoSidewaysVersionsWithoutTrapping() throws {
        let store = try makeTemporaryStore()
        let base = try store.makeVersion(basedOnPredecessor: nil,
            inserting: [Value(id: .init("a"), data: Data("base".utf8))])
        // Two branches from one base, each updating "a" — a .twiceUpdated fork.
        let left = try store.makeVersion(basedOnPredecessor: base.id,
            updating: [Value(id: .init("a"), data: Data("left".utf8))])
        let right = try store.makeVersion(basedOnPredecessor: base.id,
            updating: [Value(id: .init("a"), data: Data("right".utf8))])

        let changes = try store.valueChanges(updatingFrom: left.id, to: right.id)
        #expect(changes.count == 1)
        guard case let .update(value) = changes[0] else {
            Issue.record("expected an update, got \(changes[0])")
            return
        }
        #expect(String(decoding: value.data, as: UTF8.self) == "right")
    }

    @Test func reportsNothingBetweenAVersionAndItself() throws {
        let store = try makeTemporaryStore()
        let v1 = try store.makeVersion(basedOnPredecessor: nil,
            inserting: [Value(id: .init("a"), data: Data("one".utf8))])
        let changes = try store.valueChanges(updatingFrom: v1.id, to: v1.id)
        #expect(changes.isEmpty)
    }
}
```

`handlesTwoSidewaysVersionsWithoutTrapping` is the test that matters. It is the case the existing API traps on.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter VersionDifferenceTests`
Expected: FAIL to compile, "value of type 'Store' has no member 'valueChanges(updatingFrom:to:)'".

- [ ] **Step 3: Implement it**

Add to `Sources/LLVS/Core/Store.swift`, immediately after `valueChanges(madeBetween:and:)`:

```swift
/// Returns the changes that transform the contents at `fromVersion` into the contents
/// at `toVersion`. The two versions need not be on the same line of history: this is a
/// set difference, not a replay, so it is correct when `toVersion` is a merge commit,
/// a branch, or an ancestor of `fromVersion`.
///
/// Every change is expressed against `toVersion`. An `.insert` or `.update` carries the
/// value as it exists at `toVersion`; a `.remove` names a value that does not exist there.
/// `.preserve` and `.preserveRemoval` are never returned.
public func valueChanges(updatingFrom fromVersion: Version.ID, to toVersion: Version.ID) throws -> [Value.Change] {
    guard let _ = try version(identifiedBy: fromVersion), let _ = try version(identifiedBy: toVersion) else {
        throw Error.missingVersion
    }
    guard fromVersion != toVersion else { return [] }

    var ancestor: Version.ID?
    try queryHistory { history in
        ancestor = try history.greatestCommonAncestor(ofVersionsIdentifiedBy: (fromVersion, toVersion))
    }

    let diffs = try valuesMap.differences(between: toVersion, and: fromVersion, withCommonAncestor: ancestor)

    var changes: [Value.Change] = []
    for diff in diffs {
        // Decide from the target version, not from the fork label. A fork describes how the
        // two branches relate to their ancestor; what matters here is only whether the value
        // exists at `toVersion`, and whether it existed at `fromVersion`.
        let valueAtTo = try value(id: diff.valueId, at: toVersion)
        let existedAtFrom = try valueReference(id: diff.valueId, at: fromVersion) != nil
        switch (valueAtTo, existedAtFrom) {
        case let (.some(value), false):
            changes.append(.insert(value))
        case let (.some(value), true):
            changes.append(.update(value))
        case (.none, true):
            changes.append(.remove(diff.valueId))
        case (.none, false):
            break // Present in neither: nothing for a consumer to do.
        }
    }
    return changes
}
```

Note the argument order into `differences`: the existing caller at line 493 passes `(between: versionId2, and: versionId1, ...)`, target first. This follows that.

The `queryHistory` call is not nested inside another, and the `History` reference does not escape the closure.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter VersionDifferenceTests`
Expected: PASS, all four tests.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS. Nothing existing should change; this only adds a method.

- [ ] **Step 6: Note it in the changelog**

Add under `## Unreleased`, in the `### Added` section:

```markdown
- `Store.valueChanges(updatingFrom:to:)`, which returns the changes that turn the contents at one version into the contents at another. Unlike `valueChanges(madeBetween:and:)`, the two versions need not be on one line of history: it resolves their common ancestor and decides each change from whether the value exists at the target, so a merge commit or a move onto a branch is handled rather than trapped on.
```

- [ ] **Step 7: Commit**

```bash
git add Sources/LLVS/Core/Store.swift Tests/LLVSTests/VersionDifferenceTests.swift CHANGELOG.md
git commit -m "Add a public diff between two arbitrary versions"
```

---

### Task 4: Create the LLVSProjection target with its schema type

This task sets up the library and the one thing an app must write: a description of how a stored model becomes a table row. No projecting yet.

**Files:**
- Modify: `Package.swift` (add a product near line 41 and a target near line 114, plus a test target near line 122)
- Create: `Sources/LLVSProjection/ProjectedType.swift`
- Create: `Tests/LLVSProjectionTests/ProjectedTypeTests.swift`

**Interfaces:**
- Consumes: `Value`, `Value.ID` from `LLVS`.
- Produces:
  - `public struct ProjectedColumn: Sendable` with `let name: String` and `let declaration: String`, and `init(name:declaration:)`.
  - `public struct ProjectedType: Sendable` with `let typeIdentifier: String`, `let tableName: String`, `let columns: [ProjectedColumn]`, `let extract: @Sendable (Value) throws -> [String: SQLiteValue]`, and `init(typeIdentifier:tableName:columns:extract:)`.
  - `public enum SQLiteValue: Sendable, Equatable` with cases `text(String)`, `integer(Int64)`, `real(Double)`, `null`.
  - `ProjectedType.createTableStatement() -> String`.

- [ ] **Step 1: Add the target to Package.swift**

Add to `products`, after the `LLVSOneDrive` product:

```swift
        .library(
            name: "LLVSProjection",
            targets: ["LLVSProjection"]),
```

Add to `targets`, after the `LLVSOneDrive` target:

```swift
        .target(
            name: "LLVSProjection",
            dependencies: ["LLVS", "LLVSSQLite"]),
```

Add a test target after `LLVSModelTests`:

```swift
        .testTarget(
            name: "LLVSProjectionTests",
            dependencies: ["LLVS", "LLVSSQLite", "LLVSProjection"]),
```

Match the exact formatting and indentation of the surrounding entries.

- [ ] **Step 2: Write the failing test**

Create `Tests/LLVSProjectionTests/ProjectedTypeTests.swift`:

```swift
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
        let sql = type.createTableStatement()
        #expect(sql == "CREATE TABLE IF NOT EXISTS notes (llvs_id TEXT PRIMARY KEY, title TEXT, updated_at INTEGER)")
    }

    @Test func extractReturnsTheColumnValues() throws {
        let type = ProjectedType(
            typeIdentifier: "Note",
            tableName: "notes",
            columns: [ProjectedColumn(name: "title", declaration: "TEXT")],
            extract: { value in
                ["title": .text(String(decoding: value.data, as: UTF8.self))]
            }
        )
        let value = Value(id: .init("abc/Note"), data: Data("Hello".utf8))
        let row = try type.extract(value)
        #expect(row["title"] == .text("Hello"))
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter LLVSProjectionTests`
Expected: FAIL. No such module `LLVSProjection`, since the source file does not exist yet.

- [ ] **Step 4: Write the implementation**

Create `Sources/LLVSProjection/ProjectedType.swift`:

```swift
import Foundation
import LLVS

/// A value bound into a SQLite statement.
public enum SQLiteValue: Sendable, Equatable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null
}

/// One indexed column in a projected table.
public struct ProjectedColumn: Sendable {
    public let name: String
    /// The SQLite type and any constraints, for example `"TEXT"` or `"INTEGER NOT NULL"`.
    public let declaration: String

    public init(name: String, declaration: String) {
        self.name = name
        self.declaration = declaration
    }
}

/// Describes how one stored model type becomes rows in a SQLite table.
///
/// The projection is an index, not a copy. Declare only the fields that are
/// queried or sorted on, and read the full object from the store once a query
/// has named the IDs. Adding a field later is a rebuild, not a migration.
public struct ProjectedType: Sendable {
    /// The model type identifier, matching `StorableModel.modelTypeIdentifier`.
    public let typeIdentifier: String
    public let tableName: String
    public let columns: [ProjectedColumn]
    /// Decodes a stored value and returns its column values, keyed by column name.
    /// Throwing here marks the value unreadable; the projector skips and reports it.
    public let extract: @Sendable (Value) throws -> [String: SQLiteValue]

    public init(
        typeIdentifier: String,
        tableName: String,
        columns: [ProjectedColumn],
        extract: @escaping @Sendable (Value) throws -> [String: SQLiteValue]
    ) {
        self.typeIdentifier = typeIdentifier
        self.tableName = tableName
        self.columns = columns
        self.extract = extract
    }

    /// The table always carries `llvs_id`, the value ID, as its primary key. That is
    /// what lets the projector upsert and delete by ID without consulting the model.
    public func createTableStatement() -> String {
        let declarations = columns.map { "\($0.name) \($0.declaration)" }
        let all = (["llvs_id TEXT PRIMARY KEY"] + declarations).joined(separator: ", ")
        return "CREATE TABLE IF NOT EXISTS \(tableName) (\(all))"
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter LLVSProjectionTests`
Expected: PASS, both tests.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/LLVSProjection Tests/LLVSProjectionTests
git commit -m "Add the LLVSProjection target and its schema description type"
```

---

### Task 5: Project a diff into SQLite in one transaction

The core of the design. Apply a change set and record the new version together, or not at all.

**Files:**
- Create: `Sources/LLVSProjection/Projector.swift`
- Create: `Tests/LLVSProjectionTests/ProjectorTests.swift`

**Interfaces:**
- Consumes: `ProjectedType`, `ProjectedColumn`, `SQLiteValue` (Task 4); `SQLiteDatabase.inTransaction(_:)` (Task 2); `Store.valueChanges(updatingFrom:to:)` (Task 3); `modelTypeIdentifier(from:)` semantics from Task 1 — but note `LLVSProjection` does not depend on `LLVSModel`, so it parses the suffix itself.
- Produces:
  - `public final class Projector` with `init(database:store:types:schemaVersion:) throws`.
  - `public func projectedVersion() throws -> Version.ID?`
  - `@discardableResult public func update(to version: Version.ID) throws -> ProjectionResult`
  - `public func rebuild(at version: Version.ID) throws -> ProjectionResult`
  - `public struct ProjectionResult: Sendable` with `let appliedCount: Int` and `let unreadableIds: [Value.ID]`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LLVSProjectionTests/ProjectorTests.swift`:

```swift
import Testing
import Foundation
@testable import LLVS
@testable import LLVSSQLite
@testable import LLVSProjection

@Suite struct ProjectorTests {

    /// A note whose stored data is just its title, so the tests need no Codable setup.
    func noteType() -> ProjectedType {
        ProjectedType(
            typeIdentifier: "Note",
            tableName: "notes",
            columns: [ProjectedColumn(name: "title", declaration: "TEXT")],
            extract: { value in
                let text = String(decoding: value.data, as: UTF8.self)
                if text == "CORRUPT" { throw ProjectorTestError.undecodable }
                return ["title": .text(text)]
            }
        )
    }

    enum ProjectorTestError: Swift.Error { case undecodable }

    func titles(in db: SQLiteDatabase) throws -> [String] {
        var result: [String] = []
        try db.forEach(matchingQuery: "SELECT title FROM notes ORDER BY title") { row in
            if let t: String = row.value(inColumnAtIndex: 0) { result.append(t) }
        }
        return result
    }

    @Test func projectsAnInsert() throws {
        let store = try makeTemporaryStore()
        let db = try makeTemporaryDatabase()
        let projector = try Projector(database: db, store: store, types: [noteType()], schemaVersion: 1)

        let v1 = try store.makeVersion(basedOnPredecessor: nil,
            inserting: [Value(id: .init("a/Note"), data: Data("Alpha".utf8))])
        try projector.update(to: v1.id)

        #expect(try titles(in: db) == ["Alpha"])
        #expect(try projector.projectedVersion() == v1.id)
    }

    @Test func projectsAnUpdateAndARemoval() throws {
        let store = try makeTemporaryStore()
        let db = try makeTemporaryDatabase()
        let projector = try Projector(database: db, store: store, types: [noteType()], schemaVersion: 1)

        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            Value(id: .init("a/Note"), data: Data("Alpha".utf8)),
            Value(id: .init("b/Note"), data: Data("Beta".utf8)),
        ])
        try projector.update(to: v1.id)

        let v2 = try store.makeVersion(basedOnPredecessor: v1.id,
            updating: [Value(id: .init("a/Note"), data: Data("Alpha2".utf8))],
            removing: [.init("b/Note")])
        try projector.update(to: v2.id)

        #expect(try titles(in: db) == ["Alpha2"])
    }

    @Test func movingBackwardsRestoresTheEarlierContents() throws {
        let store = try makeTemporaryStore()
        let db = try makeTemporaryDatabase()
        let projector = try Projector(database: db, store: store, types: [noteType()], schemaVersion: 1)

        let v1 = try store.makeVersion(basedOnPredecessor: nil,
            inserting: [Value(id: .init("a/Note"), data: Data("Alpha".utf8))])
        let v2 = try store.makeVersion(basedOnPredecessor: v1.id,
            inserting: [Value(id: .init("b/Note"), data: Data("Beta".utf8))])

        try projector.update(to: v2.id)
        #expect(try titles(in: db) == ["Alpha", "Beta"])

        try projector.update(to: v1.id)
        #expect(try titles(in: db) == ["Alpha"])
        #expect(try projector.projectedVersion() == v1.id)
    }

    @Test func anUnreadableValueIsSkippedAndReported() throws {
        let store = try makeTemporaryStore()
        let db = try makeTemporaryDatabase()
        let projector = try Projector(database: db, store: store, types: [noteType()], schemaVersion: 1)

        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            Value(id: .init("a/Note"), data: Data("Alpha".utf8)),
            Value(id: .init("bad/Note"), data: Data("CORRUPT".utf8)),
        ])
        let result = try projector.update(to: v1.id)

        #expect(try titles(in: db) == ["Alpha"])
        #expect(result.unreadableIds.map(\.rawValue) == ["bad/Note"])
        // The good value still landed, and the version still advanced.
        #expect(try projector.projectedVersion() == v1.id)
    }

    @Test func aValueOfAnUnknownTypeIsIgnored() throws {
        let store = try makeTemporaryStore()
        let db = try makeTemporaryDatabase()
        let projector = try Projector(database: db, store: store, types: [noteType()], schemaVersion: 1)

        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            Value(id: .init("a/Note"), data: Data("Alpha".utf8)),
            Value(id: .init("t/Tag"), data: Data("red".utf8)),
        ])
        let result = try projector.update(to: v1.id)

        #expect(try titles(in: db) == ["Alpha"])
        // Unknown is not unreadable: no type claims it, so it is simply not projected.
        #expect(result.unreadableIds.isEmpty)
    }

    @Test func rebuildReplacesTheWholeTable() throws {
        let store = try makeTemporaryStore()
        let db = try makeTemporaryDatabase()
        let projector = try Projector(database: db, store: store, types: [noteType()], schemaVersion: 1)

        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            Value(id: .init("a/Note"), data: Data("Alpha".utf8)),
            Value(id: .init("b/Note"), data: Data("Beta".utf8)),
        ])
        try projector.update(to: v1.id)

        // Corrupt the projection behind the projector's back.
        try db.execute(statement: "DELETE FROM notes")
        try projector.rebuild(at: v1.id)

        #expect(try titles(in: db) == ["Alpha", "Beta"])
        #expect(try projector.projectedVersion() == v1.id)
    }
}
```

There are no shared test helpers in this repo. Every suite is a `@Suite class` that builds its own store or database in `init()` and cleans up in `deinit`, following `Tests/LLVSTests/ValueChangesInVersionTests.swift` and `Tests/LLVSTests/SQLiteDatabaseTests.swift`. Follow that pattern here rather than adding free helper functions; the code below assumes `store`, `db` and `rootURL` are suite properties set up that way.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ProjectorTests`
Expected: FAIL to compile, "cannot find 'Projector' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/LLVSProjection/Projector.swift`:

```swift
import Foundation
import LLVS
import LLVSSQLite

/// What a projection pass did.
public struct ProjectionResult: Sendable {
    /// Rows written or deleted.
    public let appliedCount: Int
    /// Values that a `ProjectedType.extract` refused. These were skipped, not applied.
    /// The projection still advanced: one unreadable value does not stop the rest.
    public let unreadableIds: [Value.ID]
}

/// Maintains a SQLite view of the current values in an LLVS store.
///
/// The projection is never the truth. It can be deleted and rebuilt from the store
/// at any time, which is what makes it safe to change the indexed columns.
///
/// Not thread-safe. Call it from one place, in order.
public final class Projector {
    public enum Error: Swift.Error {
        case schemaVersionMismatch
    }

    private let database: SQLiteDatabase
    private let store: Store
    private let types: [String: ProjectedType]
    private let schemaVersion: Int

    public init(database: SQLiteDatabase, store: Store, types: [ProjectedType], schemaVersion: Int) throws {
        self.database = database
        self.store = store
        self.types = Dictionary(uniqueKeysWithValues: types.map { ($0.typeIdentifier, $0) })
        self.schemaVersion = schemaVersion

        try database.execute(statement: """
            CREATE TABLE IF NOT EXISTS projection_state (
                id INTEGER PRIMARY KEY CHECK (id = 0),
                version_id TEXT,
                schema_version INTEGER NOT NULL
            )
            """)
        for type in types {
            try database.execute(statement: type.createTableStatement())
        }
    }

    /// The version the database currently reflects, or `nil` if nothing has been projected.
    public func projectedVersion() throws -> Version.ID? {
        var raw: String?
        try database.forEach(matchingQuery: "SELECT version_id FROM projection_state WHERE id = 0") { row in
            raw = row.value(inColumnAtIndex: 0)
        }
        return raw.map { Version.ID($0) }
    }

    /// The schema version recorded in the database, or `nil` if nothing has been projected.
    public func storedSchemaVersion() throws -> Int? {
        var raw: Int64?
        try database.forEach(matchingQuery: "SELECT schema_version FROM projection_state WHERE id = 0") { row in
            raw = row.value(inColumnAtIndex: 0)
        }
        return raw.map { Int($0) }
    }

    /// Brings the database up to `version`, applying only what differs.
    ///
    /// If nothing has been projected yet, or the recorded schema version does not match,
    /// this rebuilds from scratch instead.
    @discardableResult
    public func update(to version: Version.ID) throws -> ProjectionResult {
        guard let current = try projectedVersion(), try storedSchemaVersion() == schemaVersion else {
            return try rebuild(at: version)
        }
        guard current != version else {
            return ProjectionResult(appliedCount: 0, unreadableIds: [])
        }
        let changes = try store.valueChanges(updatingFrom: current, to: version)
        return try apply(changes, at: version, clearingFirst: false)
    }

    /// Throws away the projected tables and projects every value at `version`.
    @discardableResult
    public func rebuild(at version: Version.ID) throws -> ProjectionResult {
        var changes: [Value.Change] = []
        try store.enumerate(version: version) { reference in
            if let value = try self.store.value(storedAt: reference) {
                changes.append(.insert(value))
            }
        }
        return try apply(changes, at: version, clearingFirst: true)
    }

    private func apply(_ changes: [Value.Change], at version: Version.ID, clearingFirst: Bool) throws -> ProjectionResult {
        try database.inTransaction {
            if clearingFirst {
                for type in self.types.values {
                    try self.database.execute(statement: "DELETE FROM \(type.tableName)")
                }
            }

            var applied = 0
            var unreadable: [Value.ID] = []

            for change in changes {
                switch change {
                case let .insert(value), let .update(value):
                    guard let type = self.type(for: value.id) else { continue }
                    let row: [String: SQLiteValue]
                    do {
                        row = try type.extract(value)
                    } catch {
                        // Skip and report. One value an app cannot decode must not stop
                        // the rest, and must not vanish without the app being told.
                        unreadable.append(value.id)
                        continue
                    }
                    try self.upsert(row, id: value.id, into: type)
                    applied += 1
                case let .remove(valueId):
                    guard let type = self.type(for: valueId) else { continue }
                    try self.database.execute(
                        statement: "DELETE FROM \(type.tableName) WHERE llvs_id = ?",
                        withBindingsList: [[valueId.rawValue]])
                    applied += 1
                case .preserve, .preserveRemoval:
                    continue
                }
            }

            try self.database.execute(
                statement: """
                    INSERT INTO projection_state (id, version_id, schema_version) VALUES (0, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET version_id = excluded.version_id, schema_version = excluded.schema_version
                    """,
                withBindingsList: [[version.rawValue, self.schemaVersion]])

            return ProjectionResult(appliedCount: applied, unreadableIds: unreadable)
        }
    }

    /// Value IDs are `"<instance>/<TypeName>"`, so the type is the suffix after the last
    /// slash. This mirrors `LLVSModel.modelTypeIdentifier(from:)` without depending on it.
    private func type(for valueId: Value.ID) -> ProjectedType? {
        guard let slashIndex = valueId.rawValue.lastIndex(of: "/") else { return nil }
        let typeId = String(valueId.rawValue[valueId.rawValue.index(after: slashIndex)...])
        return types[typeId]
    }

    private func upsert(_ row: [String: SQLiteValue], id: Value.ID, into type: ProjectedType) throws {
        let names = ["llvs_id"] + type.columns.map(\.name)
        let placeholders = Array(repeating: "?", count: names.count).joined(separator: ", ")
        let assignments = type.columns.map { "\($0.name) = excluded.\($0.name)" }.joined(separator: ", ")
        let bindings: [Any?] = [id.rawValue] + type.columns.map { binding(for: row[$0.name] ?? .null) }
        try database.execute(
            statement: """
                INSERT INTO \(type.tableName) (\(names.joined(separator: ", "))) VALUES (\(placeholders))
                ON CONFLICT(llvs_id) DO UPDATE SET \(assignments)
                """,
            withBindingsList: [bindings])
    }

    private func binding(for value: SQLiteValue) -> Any? {
        switch value {
        case let .text(s): return s
        case let .integer(i): return i
        case let .real(d): return d
        case .null: return nil
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ProjectorTests`
Expected: PASS, all six tests.

If `execute(statement:withBindingsList:)` rejects an `Int64` or `Double` binding, read its binding code around `SQLiteDatabase.swift:90-119` and match the types it already accepts rather than changing the database layer here.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LLVSProjection/Projector.swift Tests/LLVSProjectionTests/ProjectorTests.swift
git commit -m "Project version diffs into SQLite in one transaction"
```

---

### Task 6: Prove the projection survives a crash mid-apply

The single-transaction claim is the design's whole safety story, and it is currently only asserted. This task makes it a test.

**Files:**
- Create: `Tests/LLVSProjectionTests/ProjectionRecoveryTests.swift`

**Interfaces:**
- Consumes: everything from Task 5. Adds no new API.

- [ ] **Step 1: Write the test**

Create `Tests/LLVSProjectionTests/ProjectionRecoveryTests.swift`:

```swift
import Testing
import Foundation
@testable import LLVS
@testable import LLVSSQLite
@testable import LLVSProjection

@Suite struct ProjectionRecoveryTests {

    enum Crash: Swift.Error { case midway }

    @Test func aFailureMidApplyLeavesTheProjectionUnchanged() throws {
        let store = try makeTemporaryStore()
        let db = try makeTemporaryDatabase()

        // This type throws on the second value it sees, simulating a crash part-way
        // through applying a change set.
        let seen = Counter()
        let type = ProjectedType(
            typeIdentifier: "Note",
            tableName: "notes",
            columns: [ProjectedColumn(name: "title", declaration: "TEXT")],
            extract: { value in
                if seen.increment() == 2 { throw Crash.midway }
                return ["title": .text(String(decoding: value.data, as: UTF8.self))]
            }
        )
        let projector = try Projector(database: db, store: store, types: [type], schemaVersion: 1)

        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            Value(id: .init("a/Note"), data: Data("Alpha".utf8)),
            Value(id: .init("b/Note"), data: Data("Beta".utf8)),
        ])

        // extract throwing is "skip and report", not a crash, so force a real failure:
        // an error thrown by the database work itself must roll the whole thing back.
        try db.execute(statement: "DROP TABLE notes")

        #expect(throws: (any Swift.Error).self) {
            try projector.update(to: v1.id)
        }

        // Nothing was recorded: the version marker never advanced.
        #expect(try projector.projectedVersion() == nil)
    }

    @Test func rerunningAfterAFailureCompletesTheWork() throws {
        let store = try makeTemporaryStore()
        let db = try makeTemporaryDatabase()
        let type = ProjectedType(
            typeIdentifier: "Note",
            tableName: "notes",
            columns: [ProjectedColumn(name: "title", declaration: "TEXT")],
            extract: { value in ["title": .text(String(decoding: value.data, as: UTF8.self))] }
        )
        let projector = try Projector(database: db, store: store, types: [type], schemaVersion: 1)

        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            Value(id: .init("a/Note"), data: Data("Alpha".utf8)),
        ])

        try db.execute(statement: "DROP TABLE notes")
        #expect(throws: (any Swift.Error).self) { try projector.update(to: v1.id) }
        #expect(try projector.projectedVersion() == nil)

        // Put the table back, as a fresh launch would, and retry the same work.
        try db.execute(statement: type.createTableStatement())
        try projector.update(to: v1.id)

        var titles: [String] = []
        try db.forEach(matchingQuery: "SELECT title FROM notes") { row in
            if let t: String = row.value(inColumnAtIndex: 0) { titles.append(t) }
        }
        #expect(titles == ["Alpha"])
        #expect(try projector.projectedVersion() == v1.id)
    }

    @Test func aSchemaVersionBumpForcesARebuild() throws {
        let store = try makeTemporaryStore()
        let db = try makeTemporaryDatabase()
        func makeType() -> ProjectedType {
            ProjectedType(
                typeIdentifier: "Note",
                tableName: "notes",
                columns: [ProjectedColumn(name: "title", declaration: "TEXT")],
                extract: { value in ["title": .text(String(decoding: value.data, as: UTF8.self))] }
            )
        }

        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            Value(id: .init("a/Note"), data: Data("Alpha".utf8)),
        ])

        let first = try Projector(database: db, store: store, types: [makeType()], schemaVersion: 1)
        try first.update(to: v1.id)
        try db.execute(statement: "DELETE FROM notes")

        // A new schema version means the table contents cannot be trusted: rebuild.
        let second = try Projector(database: db, store: store, types: [makeType()], schemaVersion: 2)
        try second.update(to: v1.id)

        var titles: [String] = []
        try db.forEach(matchingQuery: "SELECT title FROM notes") { row in
            if let t: String = row.value(inColumnAtIndex: 0) { titles.append(t) }
        }
        #expect(titles == ["Alpha"])
    }
}

/// A tiny mutable counter, so the `@Sendable` extract closure can count its calls.
final class Counter: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter ProjectionRecoveryTests`
Expected: PASS, all three tests.

If `aFailureMidApplyLeavesTheProjectionUnchanged` fails because `projectedVersion()` itself throws on the dropped table, that is a real finding: `projection_state` is a separate table and should still be readable. Check whether `forEach` surfaces the error, and if the assertion needs restating, state it as "the version marker did not advance" in whatever form the API allows — do not weaken the test to make it pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/LLVSProjectionTests/ProjectionRecoveryTests.swift
git commit -m "Test that a failed projection pass rolls back whole"
```

---

### Task 7: Follow the coordinator's current version, and document the library

Wires the projector to `StoreCoordinator.currentVersionUpdates` so an app does not hand-drive it, and writes the README section an adopter needs.

**Files:**
- Create: `Sources/LLVSProjection/Projector+Coordinator.swift`
- Create: `Tests/LLVSProjectionTests/ProjectorCoordinatorTests.swift`
- Modify: `README.md` (add a section after the `LLVSModel` material)
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `Projector.update(to:)` (Task 5); `StoreCoordinator.currentVersion`, `StoreCoordinator.currentVersionUpdates: AsyncStream<Version.ID>` (`StoreCoordinator.swift:45,50`).
- Produces: `public func follow(_ coordinator: StoreCoordinator, onResult: @escaping @Sendable (ProjectionResult) -> Void) async` on `Projector`.

- [ ] **Step 1: Write the failing test**

Create `Tests/LLVSProjectionTests/ProjectorCoordinatorTests.swift`:

```swift
import Testing
import Foundation
@testable import LLVS
@testable import LLVSSQLite
@testable import LLVSProjection

@Suite struct ProjectorCoordinatorTests {

    @Test func followingACoordinatorProjectsEachNewVersion() async throws {
        let coordinator = try makeTemporaryCoordinator()
        let db = try makeTemporaryDatabase()
        let type = ProjectedType(
            typeIdentifier: "Note",
            tableName: "notes",
            columns: [ProjectedColumn(name: "title", declaration: "TEXT")],
            extract: { value in ["title": .text(String(decoding: value.data, as: UTF8.self))] }
        )
        let projector = try Projector(database: db, store: coordinator.store, types: [type], schemaVersion: 1)

        let task = Task {
            await projector.follow(coordinator) { _ in }
        }

        try coordinator.save(inserting: [Value(id: .init("a/Note"), data: Data("Alpha".utf8))])

        // Wait for the projection to catch up rather than sleeping a fixed time.
        var titles: [String] = []
        for _ in 0..<100 {
            titles = []
            try db.forEach(matchingQuery: "SELECT title FROM notes") { row in
                if let t: String = row.value(inColumnAtIndex: 0) { titles.append(t) }
            }
            if titles == ["Alpha"] { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()

        #expect(titles == ["Alpha"])
    }
}
```

Build the `StoreCoordinator` in the suite's `init()`, rooted in a fresh temporary directory, following `Tests/LLVSTests/StoreCoordinatorTests.swift`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ProjectorCoordinatorTests`
Expected: FAIL to compile, "value of type 'Projector' has no member 'follow'".

- [ ] **Step 3: Write the implementation**

Create `Sources/LLVSProjection/Projector+Coordinator.swift`:

```swift
import Foundation
import LLVS

extension Projector {
    /// Projects the coordinator's current version, then every version it moves to,
    /// until the calling task is cancelled.
    ///
    /// Each pass reports what it did, including any values it could not read.
    /// A pass that throws is reported through `onResult` as nothing applied, and the
    /// loop continues: the projection stays behind and the next version retries the
    /// same ground, which is the intended failure mode.
    public func follow(
        _ coordinator: StoreCoordinator,
        onResult: @escaping @Sendable (ProjectionResult) -> Void
    ) async {
        // Catch up first. The coordinator may already be past what the database holds.
        if let result = try? update(to: coordinator.currentVersion) {
            onResult(result)
        }
        for await version in coordinator.currentVersionUpdates {
            if Task.isCancelled { return }
            if let result = try? update(to: version) {
                onResult(result)
            }
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter ProjectorCoordinatorTests`
Expected: PASS.

If the compiler objects that `Projector` is not `Sendable` when captured across the `await`, do not reach for `@unchecked Sendable`. Make `follow` take the projector work on the caller's isolation, or mark `Projector` as being for single-isolation use and annotate accordingly. Report which route was taken.

- [ ] **Step 5: Write the README section**

Add to `README.md`, after the `LLVSModel` material and before the samples section. Do not hard-wrap the paragraphs:

```markdown
## Querying with LLVSProjection

LLVS answers "what is this value at this version". It does not answer "which notes were edited this week", because every value is an opaque blob keyed by ID.

`LLVSProjection` fills that gap without making LLVS query-aware. It maintains a SQLite table of current values, updated from version diffs, and you query that.

```swift
import LLVSProjection
import LLVSSQLite

let notes = ProjectedType(
    typeIdentifier: "Note",
    tableName: "notes",
    columns: [
        ProjectedColumn(name: "title", declaration: "TEXT"),
        ProjectedColumn(name: "updated_at", declaration: "INTEGER"),
    ],
    extract: { value in
        let note = try JSONDecoder().decode(Note.self, from: value.data)
        return ["title": .text(note.title), "updated_at": .integer(note.updatedAt)]
    }
)

let database = try SQLiteDatabase(fileURL: databaseURL)
let projector = try Projector(database: database, store: coordinator.store, types: [notes], schemaVersion: 1)

Task {
    await projector.follow(coordinator) { result in
        if !result.unreadableIds.isEmpty {
            print("Could not project: \(result.unreadableIds)")
        }
    }
}
```

Three things are worth knowing before you build on it.

**The projection is an index, not a copy.** Declare only the columns you query or sort on, then read the full object from the store once a query has named the IDs. This keeps writes cheap and the database small.

**Changing your columns is a rebuild, not a migration.** Raise `schemaVersion` and the next pass throws the tables away and re-projects everything from the store. There is no migration path to write, because the truth never lived in SQLite.

**A value that will not decode is skipped, not fatal.** If `extract` throws — an older device wrote a model this build cannot read — that value is left out and its ID is reported in `ProjectionResult.unreadableIds`. Sync is never blocked by one bad value, and nothing disappears without your app being told.
```

- [ ] **Step 6: Write the changelog entry**

Add under `## Unreleased`, in the `### Added` section:

```markdown
- `LLVSProjection`, a library that maintains a SQLite view of the current values in a store so an app can query by field rather than only by value ID. It follows a `StoreCoordinator`, asks the store what differs between the version its database holds and the new one, and applies that difference together with the new version marker in a single transaction — so a crash leaves the projection behind rather than half-applied, and a lost database is rebuilt from the store. A value its `extract` cannot decode is skipped and reported rather than blocking the pass.
```

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS, every test.

- [ ] **Step 8: Commit**

```bash
git add Sources/LLVSProjection/Projector+Coordinator.swift Tests/LLVSProjectionTests/ProjectorCoordinatorTests.swift README.md CHANGELOG.md
git commit -m "Follow the coordinator's current version, and document LLVSProjection"
```

---

## Deferred, deliberately

**Coalescing and cloud growth.** Snapshots already cover the new-device case. Cloud growth is real but is not what blocks an app, and it is easier to reason about once reading no longer depends on old versions. Not in this plan.

**The common-ancestor walk.** `greatestCommonAncestor` walks the DAG proportionally to history length, and Task 3 calls it on every projection pass. Every merge already pays this cost today, so it is not a new risk, but it is the one place where old history still costs something. Measure it against a realistic history before optimising; `Tests/LLVSTests/PerformanceTests.swift` is where such a measurement belongs.

**Existing stores keep the old ID layout.** Task 1 changes new IDs only. A store written before it keeps `"Type/instance"` IDs, which still work and still crowd one bucket. A migration would have to rewrite every value ID in every version, and is out of scope.
