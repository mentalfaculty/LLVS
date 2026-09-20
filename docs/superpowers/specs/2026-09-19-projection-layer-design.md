# LLVS Projection Layer — Design

Date: 2026-09-19
Status: Approved design, not yet implemented.

## Problem

LLVS is a log. A log is good at history and merging, and bad at "show me today's notes". Every value is an opaque blob, and the only key is the value ID, so an app cannot ask a question of the store other than "give me this ID at this version".

Three shortcomings were raised: no querying except by object ID, cloud data too fine-grained, and no coalescing of old data. They are one problem. A log needs to be paired with something that is not a log.

Snapshots, added earlier, are sometimes mistaken for coalescing. They are not. A snapshot lets a new device start without replaying history, but no old version is ever removed from the cloud. Compaction was removed earlier because independent per-device baselines conflict.

## Decision

LLVS stays the truth. A SQLite database becomes the queryable current-values view, maintained by projecting version diffs into it. This is the shape CloudKit uses over FoundationDB, and roughly what Agenda already does.

Rejected alternatives:

- **Coalescing / history truncation first.** Already removed once because it does not work with independent devices. It unblocks nothing in the app, and it is much easier to reason about once a projection exists and old versions are needed only for history and merging, not for reading.
- **Secondary indexes inside the Map.** This rebuilds SQLite, badly, inside a versioned store. SQLite already exists on every device.

Judging criterion for this work: does it unblock a real app at Agenda scale.

## Shape

A new library, `LLVSProjection`, beside `LLVSModel`. Depends on `LLVS`. Knows nothing about the cloud.

One object, the projector. It owns a SQLite database and one extra table, `projection_state`, holding a single row: the version ID the database currently reflects.

The loop:

1. Wake on a change to the current version (`StoreCoordinator.currentVersionUpdates`).
2. Ask `Map.differences(between:and:withCommonAncestor:)` what differs between the stored version and the new one.
3. Apply the resulting rows and write the new version ID into `projection_state`, **in one SQLite transaction**.

The single transaction is the whole safety story. A crash mid-apply rolls back, the stored version ID stays old, and the next launch redoes the same diff. The projection can never be half-updated. It can only be behind, and behind repairs itself.

Two non-goals, stated so they are not eroded later:

- LLVS does not become query-aware. It remains a log of opaque blobs.
- The projection never becomes truth. Deleting the SQLite file loses nothing.

## Going backwards through a DAG

The naive loop assumes the new version descends from the old one. Often it does not: after a sync and merge, the current version jumps to a merge commit whose history includes edits that happened before edits already projected. History is a DAG, not a line.

`Map.differences(between:and:withCommonAncestor:)` is a set difference between two arbitrary versions, not a replay of the steps between them. Given a true common ancestor it answers correctly when the target is sideways from the source, not after it.

**Correction, found while planning.** No public API delivers this today, and the earlier draft of this section was wrong to imply otherwise. `Map` and `Map.Diff` are internal, so a separate library cannot reach them. The one public route, `Store.valueChanges(madeBetween:and:)` (`Store.swift:489`), passes `versionId1` itself as the common ancestor, which is only valid when the first version is an ancestor of the second. Its `switch` calls `fatalError` on the two-branch forks (`.twiceUpdated`, `.removedAndUpdated`, `.twiceInserted`, `.twiceRemoved`), so on two sideways versions it traps rather than answering.

`History.greatestCommonAncestor(ofVersionsIdentifiedBy:)` (`History.swift:97`) is public and reachable through `store.queryHistory`. So the pieces exist; the join does not. Making that join public is a prerequisite task, and it must fold the two-branch forks into insert/update/remove against the target version rather than trapping on them.

So the projector never replays history. It asks one question — what differs between where I am and where I need to be — and applies the answer as an upsert-and-delete set. No undo, no reverse diff, no ordering problem.

Consequences:

- **Merges are free.** A merge commit is just another version to diff against.
- **Rollback is free.** Moving the current version backwards, or onto a branch, runs the same code path.
- **Cost tracks the diff, not the distance.** Diffing across a thousand versions costs what diffing across one costs, if the same ten values changed. This is what makes the design viable at Agenda size.

Open risk, not designed around: `differences` takes a common ancestor, and computing it walks the DAG proportionally to history length. Every merge already pays this today, so it is not new risk, but it is the one place where old history still costs something. Measure before trusting it.

## What lands in the table

LLVS will not look inside a blob, correctly. The app supplies the knowledge: per stored type, a table name and the column values to extract from a decoded model. Everything else — diffing, the transaction, the state row, rebuild — belongs to the framework.

**The projection is an index, not a copy.** Store the ID, the fields actually queried or sorted on, and nothing more. Read the full object from LLVS once a query has named the IDs. This keeps the database small, keeps writes cheap, and makes adding a queryable field a rebuild rather than a migration.

That inverts normal database advice, deliberately. A rebuild is usually frightening; here it is the cheap operation, because truth is intact in LLVS and "drop the table and re-project" is always correct. Designing so rebuild is routine is what buys the freedom to change one's mind about indexes.

**Raw SQLite, via the existing `LLVSSQLite` target — not SwiftData.** SwiftData wants to own the object graph, persistence, and increasingly sync; two owners of truth is a bug factory. It also cannot easily span "apply these rows" and "record this version" in one transaction, which this design depends on. Raw SQLite gives transaction control, no migration ceremony on rebuild, and is boring — the right property beneath a truth store. An app wanting SwiftData in its UI may still have it; reading a plain SQLite is not hard, and the choice stays with the app.

## Rebuild

One entry point: drop the table, read every value at the current version, project it all in one transaction. It runs on three occasions — first launch, a missing or corrupt database, and a schema-version mismatch when the app changes its indexed columns. The app stores a schema version number; a mismatch triggers rebuild. There are no migrations.

## Failure

**Crash mid-apply.** Solved by the transaction. Rolls back, retries next launch.

**Corrupt database.** Solved by rebuild. Nothing is lost, because nothing lived only there.

**A blob that will not decode.** An older device writes a model a newer one cannot read, or the reverse. Three options were considered: skip the row, fail the whole transaction, or project a tombstone. Failing means one bad value freezes sync forever. Skipping silently is quiet data loss in the UI.

**Decision: skip and report.** The projector carries on and hands the app the list of IDs it could not project, so the app can warn rather than lose them silently. This fails soft in both directions: one unreadable value never blocks sync, and nothing disappears without the app being told.

## Map bucketing must be fixed first

`Map.swift:49` buckets by the first two characters of the value ID. LLVSModel IDs look like `"Note/<uuid>"`, so every note lands in bucket `"No"`, and each save rewrites a node listing every note. That is O(N) per write, and fatal at Agenda size. It is audit item 7.

Take the audit's cheaper option: have LLVSModel build IDs as `"<uuid>/Note"`, so the random part is the prefix. No migration, and it fixes the common case.

It is not free, and the cost was missed on first pass. Today's collision is both the pathology and the only cheap way to ask "give me all Notes" by prefix. After the flip, notes scatter across buckets. For the projector this is fine, since it works from diffs rather than scans, and a rebuild reads every value regardless. Recorded so it is not later mistaken for a change with no downside.

## Order of work

1. Fix Map bucketing.
2. Add a public diff between two arbitrary versions, resolving the common ancestor and folding two-branch forks into a flat change set. See the correction under "Going backwards through a DAG".
3. Build `LLVSProjection`, on top of that API.

The decode-failure policy is settled above: skip and report.

Coalescing stays untouched. Snapshots already cover the new-device case; cloud growth is real but is next year's problem, and easier once a projection exists.
