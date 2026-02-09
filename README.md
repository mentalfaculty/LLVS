[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmentalfaculty%2FLLVS%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/mentalfaculty/LLVS)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmentalfaculty%2FLLVS%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/mentalfaculty/LLVS)

# Low-Level Versioned Store (LLVS)

_Author: Drew McCormack ([@drewmccormack](https://github.com/drewmccormack))_

## Introduction

Ever wish it was as easy to move your app's data around as it is to push and pull your source code with Git? If so, read on.

### Why LLVS?

Application data is more decentralized than ever. A single user may have a multitude of devices -- phones, laptops, watches -- and each device may run several independent processes (main app, sharing extension, widget), each working with its own copy of the data. How do you keep all of this in sync without writing thousands of lines of custom code?

Software developers solved an analogous problem with source control. Advances in SCM led to tools like Git, which successfully handle decentralized collaboration across many machines. LLVS applies the same ideas to app data: it provides a framework for storing and moving data through the decentralized world in which our apps live.

### What is LLVS?

LLVS is a _decentralized, versioned, key-value storage framework_.

It works like a traditional key-value store, where you insert data values for unique keys. But LLVS adds an extra dimension: each time you store a set of values, a new _version_ is created, and every version has an ancestry you can trace back in time. Just as with Git, you can retrieve the values for any version, determine what changed between any two versions, and merge versions together.

LLVS can also _send_ and _receive_ versions with other stores, in the same way you _push_ and _pull_ between Git repositories.

In summary, LLVS is:

- A decentralized, versioned, key-value storage framework
- A Directed Acyclic Graph (DAG) of your app's data history
- A means to sync data sets across devices, processes, and the cloud
- An abstraction layer for tracking the ancestry of a decentralized data set

### What LLVS is _Not_

- An Object-Relational Modeling (ORM) framework
- A database
- A serialization framework
- A web services framework

### Where Does it Fit?

LLVS is an abstraction layer. It manages the history of a data set without knowing what the data represents, how it is stored on disk, or how it moves between devices.

LLVS ships with storage backends (file-based and SQLite) and a cloud sync layer (CloudKit), but you can substitute your own. The data format is entirely up to you -- `Codable` structs, JSON, encrypted blobs, or anything else that reduces to `Data`.


## Installation

### Swift Package Manager

Add LLVS as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mentalfaculty/LLVS.git", from: "0.3.0")
]
```

Then add the libraries you need to your target's dependencies: `LLVS` for the core framework, `LLVSSQLite` for SQLite-backed storage, and `LLVSCloudKit` for CloudKit sync.

### Xcode

In Xcode, choose _File > Add Package Dependencies..._, enter the LLVS repository URL, and select the libraries your target needs.

### Platforms

LLVS supports macOS 10.15+, iOS 13+, and watchOS 6+.


## Quick Start

This section walks through a minimal iOS app that syncs a shared message via CloudKit. The complete code is in the _Samples/TheMessage_ directory.

### Set Up a StoreCoordinator

`StoreCoordinator` is the simplest entry point. It wraps a `Store`, tracks the current version, and orchestrates sync and merging.

```swift
lazy var storeCoordinator: StoreCoordinator = {
    let coordinator = try! StoreCoordinator()
    let container = CKContainer(identifier: "iCloud.com.mycompany.themessage")
    let exchange = CloudKitExchange(
        with: coordinator.store,
        storeIdentifier: "MainStore",
        cloudDatabaseDescription: .publicDatabase(container)
    )
    coordinator.exchange = exchange
    return coordinator
}()
```

### Save Data

```swift
let messageId = Value.ID("MESSAGE")

func post(message: String) {
    let value = Value(id: messageId, data: message.data(using: .utf8)!)
    try! storeCoordinator.save(updating: [value])
    sync()
}
```

LLVS stores `Value` objects, each consisting of an identifier (the key) and a `Data` payload. Your app converts its model types to and from `Data` however you see fit.

### Fetch Data

```swift
func fetchMessage() -> String? {
    guard let value = try? storeCoordinator.value(id: messageId) else { return nil }
    return String(data: value.data, encoding: .utf8)
}
```

### Sync

```swift
func sync() {
    storeCoordinator.exchange { _ in
        self.storeCoordinator.merge()
    }
}
```

Call `exchange` to send and receive versions with the cloud, then `merge` to reconcile any concurrent changes. No networking code required.


## Working with `Store` Directly

`StoreCoordinator` is convenient, but `Store` gives you full access to the version history, including branching, merging, and diffing.

### Creating a Store

```swift
let rootDir = FileManager.default
    .containerURL(forSecurityApplicationGroupIdentifier: "group.com.mycompany.myapp")!
    .appendingPathComponent("MyStore")
let store = try Store(rootDirectoryURL: rootDir)
```

Using an app group container lets multiple processes (main app, extensions) share the same store.

By default, `Store` uses file-based storage. To use SQLite instead:

```swift
let store = try Store(rootDirectoryURL: rootDir, storage: SQLiteStorage())
```

### Inserting Values

```swift
let value = Value(idString: "ABCDEF", data: "Hello".data(using: .utf8)!)
let firstVersion = try store.makeVersion(basedOnPredecessor: nil, inserting: [value])
```

Passing `nil` for the predecessor creates the initial version (analogous to Git's initial commit). The returned `Version` captures the state of the entire store, not just the values being added.

### Updating and Removing Values

Subsequent changes are based on a predecessor version:

```swift
let updated = Value(idString: "ABCDEF", data: "World".data(using: .utf8)!)
let secondVersion = try store.makeVersion(
    basedOnPredecessor: firstVersion.id,
    updating: [updated]
)
```

Inserts, updates, and removes can be combined in a single `makeVersion` call:

```swift
let thirdVersion = try store.makeVersion(
    basedOnPredecessor: secondVersion.id,
    inserting: [newValue],
    updating: [changedValue],
    removing: [obsoleteValueId]
)
```

### Versions are Store-Wide

Versions apply to the store as a whole. Once a value is added, it persists in all subsequent versions until explicitly updated or removed.

### Fetching Data

Retrieving a value requires specifying the version:

```swift
let value = try store.value(idString: "ABCDEF", at: secondVersion.id)!
let text = String(data: value.data, encoding: .utf8)
```

If the value did not exist at the requested version, `nil` is returned.

### Branching

When concurrent changes are made -- for example, edits on two devices between syncs -- the version history diverges into branches. This is normal and expected; the branches are reconciled through merging.

### Predecessors, Successors, and Heads

Each `Version` can have up to two predecessors (one for linear history, two for merge commits) and zero or more successors. A _head_ is a version with no successors -- the tip of a branch.

Most of the time, your app works with a head as its current version and bases new versions off of it. When multiple heads exist, they generally need to be merged.

### Navigating History

Access the version graph through `queryHistory`, which serializes access for thread safety:

```swift
store.queryHistory { history in
    let heads = history.headIdentifiers
    // ...
}
```

Or get the most recent head directly:

```swift
let latest: Version? = store.mostRecentHead
```

### Merging

LLVS supports two merge modes:

- **Three-way merge**: the standard case. LLVS finds the greatest common ancestor of two divergent versions, diffs each against it, and passes the results to a `MergeArbiter` to resolve conflicts.
- **Two-way merge**: used when two versions share no common ancestry (e.g., two independent initial commits).

A basic merge:

```swift
let arbiter = MostRecentChangeFavoringArbiter()
let merged = try store.merge(version: headA, with: headB, resolvingWith: arbiter)
```

If one version is an ancestor of the other, LLVS fast-forwards without creating a new version.

#### Built-in Arbiters

- `MostRecentChangeFavoringArbiter` -- resolves each conflict by keeping whichever individual change is newer.
- `MostRecentBranchFavoringArbiter` -- resolves all conflicts by keeping values from whichever branch has the newer timestamp.

#### Custom Arbiters

For full control, implement the `MergeArbiter` protocol:

```swift
public protocol MergeArbiter {
    func changes(toResolve merge: Merge, in store: Store) throws -> [Value.Change]
}
```

The `Merge` object provides a dictionary of `Value.Fork` entries describing per-value conflict states: `.inserted`, `.updated`, `.removed` (non-conflicting, single branch), `.twiceInserted`, `.twiceUpdated`, `.removedAndUpdated` (conflicting, require resolution). Your arbiter must return changes that resolve all conflicting forks.

### Setting Up an Exchange

An `Exchange` sends and receives versions between stores. LLVS includes two implementations:

**CloudKit** (via the `LLVSCloudKit` library):

```swift
let exchange = CloudKitExchange(
    with: store,
    storeIdentifier: "MyStore",
    cloudDatabaseDescription: .privateDatabaseWithCustomZone(
        CKContainer.default(), zoneIdentifier: "MyZone"
    )
)
```

**File system** (useful for testing and inter-process sync):

```swift
let exchange = FileSystemExchange(
    rootDirectoryURL: sharedDirectoryURL, store: store
)
```

Retrieving and sending are both asynchronous:

```swift
exchange.retrieve { result in /* handle result */ }
exchange.send { result in /* handle result */ }
```

You can attach multiple exchanges to a single store, pushing and pulling data via different routes. You can also implement custom exchanges by conforming to the `Exchange` protocol.


## Architecture

This section describes the internal design for contributors and advanced users.

### Package Structure

LLVS is split into four SPM targets with a layered dependency graph:

| Target | Purpose | Dependencies |
|---|---|---|
| **LLVS** | Core framework: `Store`, `History`, `Map`, `Zone`, `Exchange`, `Value`, `Version` | None |
| **LLVSSQLite** | SQLite storage backend | LLVS, SQLite3 |
| **LLVSCloudKit** | CloudKit sync exchange | LLVS |
| **SQLite3** | System library wrapper | System SQLite |

### Core Data Flow

`Store` is the central class. It owns three key components:

- **History** -- An in-memory Directed Acyclic Graph (DAG) of all versions. Provides topological traversal (Kahn's algorithm), common ancestor finding, and head tracking. Access is serialized via `historyAccessQueue`.
- **Map** -- A hierarchical trie-like index that tracks which values exist at each version. Nodes are keyed by 2-character prefixes of value identifiers. This allows efficient "what values exist at this version?" queries without scanning all values.
- **Zone** -- A pluggable storage backend for reading and writing raw data.

All writes go through `Store.makeVersion()`, which atomically records a new version with its value changes. All reads go through `Store.value(id:at:)`, which resolves the map to find where a value's data is physically stored.

### Storage Abstraction

The `Storage` protocol creates `Zone` instances. `Zone` is the raw read/write interface with two methods: `store(_:for:)` and `data(for:)`.

Two implementations are provided:

- **FileZone** -- Stores data as files on disk, using 2-character prefix subdirectories for filesystem efficiency. Multi-process safe.
- **SQLiteZone** -- Stores data in a SQLite database. Not thread-safe (the caller manages concurrency). Available via the `LLVSSQLite` target.

### Version History

Versions form a DAG. Each `Version` has:

- 0--2 predecessors (0 for the initial version, 1 for linear commits, 2 for merges)
- 0+ successors
- A timestamp, optional metadata, and an identifier (UUID)

_Heads_ are versions with no successors -- the branch tips. `History` is enumerable via a topological iterator that yields versions from newest to oldest.

### Merging

Three-way merging works by finding the greatest common ancestor of two versions, then computing diffs against it. The diffs are expressed as `Value.Fork` entries describing per-value conflict states. A `MergeArbiter` receives these forks and returns `Value.Change` entries that resolve all conflicts.

### Sync (Exchange)

The `Exchange` protocol handles sending and receiving versions between stores. The default implementations orchestrate the full sync flow: discover remote version IDs, find missing ones, then fetch or push in batches (capped at 5 MB via `DynamicTaskBatcher`).

### Map Internals

The Map is a two-level trie. The root node for each version points to subnodes keyed by the first two characters of value identifiers. Each subnode contains `KeyValuePair` entries mapping value IDs to `Value.Reference` (which records the version where the value's data is physically stored).

Subnodes are shared across versions -- if a version doesn't modify any values in a particular bucket, it reuses the parent version's subnode. This makes versioning space-efficient but means care is needed when deleting old data (see Compaction).


## Structuring Your Data

LLVS stores opaque `Data` blobs keyed by string identifiers. How you structure your model is up to you.

Consider the granularity of each `Value`:

| Approach | Merging | Performance | Disk use |
|---|---|---|---|
| **One property per Value** | Best (per-property conflict resolution) | Slow (many small reads) | Many small files |
| **One entity per Value** | Good (per-entity conflict resolution) | Moderate | Moderate |
| **Entire model in one Value** | Poor (must merge everything manually) | Fast (single read) | Large per-version files |

The **one entity per Value** approach is a good default -- it balances merge granularity with performance.


## Compaction (History Compression)

Over time, LLVS stores grow as every version, its map nodes, and its value data persist. For long-lived stores, you can use _compaction_ to collapse old history into a single baseline snapshot, reducing storage overhead while preserving full functionality for recent versions.

### How It Works

Compaction uses a three-phase, crash-safe algorithm:

1. **Prepare** -- A baseline snapshot is created, capturing the full state of the store at a bottleneck point in the version graph. All new data is written; nothing is deleted yet.
2. **Commit** -- A `compaction.json` file is atomically written, activating the baseline. Predecessor pointers of versions just above the boundary are relinked to the baseline.
3. **Cleanup** -- Version JSON files for compressed versions are deleted. Value data that is no longer referenced is also removed. This phase is idempotent and will automatically resume on the next store initialization if interrupted.

### Usage

Compaction is available via `Store` or `StoreCoordinator`:

```swift
// Compact versions older than 7 days, keeping at least 50 recent versions
let baselineId = try store.compact(
    beforeDate: Date(timeIntervalSinceNow: -7*24*3600),
    minRetainedVersions: 50
)
```

Or with `StoreCoordinator`:

```swift
let baselineId = try storeCoordinator.compact()
```

### Compaction Policy

`StoreCoordinator` supports a `CompactionPolicy` that controls when compaction runs:

| Policy | Behavior |
|---|---|
| `.auto` (default) | Compacts automatically on startup when the existing heuristics determine it is worthwhile. |
| `.manual` | Compaction only runs when you explicitly call `compact()`. |
| `.none` | Compaction is disabled on the coordinator entirely. (`Store.compact()` still works directly.) |

```swift
// Auto-compact on startup (default)
let coordinator = try StoreCoordinator()

// Only compact when explicitly requested
let coordinator = try StoreCoordinator(compactionPolicy: .manual)

// Disable compaction through the coordinator
let coordinator = try StoreCoordinator(compactionPolicy: .none)
```

### Boundary Selection

The compaction boundary is always a _bottleneck_ -- a single version through which the entire DAG converges. This ensures no active branch needs a compressed version as a merge ancestor.

- If there are multiple heads, the greatest common ancestor is used.
- For a single head, the algorithm walks backward, skipping at least `minRetainedVersions` versions, until finding a suitable bottleneck older than the cutoff date.

### Compressed Versions

After compaction, compressed versions are tracked in a persistent set. Attempting to read values _at_ a compressed version will throw an error. Exchanges automatically filter out compressed versions, so they are never sent to or retrieved from remote stores.

```swift
if store.isCompressedVersion(someVersionId) { ... }
```

Compaction can be run multiple times. Each subsequent compaction builds on the previous baseline, progressively compressing more history.


## Features

- Full version history with branching and merging
- Three-way merge with pluggable conflict resolution
- Decentralized sync -- push and pull between any number of stores
- Multiple exchange backends (CloudKit, file system, or custom)
- Multiple storage backends (file-based, SQLite, or custom)
- Thread safe -- work from any thread
- Multiprocess safe -- share a store between app and extensions
- Safe in syncing folders (e.g., Dropbox), unlike raw SQLite databases
- No lock-in -- use multiple cloud services simultaneously
- Compact old history to reclaim storage
- Compatible with end-to-end encryption (data is opaque to the framework)
- Diff between any two versions
- Revert to any previous version


## Samples

The _Samples_ directory includes three example projects:

- **TheMessage** -- A minimal app that syncs a single shared message via CloudKit. Good for understanding the basics.
- **LoCo** -- A contact book app using UIKit.
- **LoCo-SwiftUI** -- The same contact book app built with SwiftUI.


## Learning More

There are useful posts at the [LLVS Blog](https://mentalfaculty.github.io/LLVS/).
