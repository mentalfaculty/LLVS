[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmentalfaculty%2FLLVS%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/mentalfaculty/LLVS)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmentalfaculty%2FLLVS%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/mentalfaculty/LLVS)

# Low-Level Versioned Store (LLVS)

_Author: Drew McCormack ([@drewmccormack](https://github.com/drewmccormack))_

Ever wish it was as easy to move your app's data around as it is to push and pull your source code with Git?

LLVS brings the same model to app data. Every save creates a version. Versions branch, merge, and sync between devices -- just like commits in a Git repository. Your app gets full version history, conflict resolution, and multi-device sync without writing any networking or diffing code.

### The problem

A user edits a note on their phone during a flight. Meanwhile, a share extension updates the same note on their iPad. Later, their Watch app writes a quick addition. When the phone comes back online, three copies of the data have diverged independently.

Keeping these in sync is the kind of problem that consumes months of development time. You end up writing custom conflict detection, manual diffing, retry logic, and timestamp heuristics -- and it's still fragile.

LLVS handles this the way Git handles divergent branches: it tracks the full ancestry of every change, finds the common ancestor when versions diverge, and merges them back together through a conflict resolver you control. The framework does the hard part; you just decide what "resolve this conflict" means for your data.

### What you get

- **Version history** -- Every save is a version. Branch, merge, diff, or revert to any point in time.
- **Three-way merge** -- When versions diverge, LLVS finds their common ancestor and diffs both sides. You provide a `MergeArbiter` to resolve conflicts however you like, or use a built-in one.
- **Sync without networking code** -- Push and pull versions between stores via CloudKit, a shared filesystem, or your own custom exchange. Attach multiple exchanges to the same store.
- **Multi-process safe** -- Share a store between your main app, extensions, and widgets using an app group container. LLVS handles concurrent access.
- **Pluggable storage** -- File-based storage by default, SQLite via `LLVSSQLite`, or bring your own backend.
- **Encryption-friendly** -- LLVS stores opaque `Data` blobs. Encrypt them however you want; the framework never inspects your data.


## Quick Start

This walks through a minimal app that syncs a shared message via CloudKit. Full code is in _Samples/TheMessage_.

### Set up a StoreCoordinator

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

### Save, fetch, sync

```swift
let messageId = Value.ID("MESSAGE")

func post(message: String) {
    let value = Value(id: messageId, data: message.data(using: .utf8)!)
    try! storeCoordinator.save(updating: [value])
    sync()
}

func fetchMessage() -> String? {
    guard let value = try? storeCoordinator.value(id: messageId) else { return nil }
    return String(data: value.data, encoding: .utf8)
}

func sync() {
    storeCoordinator.exchange { _ in
        self.storeCoordinator.merge()
    }
}
```

`exchange` sends and receives versions with the cloud. `merge` reconciles any concurrent changes. That's the entire sync implementation.

This example is deliberately minimal -- the real power of LLVS shows up when data diverges across devices, which is covered below.


## Installation

### Swift Package Manager

Add LLVS as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mentalfaculty/LLVS.git", from: "0.3.0")
]
```

Then add the libraries you need: `LLVS` for the core framework, `LLVSSQLite` for SQLite-backed storage, and `LLVSCloudKit` for CloudKit sync.

### Xcode

Choose _File > Add Package Dependencies..._, enter the LLVS repository URL, and select the libraries your target needs.

### Platforms

macOS 10.15+, iOS 13+, watchOS 6+.


## Working with `Store`

`StoreCoordinator` is convenient for common cases, but `Store` gives you direct access to the version graph -- branching, merging, diffing, and time travel.

### Creating a Store

```swift
let rootDir = FileManager.default
    .containerURL(forSecurityApplicationGroupIdentifier: "group.com.mycompany.myapp")!
    .appendingPathComponent("MyStore")
let store = try Store(rootDirectoryURL: rootDir)
```

Using an app group container lets your main app, extensions, and widgets share the same store. For SQLite-backed storage:

```swift
let store = try Store(rootDirectoryURL: rootDir, storage: SQLiteStorage())
```

### Versions and values

Every write creates a new version:

```swift
let value = Value(idString: "ABCDEF", data: "Hello".data(using: .utf8)!)
let firstVersion = try store.makeVersion(basedOnPredecessor: nil, inserting: [value])
```

Passing `nil` for the predecessor creates the initial version -- like Git's first commit. Subsequent changes build on a predecessor:

```swift
let updated = Value(idString: "ABCDEF", data: "World".data(using: .utf8)!)
let secondVersion = try store.makeVersion(
    basedOnPredecessor: firstVersion.id,
    updating: [updated]
)
```

Inserts, updates, and removes can be combined in a single call:

```swift
let thirdVersion = try store.makeVersion(
    basedOnPredecessor: secondVersion.id,
    inserting: [newValue],
    updating: [changedValue],
    removing: [obsoleteValueId]
)
```

Versions are store-wide: once a value is added, it persists in all subsequent versions until explicitly updated or removed. You can retrieve any value at any version:

```swift
let value = try store.value(idString: "ABCDEF", at: secondVersion.id)!
```

### Branching and heads

When concurrent changes happen -- edits on two devices between syncs, or writes from both your app and its share extension -- the version history naturally diverges into branches. This isn't an error; it's the normal state of decentralized data. The branches get reconciled through merging.

Each `Version` can have up to two predecessors (one for linear history, two for merge commits) and any number of successors. A _head_ is a version with no successors -- the tip of a branch. When multiple heads exist, they generally need to be merged.

```swift
store.queryHistory { history in
    let heads = history.headIdentifiers
    // ...
}

// Or get the most recent head directly:
let latest: Version? = store.mostRecentHead
```

### Merging

This is where it gets interesting. When two versions have diverged, LLVS performs a three-way merge: it finds the greatest common ancestor, diffs each branch against it, and hands the results to a `MergeArbiter` that you provide. The arbiter decides how to resolve every conflict.

```swift
let arbiter = MostRecentChangeFavoringArbiter()
let merged = try store.merge(version: headA, with: headB, resolvingWith: arbiter)
```

If one version is an ancestor of the other, LLVS fast-forwards without creating a new version -- just like Git.

LLVS ships with two built-in arbiters:

- `MostRecentChangeFavoringArbiter` -- resolves each conflict individually by keeping whichever change is newer.
- `MostRecentBranchFavoringArbiter` -- resolves all conflicts by favoring whichever branch has the newer timestamp.

For full control, implement the `MergeArbiter` protocol:

```swift
public protocol MergeArbiter {
    func changes(toResolve merge: Merge, in store: Store) throws -> [Value.Change]
}
```

The `Merge` object gives you a dictionary of `Value.Fork` entries describing per-value conflict states: `.inserted`, `.updated`, `.removed` (non-conflicting, single branch), `.twiceInserted`, `.twiceUpdated`, `.removedAndUpdated` (conflicting, both branches changed). Your arbiter returns `Value.Change` entries that resolve all the conflicting forks. This is where you encode your app's domain logic -- maybe the longer text wins, maybe you concatenate both, maybe you prompt the user.

### Sync (Exchange)

An `Exchange` sends and receives versions between stores -- the equivalent of `git push` and `git pull`.

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

You can attach multiple exchanges to a single store, syncing via different routes simultaneously -- CloudKit for cross-device, a shared directory for inter-process. You can also implement custom exchanges by conforming to the `Exchange` protocol.


## Structuring Your Data

LLVS stores opaque `Data` blobs keyed by string identifiers. How you map your model onto values is up to you, but the granularity matters:

| Approach | Merging | Performance | Disk use |
|---|---|---|---|
| **One property per Value** | Best (per-property conflict resolution) | Slow (many small reads) | Many small files |
| **One entity per Value** | Good (per-entity conflict resolution) | Moderate | Moderate |
| **Entire model in one Value** | Poor (must merge everything manually) | Fast (single read) | Large per-version files |

**One entity per Value** is a good default. It gives you per-entity conflict resolution while keeping read performance reasonable. Use `Codable`, JSON, flatbuffers, or whatever serialization you prefer -- LLVS never inspects the bytes.


## Snapshots

When a new device joins your sync group, it normally replays every version from the beginning -- downloading each change and rebuilding the store's history. For stores with thousands of versions, this can be slow.

**Cloud snapshots** solve this by periodically uploading a chunked dump of the entire store. A new device downloads the snapshot, restores it locally, and then uses normal incremental sync to catch up with any versions added since the snapshot. Existing devices are completely unaffected.

### Bootstrapping a new device

```swift
let coordinator = try StoreCoordinator(
    withStoreDirectoryAt: storeURL,
    cacheDirectoryAt: cacheURL,
    snapshotPolicy: .auto
)
coordinator.exchange = myExchange

// On first launch, try to restore from a snapshot before syncing
coordinator.bootstrapFromSnapshot { error in
    coordinator.exchange { _ in
        coordinator.merge()
    }
}
```

`bootstrapFromSnapshot()` checks whether the exchange supports snapshots, whether one exists, and whether the local store is empty. If all conditions are met, it downloads and restores the snapshot. If not, it completes immediately -- the app falls back to a full sync with no extra code.

### Automatic snapshot uploads

With `SnapshotPolicy.auto`, the coordinator uploads a new snapshot after each exchange when enough time has passed (`minimumInterval`, default 7 days) and enough new versions have accumulated (`minimumNewVersions`, default 20). Use `.disabled` (the default) to opt out.

### Custom storage and exchange support

Snapshot support requires both the storage backend and the exchange to opt in:

- **Storage**: Conform to `SnapshotCapable` (both `FileStorage` and `SQLiteStorage` already do).
- **Exchange**: Conform to `SnapshotExchange` (`FileSystemExchange` already does).

If either side doesn't conform, snapshot operations are silently skipped.


## Architecture

This section covers the internal design for contributors and anyone who wants to understand what's happening under the hood.

### Package structure

LLVS is split into four SPM targets:

| Target | Purpose | Dependencies |
|---|---|---|
| **LLVS** | Core framework: `Store`, `History`, `Map`, `Zone`, `Exchange`, `Value`, `Version` | None |
| **LLVSSQLite** | SQLite storage backend | LLVS, SQLite3 |
| **LLVSCloudKit** | CloudKit sync exchange | LLVS |
| **SQLite3** | System library wrapper | System SQLite |

### Core data flow

`Store` is the central class. It owns three components:

- **History** -- An in-memory directed acyclic graph (DAG) of all versions. Provides topological traversal (Kahn's algorithm), common ancestor finding, and head tracking. Access is serialized via `historyAccessQueue`.
- **Map** -- A hierarchical trie-like index that tracks which values exist at each version. Nodes are keyed by 2-character prefixes of value identifiers, making "what values exist at this version?" queries efficient without scanning everything.
- **Zone** -- A pluggable storage backend for reading and writing raw data.

All writes go through `Store.makeVersion()`, which atomically records a new version with its value changes. All reads go through `Store.value(id:at:)`, which walks the map to find where a value's data is physically stored.

### Storage abstraction

The `Storage` protocol creates `Zone` instances. `Zone` is the raw read/write interface with two methods: `store(_:for:)` and `data(for:)`.

- **FileZone** -- Files on disk, using 2-character prefix subdirectories for filesystem efficiency. Multi-process safe.
- **SQLiteZone** -- SQLite-backed. Not thread-safe by design (the caller manages concurrency). Available via `LLVSSQLite`.

### Map internals

The Map is a two-level trie. The root node for each version points to subnodes keyed by the first two characters of value identifiers. Each subnode maps value IDs to `Value.Reference` (which records the version where the data is physically stored).

Subnodes are shared across versions -- if a version doesn't modify any values in a particular bucket, it reuses the parent's subnode. This makes versioning space-efficient.


## Samples

The _Samples_ directory includes three example projects:

- **TheMessage** -- A minimal app that syncs a single shared message via CloudKit. Good for understanding the basics.
- **LoCo** -- A contact book app using UIKit.
- **LoCo-SwiftUI** -- The same contact book app built with SwiftUI.


## Learning More

There are useful posts at the [LLVS Blog](https://mentalfaculty.github.io/LLVS/).
