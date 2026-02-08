# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is LLVS?

LLVS (Low-Level Versioned Store) is a decentralized, versioned key-value storage framework — essentially Git for app data. It provides version-controlled data storage with branching, merging, and syncing across devices and processes (main app, extensions, watch apps). The data itself is opaque to the framework; apps store arbitrary `Data` blobs keyed by string identifiers.

## Build & Test Commands

```bash
swift build                                    # Build all targets
swift test                                     # Run all 113 tests (LLVSTests target)
swift test --filter LLVSTests.StoreSetupTests  # Run a single test class
swift test --filter testStoreCreatesDirectories # Run a single test method by name
```

Tests are in `Tests/LLVSTests/` and depend on both `LLVS` and `LLVSSQLite`. There is no linter configured. Sample apps (in `Samples/`) are Xcode projects, not part of the SPM package.

## Package Structure

Four SPM targets with a layered dependency graph:

- **LLVS** — Core framework, zero dependencies. All fundamental types and logic.
- **LLVSSQLite** — SQLite storage backend. Depends on LLVS and SQLite3.
- **LLVSCloudKit** — CloudKit sync exchange. Depends on LLVS.
- **SQLite3** — System library wrapper for SQLite.

## Architecture

### Core Data Flow

`Store` is the central class. It owns a `History` (in-memory DAG of all versions), a `Map` (index mapping versions to their values), and a `Zone` (pluggable storage backend). All writes go through `Store.makeVersion()`, which atomically records a new version with its value changes. All reads go through `Store.value(id:at:)`, which resolves what value exists for a key at a given version by walking the map.

`StoreCoordinator` wraps `Store` with convenience: it tracks the "current version" for the app UI, simplifies save/fetch, and orchestrates exchange + merge cycles.

### Version History (DAG)

Versions form a directed acyclic graph. Each `Version` has 0-2 predecessors (0 for initial, 1 for linear, 2 for merge commits) and 0+ successors. "Heads" are versions with no successors — the branch tips. `History` provides traversal (topological sort via Kahn's algorithm), common ancestor finding, and head tracking. Access to `History` is serialized via `historyAccessQueue` — always use `store.queryHistory { history in ... }`.

### Merging

Three-way merge is the primary merge strategy: find the greatest common ancestor of two heads, diff each head against it, then pass the forks to a `MergeArbiter` to resolve conflicts. The `MergeArbiter` protocol has a single method: `changes(toResolve:in:) throws -> [Value.Change]`. Built-in arbiters: `MostRecentBranchFavoringArbiter` (favors branch with newer timestamp) and `MostRecentChangeFavoringArbiter` (favors most recent individual change). Fast-forward is used when one version is an ancestor of the other.

`Value.Fork` describes per-value conflict states: `.inserted`, `.updated`, `.removed` (non-conflicting, single branch), `.twiceInserted`, `.twiceUpdated`, `.removedAndUpdated` (conflicting, require arbiter resolution).

### Storage Abstraction

`Storage` protocol creates `Zone` instances. `Zone` is the raw read/write interface (`store(_:for:)` / `data(for:)`). Two implementations:
- `FileZone` — hierarchical files on disk under the store's root directory. Uses 2-char prefix subdirectories for filesystem efficiency. Multi-process safe.
- `SQLiteZone` — SQLite-backed storage via `LLVSSQLite`. Not thread-safe by design (caller manages concurrency).

### Sync (Exchange)

`Exchange` protocol handles sending/receiving versions between stores. The default `retrieve`/`send` implementations (in protocol extensions on `Exchange.swift`) orchestrate the full sync flow: discover remote version IDs → find missing ones → fetch/push in batches (5MB chunks via `DynamicTaskBatcher`). Implementations:
- `CloudKitExchange` — syncs via CloudKit (private, public, or shared databases).
- `FileSystemExchange` — syncs via a shared filesystem directory (useful for testing).

### Map (Value Index)

`Map` is a hierarchical tree that tracks which values exist at each version. Nodes are keyed by 2-character prefixes of value identifiers, forming a trie-like structure. This allows efficient "what values changed in this version?" queries without scanning all values.

### Key Value Types

- `Value` — has an `ID` (string key) and `Data` payload, plus an optional `Reference` (version + key) for locating stored data.
- `Value.Change` — enum: `.insert`, `.update`, `.remove`, `.preserve`, `.preserveRemoval`. These are what get stored per-version.
- `Version.ID` — wrapper around a UUID string.
- `Branch` — wrapper around a raw string, stored in version metadata.
