# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is LLVS?

LLVS (Low-Level Versioned Store) is a decentralized, versioned key-value storage framework — essentially Git for app data. It provides version-controlled data storage with branching, merging, and syncing across devices and processes (main app, extensions, watch apps). The data itself is opaque to the framework; apps store arbitrary `Data` blobs keyed by string identifiers.

## Build & Test Commands

```bash
swift build                                    # Build all targets (Box and pCloud compile to empty modules)
swift build --enable-all-traits                # Also compile the SDK-backed backends (Box, pCloud)
swift test                                     # Run all 208 tests (191 LLVSTests + 17 LLVSModelTests)
swift test --filter LLVSTests.StoreSetupTests  # Run a single suite
swift test --filter storeCreatesDirectories    # Run a single test by name
```

- Tests are **Swift Testing** (`@Suite`/`@Test`/`#expect`), not XCTest. Test names have no `test` prefix.
- Tests are in `Tests/LLVSTests/` and `Tests/LLVSModelTests/`, and depend on `LLVS`, `LLVSSQLite`, `LLVSModel`, and `LLVSWebDAV` (for its XML parser only). The other cloud backend targets have no tests.
- SPM builds ALL targets before tests run. A broken backend target blocks the whole test suite. After a change to `LLVSBox` or `LLVSPCloud`, build with `--enable-all-traits`, or the change is not compiled at all.
- `swift-tools-version: 6.1`, but every target except the macro uses `.swiftLanguageMode(.v5)`. Platforms: macOS 15, iOS 18, watchOS 11 (needed for `Mutex` from `Synchronization`).
- CI is `.github/workflows/ci.yml`: `swift test`, then `swift build --enable-all-traits`. There is no linter. Sample apps (`Samples/LoCo`, `Samples/TheMessage`) are Xcode projects that reference the package locally; they are not part of the SPM package.
- `docs/` is a 2019 Jekyll blog that teaches a removed Combine API. It may be served by GitHub Pages, so it has been left in place. Do not trust it for API. Record user-visible changes in `CHANGELOG.md`.

## Package Structure

- **LLVS** — Core framework. Depends only on ZIPFoundation (used by one file, `SnapshotCapable+ZIP.swift`).
- **LLVSModel** — High-level model layer: `@MergeableModel` macro, `StorableModel` protocol, `MergeableArbiter`, `StoreCoordinator+Model` (`save`, `fetchAllModels`, `removeModel`). Depends on LLVS.
- **LLVSModelMacros** — Macro implementation for `@MergeableModel`. Depends on SwiftSyntax.
- **LLVSSQLite** — SQLite storage backend. Depends on LLVS and the `SQLite3` system library target.
- **LLVSCloudKit** — CloudKit exchange. No third-party dependencies.
- **LLVSWebDAV**, **LLVSGoogleDrive**, **LLVSOneDrive** — `CloudFileSystem` implementations over plain `URLSession`. Google Drive and OneDrive each have an OAuth authenticator (tokens in Keychain).
- **LLVSBox**, **LLVSPCloud** — `FolderBasedExchange` implementations that wrap the vendor SDKs. Gated by package traits `Box` and `PCloud` (SE-0450): the SDK products use `condition: .when(traits:)`, so SPM fetches them only when a consumer enables the trait, and each source file is wrapped in `#if Box` / `#if PCloud`. A consumer must pass `traits: ["Box"]` on the package dependency, or the module is empty. The Box SDK has its own `Version` type; write `LLVS.Version`.

## Architecture

### Core Data Flow

`Store` is the central class. It owns a `History` (in-memory DAG of all versions), a `Map` (index mapping versions to their values), and a `Zone` (pluggable storage backend). All writes go through `Store.makeVersion()`, which atomically records a new version with its value changes. All reads go through `Store.value(id:at:)`, which resolves what value exists for a key at a given version by walking the map. Version metadata is always stored as JSON files, even with the SQLite backend.

`StoreCoordinator` wraps `Store` with convenience: it tracks the "current version" for the app UI (`Mutex<Version.ID>`, published via `currentVersionUpdates: AsyncStream<Version.ID>`), simplifies save/fetch, and orchestrates exchange + merge cycles. It is `@unchecked Sendable`, not `@MainActor`, and always uses `FileStorage`. `exchange()` runs retrieve then send through `ExchangeSerializer` (an `AsyncStream` FIFO), then uploads a snapshot in a detached `Task` if the `SnapshotPolicy` says so.

### Version History (DAG)

