# Local-First SQLite over LLVS — Design

Date: 2026-09-21
Status: Approved design, not yet implemented.
Follows: `2026-09-19-projection-layer-design.md`, which this supersedes in part.

## Problem

The projection layer built on 2026-09-20 is one-way: LLVS is the truth, SQLite a read-only index over it, and an app that writes to the SQLite has its write destroyed by the next rebuild. Writes still go through `StoreCoordinator.save`.

That is not what an app wants. SQLite should be usable the way any SQLite app uses it — ordinary `INSERT`, `UPDATE`, `DELETE`, ordinary indexes on ordinary columns — and syncing should follow from that rather than being a separate thing the app does.

The framing that settles the design: **SQLite is the working copy at some version; writing to it makes a new version.** LLVS is the object store, SQLite the checkout. Reads see the state at a version. Writes capture themselves and commit.

## Decision

SQLite becomes a second write path into LLVS, not a second truth. LLVS remains the only truth, and merging continues to happen there.

One-way projection remains available for types an app only queries. A type is declared one way or the other:

- **Index table** — a few columns over a value whose real content lives in LLVS. Read-only, as built already.
- **Owned table** — a column per property, the row is the model, writes originate here.

## How a write becomes a version

1. The app runs ordinary SQL.
2. `AFTER INSERT` / `UPDATE` / `DELETE` triggers record what changed into a changelog table — per row, and for updates, per column.
3. A drain step reads the changelog, assembles each affected row into a value, and writes one LLVS version whose predecessor is the version the table was at.
4. Incoming versions apply back into SQLite with a suppression flag set, so applying them records nothing and cannot echo back out.

All four mechanisms were verified against SQLite before this was written:

- A multi-row `UPDATE` fires the trigger **once per row**, so one statement yields per-row changes without the app splitting it.
- `WHERE OLD.col IS NOT NEW.col` means a write that changes nothing records nothing.
- Per-column capture on `UPDATE` works, which is what makes column-level merge possible.
- A `WHEN (SELECT flag FROM applying) = 0` guard reliably suppresses capture while a remote change is being applied.

## Merging

**The merge does not happen in SQLite.** SQLite never sees a conflict.

A row change becomes a value in LLVS, and two devices' versions merge there, through the existing machinery: `Store` finds the common ancestor, and the `MergeArbiter` resolves. This is unchanged from how LLVS merges today.

Column-level merge therefore needs no new merge code. `MergeableArbiter` already merges two values property by property against their ancestor (`MergeableArbiter.swift:33,77`), and **a column is a property**. Two devices editing different columns of one row already merge cleanly, with both edits surviving.

**Same-column collisions go to the `MergeArbiter`**, which is where an app's existing arbiter already makes exactly this decision. No new concept, no new policy language, and an app that has registered its types with a `MergeableArbiter` gets the behaviour it already has.

Escalating below column level — merging two concurrent edits *within* one column — is served by making that property a `Mergeable` type, which `@MergeableModel` already supports recursively. That is the escape hatch rather than new infrastructure.

## A column per property

The table is generated from the model declaration. `@MergeableModel` already walks every stored property and correctly skips `let`, `static` and computed ones (`MergeableModelMacro.swift:40-70`); it currently keeps only the name, and `binding.typeAnnotation` is available and unused. So the type is already in reach.

```swift
@MergeableModel
struct Note: StorableModel {
    static let modelTypeIdentifier = "Note"
    var title: String = ""        // title TEXT
    var body: String = ""         // body TEXT
    var updatedAt: Date = .now    // updated_at INTEGER
    var tags: [String] = []       // tags TEXT, holding JSON
}
```

Mapping:

- `String`, `Int`, `Double`, `Bool`, `Date`, `UUID`, `Data` → a real column, directly indexable with ordinary `CREATE INDEX`.
- `Optional` of any of those → the same column, nullable.
- Everything else — arrays, dictionaries, nested structs → a JSON text column.

The nested case is contained to the property that causes it. `tags` being JSON does not stop `title` being a plain indexed `TEXT`. A JSON column also remains queryable through `json_extract` and `json_each`, and can carry an expression index, so it is a less pleasant column rather than a dead end.

This is the point of the design: the schema is what a developer would have written by hand. Nothing in it announces LLVS except `llvs_id`. Existing SQL works, a database browser shows sensible data, and someone who knows SQLite has nothing to learn.

## What carries over unchanged

From the projection layer, and still true:

- A pass applies its rows and the version marker in **one transaction**, so a failure leaves the table on its previous version rather than half-updated.
- **Rebuild is routine**, because LLVS holds everything. Changing indexed columns is a `schemaVersion` bump, never a migration.
- A value that will not decode is **skipped and reported**, capped, so one unreadable value never blocks a pass.

With one addition: a rebuild must **drain the changelog first**, or local edits not yet committed to LLVS would be thrown away with the table.

## Open questions, deliberately not answered here

**Schema migration of an owned table.** Adding a property changes the table. Rebuild handles it, since LLVS has the data — but an owned table may hold undrained local edits, so the order matters and needs specifying.

**Deletes and tombstones.** A `DELETE` must become a removal in LLVS, and a removal racing an update on another device is `removedAndUpdated`, which the arbiter already handles. Whether the row returns on merge needs a stated rule.

**Transaction boundaries.** One drain currently becomes one version. Whether an app's explicit `BEGIN`/`COMMIT` should map to one version instead is worth deciding before apps depend on the default.

## Order of work

1. Generate the table and triggers from `@MergeableModel`, with the scalar and JSON mapping.
2. Drain the changelog into LLVS versions, with suppression on the way back.
3. Owned tables end to end, against the existing projector.
4. Settle the three open questions above with tests.