Versions form a directed acyclic graph. Each `Version` has 0-2 predecessors (0 for initial, 1 for linear, 2 for merge commits) and 0+ successors. "Heads" are versions with no successors — the branch tips. `History` provides traversal (topological sort via Kahn's algorithm), common ancestor finding, and head tracking. `History` is guarded by a `Mutex` — always use `store.queryHistory { history in ... }`, and never nest `queryHistory` calls (the `Mutex` is not recursive).

### Merging

Three-way merge is the primary merge strategy: find the greatest common ancestor of two heads, diff each head against it, then pass the forks to a `MergeArbiter` to resolve conflicts. The `MergeArbiter` protocol has a single method: `changes(toResolve:in:) throws -> [Value.Change]`. Built-in arbiters: `MostRecentBranchFavoringArbiter` (favors branch with newer timestamp), `MostRecentChangeFavoringArbiter` (favors most recent individual change), and `MergeableArbiter` (delegates to `Mergeable` types for property-wise 3-way merge). Fast-forward is used when one version is an ancestor of the other.

`@MergeableModel` macro generates `Mergeable` conformance for structs, producing per-property merge via overloaded `mergeProperty`/`salvageProperty` free functions. Properties conforming to `Mergeable` get deep recursive merge; plain `Equatable` properties use simple equality checks. `Optional<Wrapped>` where `Wrapped: Mergeable` also supports smart merge. `StorableModel` (`Codable` + `modelTypeIdentifier`) is for top-level stored entities; nested types only need `@MergeableModel`. The macro must skip computed properties in both forms (`.getter` shorthand and explicit `.accessors`).

`Value.Fork` describes per-value conflict states: `.inserted`, `.updated`, `.removed` (non-conflicting, single branch), `.twiceRemoved` (non-conflicting, both branches), `.twiceInserted`, `.twiceUpdated`, `.removedAndUpdated` (conflicting, require arbiter resolution).

### Storage Abstraction

`Storage` protocol creates `Zone` instances. `Zone` is the raw read/write interface (`store(_:for:)` / `data(for:)`). Two implementations, both `SnapshotCapable`:
- `FileZone` — hierarchical files on disk under the store's root directory. Uses 2-char prefix subdirectories for filesystem efficiency. Intended to be multi-process safe.
- `SQLiteZone` — SQLite-backed storage via `LLVSSQLite`. Not thread-safe by design (caller manages concurrency).

Value data is stored under the version that created it, which may differ from the version being read.

### Sync (Exchange)

`Exchange` protocol (all `async throws`; `newVersionsAvailable` is an `AsyncStream<Void>`) sends/receives versions between stores. The default `retrieve`/`send` implementations orchestrate the full flow: list remote version IDs → find missing ones → fetch/push in 5MB batches via `DynamicTaskBatcher`. There is no Combine and there are no completion handlers anywhere.

Three layers:
- `CloudFileSystem` protocol (path-addressed, six operations) + the concrete `CloudFileSystemExchange`, which implements `Exchange` and `SnapshotExchange` over any `CloudFileSystem`. Used by WebDAV, Google Drive, OneDrive. Poll-only: it never yields `newVersionsAvailable`.
- `FolderBasedExchange` protocol (ID-addressed, default list/download/upload). Used by `BoxExchange` and `PCloudExchange`.
- Standalone: `CloudKitExchange` (private, public, or shared databases), `FileSystemExchange` (shared directory; keeps an `OperationQueue` because `NSFilePresenter` requires it), `MemoryExchange` (actor), `MultipeerExchange` (via `PeerTransport`).

Remote layout everywhere except CloudKit: `versions/{id}`, `changes/{id}`, `snapshots/manifest.json` + `chunk-NNN`. Changes are uploaded before the version file.

### Cloud Snapshots

Snapshots bootstrap a new device without replaying all history. They replaced compaction, which was removed because independent baselines conflict in multi-device sync. `SnapshotManifest` and `SnapshotPolicy` are in `Snapshot.swift`. The format is `zip-v1`: the store directory is zipped, split into chunks, and the manifest is written last. The manifest carries a SHA-256 of the archive (nil for snapshots made before 0.10). Restore verifies size and hash, unzips to a hidden staging directory inside the store, takes only `values/`, `maps/` and `versions/`, and moves `versions/` last, because a version file is what makes a version exist. Do not trust `unzipItem` to report damage: ZIPFoundation stops without an error at an entry it cannot read. `SnapshotExchange` is an optional protocol; `FileSystemExchange`, `CloudFileSystemExchange`, and `CloudKitExchange` conform. `StoreCoordinator.bootstrapFromSnapshot()` restores one.

### Map (Value Index)

`Map` is a hierarchical tree that tracks which values exist at each version. Nodes are keyed by the first 2 characters of value identifiers, forming a trie-like structure. Subnodes are shared across versions, so deleting old Map nodes breaks every version that references them. Identifiers with a common prefix (for example the `"TypeName/uuid"` IDs from LLVSModel) all land in one node.

### Key Value Types

- `Value` — has an `ID` (string key) and `Data` payload, plus an optional `Reference` (version + key) for locating stored data.
- `Value.Change` — enum: `.insert`, `.update`, `.remove`, `.preserve`, `.preserveRemoval`. These are what get stored per-version.
- `Version.ID` — wrapper around a UUID string.
- `Branch` — wrapper around a raw string, stored in version metadata.

## Gotchas

- On macOS, `FileManager.enumerator` returns `/private/var/...` paths but `URL.resolvingSymlinksInPath()` does not add `/private/`. Resolve each enumerated URL before computing relative paths.
- Do not use `withUnsafeBytes` + `load(as:)` on unaligned `Data`; it crashes. Use `copyBytes` into a local.
- Release tags must be three-part semver (`0.10.0`, not `0.10`), or SPM `from:` does not resolve them.
