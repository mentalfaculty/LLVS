[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmentalfaculty%2FLLVS%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/mentalfaculty/LLVS)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmentalfaculty%2FLLVS%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/mentalfaculty/LLVS)

# Low-Level Versioned Store (LLVS)

_Author: Drew McCormack ([@drewmccormack](https://github.com/drewmccormack))_

Ever wish it was as easy to move your app's data around as it is to push and pull your source code with Git?

LLVS brings the same model to app data. Every save creates a version. Versions branch, merge, and sync between devices, just like commits in a Git repository. Your app gets full version history, conflict resolution, and multi-device sync without writing any networking or diffing code.

### The problem

A user edits a note on their phone during a flight. Meanwhile, a share extension updates the same note on their iPad. Later, their Watch app writes a quick addition. When the phone comes back online, three copies of the data have diverged independently.


LLVS handles this the way Git handles divergent branches: it tracks the full ancestry of every change, finds the common ancestor when versions diverge, and merges them back together through a conflict resolver you control.

### What you get

- **Version history.** Every save is a version. Branch, merge, diff, or read the store as it was at any point in time.
- **Three-way merge.** When versions diverge, LLVS finds their common ancestor and diffs both sides. You provide a `MergeArbiter` to resolve conflicts however you like, or use a built-in one.
- **Sync without networking code.** Push and pull versions via CloudKit, WebDAV, Google Drive, OneDrive, Box, pCloud, a shared directory, a peer-to-peer link, or your own exchange.
- **Typed models, if you want them.** The `LLVSModel` library stores `Codable` structs and merges them property by property with the `@MergeableModel` macro.
- **Multi-process safe.** Share a file-based store between your main app, extensions, and widgets using an app group container.
- **Pluggable storage.** File-based storage by default, SQLite via `LLVSSQLite`, or bring your own backend.
- **Encryption-friendly.** LLVS stores opaque `Data` blobs. Encrypt them however you want; the framework never inspects your data.

Everything asynchronous uses async/await. There are no completion handlers and no Combine.


## Quick Start

This walks through a minimal app that syncs a single shared message via CloudKit. The full code is in _Samples/TheMessage_.

### Set up a StoreCoordinator

`StoreCoordinator` is the simplest entry point. It wraps a `Store`, tracks the current version for your UI, and orchestrates sync and merging.

```swift
import LLVS
import LLVSCloudKit
import CloudKit

let coordinator = try StoreCoordinator()
let container = CKContainer(identifier: "iCloud.com.mycompany.themessage")
coordinator.exchange = CloudKitExchange(
    with: coordinator.store,
    storeIdentifier: "MainStore",
    cloudDatabaseDescription: .publicDatabase(container)
)
```

`StoreCoordinator()` puts the store in Application Support. Use `StoreCoordinator(withStoreDirectoryAt:cacheDirectoryAt:)` if you want to choose the location, for example an app group container.

### Save, fetch, sync

```swift
let messageId = Value.ID("MESSAGE")

func post(message: String) throws {
    let value = Value(id: messageId, data: message.data(using: .utf8)!)
    try coordinator.save(updating: [value])
    sync()
}

func fetchMessage() -> String? {
    guard let value = try? coordinator.value(id: messageId) else { return nil }
    return String(data: value.data, encoding: .utf8)
}

func sync() {
    Task {
        try? await coordinator.exchange()
        _ = try? coordinator.merge()
    }
}
```

`exchange()` sends and receives versions with the cloud. It is a bit like a two-way `git fetch`: it moves data, but does not touch your current version. `merge()` then reconciles any concurrent changes and moves the current version forward. That's the entire sync implementation.

### React to changes

`currentVersionUpdates` is an `AsyncStream<Version.ID>` that yields whenever the current version changes, whether from a local save or a merge.

```swift
Task {
    for await _ in coordinator.currentVersionUpdates {
        self.message = fetchMessage() ?? ""
    }
}
```

This example is deliberately minimal. What happens when data diverges across devices is covered below.


## Installation

LLVS is installed with the Swift Package Manager. It requires Swift tools 6.1, and macOS 15, iOS 18, or watchOS 11.

```swift
dependencies: [
    .package(url: "https://github.com/mentalfaculty/LLVS.git", from: "0.10.0")
]
```

In Xcode, choose _File > Add Package Dependencies..._, enter the repository URL, and select the libraries your target needs.

| Library | What it is |
|---|---|
| `LLVS` | The core: `Store`, `StoreCoordinator`, merging, file storage, and the in-core exchanges |
| `LLVSSQLite` | SQLite storage backend |
| `LLVSModel` | Typed models, the `@MergeableModel` macro, `MergeableArbiter` |
| `LLVSCloudKit` | CloudKit exchange |
| `LLVSWebDAV`, `LLVSGoogleDrive`, `LLVSOneDrive` | Cloud file systems for use with `CloudFileSystemExchange` |
| `LLVSBox`, `LLVSPCloud` | Exchanges that wrap the Box and pCloud SDKs (need a trait, see below) |

The core `LLVS` library depends on [ZIPFoundation](https://github.com/weichsel/ZIPFoundation), which is used for snapshots. `LLVSModel` depends on swift-syntax for its macro.

### Box and pCloud need a package trait

`LLVSBox` and `LLVSPCloud` wrap vendor SDKs, and I don't want those SDKs downloaded into apps that never use them. They are gated behind package traits, so you have to opt in:

```swift
.package(url: "https://github.com/mentalfaculty/LLVS.git", from: "0.10.0", traits: ["Box"])
```

The traits are `Box` and `PCloud`. Without the trait, the module builds but is empty, and the SDK is not fetched.


## Typed Models with LLVSModel

The core framework deals in raw `Data`. If your model is made of `Codable` structs, `LLVSModel` saves you the boilerplate, and gives you a much better merge. This is how the _LoCo_ sample stores its contacts.

```swift
import LLVS
import LLVSModel

@MergeableModel
struct Contact: StorableModel, Equatable, Identifiable, Codable {
    static let modelTypeIdentifier = "Contact"
    var id: UUID = .init()
    var firstName: String = ""
    var lastName: String = ""
    var city: String = ""
    var avatarJPEGData: Data?
}
```

`StorableModel` is `Codable` plus a stable `modelTypeIdentifier`. Each instance is stored as JSON in one value, with the identifier `"Contact/<instanceIdentifier>"`.

`@MergeableModel` generates a `Mergeable` conformance that does a three-way merge of each stored property. If one device changes `firstName` and another changes `city`, both edits survive. Properties that are themselves `Mergeable` (including optionals of `Mergeable` types) are merged recursively; plain `Equatable` properties are compared against the common ancestor. Nested types only need `@MergeableModel`; `StorableModel` is just for the top-level types you save.

To use that merge, register your types with a `MergeableArbiter`:

```swift
let coordinator = try StoreCoordinator()

let arbiter = MergeableArbiter()
arbiter.register(Contact.self)
coordinator.mergeArbiter = arbiter
```

Values of unregistered types fall through to `fallbackArbiter`, which defaults to `MostRecentChangeFavoringArbiter`.

Saving and fetching are typed extensions on `StoreCoordinator`:

```swift
let contact = Contact(firstName: "Ada")
try coordinator.save(contact, instanceIdentifier: contact.id.uuidString)

let one = try coordinator.fetchModel(Contact.self, instanceIdentifier: contact.id.uuidString)
let all = try coordinator.fetchAllModels(Contact.self)

try coordinator.removeModel(Contact.self, instanceIdentifier: contact.id.uuidString)
```


## Concepts

`StoreCoordinator` is convenient for common cases, but `Store` gives you direct access to the version graph: branching, merging, diffing, and time travel.

### Creating a Store

```swift
let rootDir = FileManager.default
    .containerURL(forSecurityApplicationGroupIdentifier: "group.com.mycompany.myapp")!
    .appendingPathComponent("MyStore")
let store = try Store(rootDirectoryURL: rootDir)
```

Using an app group container lets your main app, extensions, and widgets share the same store. Each process keeps its history in memory, so call `try coordinator.store.reloadHistory()` before merging, to pick up versions written by the other processes.

### Versions and values

Every write creates a new version.

```swift
let value = Value(idString: "ABCDEF", data: "Hello".data(using: .utf8)!)
let firstVersion = try store.makeVersion(basedOnPredecessor: nil, inserting: [value])
```

Passing `nil` for the predecessor creates an initial version, like Git's first commit. Subsequent changes build on a predecessor, and inserts, updates, and removes can be combined in a single call:

```swift
let secondVersion = try store.makeVersion(
    basedOnPredecessor: firstVersion.id,
    inserting: [newValue],
    updating: [changedValue],
    removing: [obsoleteValueId]
)
```

Versions are store-wide: once a value is added, it persists in all subsequent versions until explicitly updated or removed. You can retrieve any value at any version.

```swift
let value = try store.value(idString: "ABCDEF", at: secondVersion.id)
```

You can also ask what changed, with `store.valueChanges(madeInVersionIdentifiedBy:)` and `store.valueChanges(madeBetween:and:)`.

Data is stored once, under the version that wrote it. Later versions just refer to it.

### Heads and branches

When concurrent changes happen (edits on two devices between syncs, or writes from both your app and its share extension) the version history naturally diverges. This isn't an error; it's the normal state of decentralized data. The divergence gets reconciled through merging.

Each `Version` can have up to two predecessors (one for linear history, two for a merge) and any number of successors. A _head_ is a version with no successors, the tip of a line of history. When multiple heads exist, they generally need to be merged.

```swift
store.queryHistory { history in
    let heads = history.headIdentifiers
    // ...
}

let latest: Version? = store.mostRecentHead
```

Always go through `queryHistory` to touch the `History`; it serializes access.

Divergence from syncing is anonymous, but you can also make a named `Branch` for background work, such as a long import. Pass it when saving with the coordinator (`save(updating:in:)`), and it is recorded in the version's metadata. Named branches are left alone by `merge()` by default. You bring them in when you are ready, using the `headSelection` argument.

```swift
let importBranch = Branch(rawValue: "import")
try coordinator.save(inserting: importedValues, in: importBranch)
// ...later
try coordinator.merge(headSelection: .allUnbranchedAndSpecificBranches([importBranch]))
```

### Merging and arbiters

When two versions have diverged, LLVS performs a three-way merge: it finds the greatest common ancestor, diffs each side against it, and hands the results to a `MergeArbiter`. The arbiter decides how to resolve every conflict.

```swift
let arbiter = MostRecentChangeFavoringArbiter()
let merged = try store.merge(version: headA, with: headB, resolvingWith: arbiter)
```

If one version is an ancestor of the other, LLVS fast-forwards without creating a new version, just like Git. If the two versions have no common ancestor at all, it falls back to a two-way merge.

`store.mergeHeads(into:resolvingWith:)` merges all the other heads into a version in one call, and `StoreCoordinator.merge()` does the same for the coordinator's current version, using its `mergeArbiter`. Heads are merged in an order that depends only on the versions themselves, so every device does it the same way.

There are three built-in arbiters:

- `MostRecentChangeFavoringArbiter` resolves each conflict individually, keeping whichever change is newer. An update always beats a removal. This is the coordinator's default.
- `MostRecentBranchFavoringArbiter` resolves all conflicts in favor of whichever of the two versions has the newer timestamp.
- `MergeableArbiter` (in `LLVSModel`) merges registered model types property by property, as described above.

### Conflicts and `Value.Fork`

For full control, implement the protocol yourself.

```swift
public protocol MergeArbiter {
    func changes(toResolve merge: Merge, in store: Store) throws -> [Value.Change]
}
```

The `Merge` gives you the two `versions`, the `commonAncestor` (if any), and `forksByValueIdentifier`, a dictionary of `Value.Fork` describing what happened to each value:

- `.inserted`, `.updated`, `.removed` (each carrying the branch, `.first` or `.second`) and `.twiceRemoved` are not conflicts. LLVS handles them for you.
- `.twiceInserted`, `.twiceUpdated`, and `.removedAndUpdated(removedOn:)` are conflicts. `fork.isConflicting` tells you which is which.

Your arbiter must return a `Value.Change` for every conflicting fork. Use `.preserve(reference)` to keep an existing value from one side, `.preserveRemoval(id)` to keep a removal, or `.update(value)` to write something new. This is where you encode your app's domain logic. Here is an arbiter where the longer text wins:

```swift
final class LongestTextArbiter: MergeArbiter {
    func changes(toResolve merge: Merge, in store: Store) throws -> [Value.Change] {
        let v = merge.versions
        var changes: [Value.Change] = []
        for (valueId, fork) in merge.forksByValueIdentifier {
            switch fork {
            case .twiceInserted, .twiceUpdated:
                let first = try store.value(id: valueId, at: v.first.id)!
                let second = try store.value(id: valueId, at: v.second.id)!
                let winner = first.data.count >= second.data.count ? first : second
                changes.append(.preserve(winner.reference!))
            case let .removedAndUpdated(removedOn):
                let updated = removedOn == .first ? v.second : v.first
                let value = try store.value(id: valueId, at: updated.id)!
                changes.append(.preserve(value.reference!))
            case .inserted, .updated, .removed, .twiceRemoved:
                break
            }
        }
        return changes
    }
}
```

### Structuring your data

If you are not using `LLVSModel`, how you map your model onto values is up to you, but the granularity matters:

| Approach | Merging | Performance | Disk use |
|---|---|---|---|
| **One property per Value** | Best (per-property conflict resolution) | Slow (many small reads) | Many small files |
| **One entity per Value** | Good (per-entity conflict resolution) | Moderate | Moderate |
| **Entire model in one Value** | Poor (must merge everything manually) | Fast (single read) | Large per-version files |

**One entity per Value** is a good default, and it is what `LLVSModel` does. With `@MergeableModel` you get per-property merging on top, without paying for per-property storage.


## Storage Backends

The `Storage` protocol creates `Zone` instances, and a `Zone` is just a raw read/write interface for blobs. Two are included:

- **`FileStorage`** (the default) keeps files on disk under the store's root directory, in 2-character prefix subdirectories to keep the file system happy. It is safe to use from multiple processes.
- **`SQLiteStorage`** (in `LLVSSQLite`) keeps the same data in SQLite databases.

```swift
import LLVSSQLite

let store = try Store(rootDirectoryURL: rootDir, storage: SQLiteStorage())
```

`StoreCoordinator` creates its store with file storage. `SQLiteStorage` is not thread-safe, so use a SQLite-backed store from one queue or actor at a time. To write your own backend, conform to `Storage` and `Zone`.


## Exchanges

An `Exchange` sends and receives versions between stores, the equivalent of `git push` and `git pull`. Set one on a coordinator and call `exchange()`, or drive it directly:

```swift
let retrievedIds = try await exchange.retrieve()
let sentIds = try await exchange.send()
```

| Backend | Library | Notes |
|---|---|---|
| `CloudKitExchange` | `LLVSCloudKit` | Private (default or custom zone) or public database. Shared databases do not work yet. Supports snapshots. |
| `CloudFileSystemExchange` | `LLVS` | Works over any `CloudFileSystem`. Supports snapshots. |
| `WebDAVFileSystem` | `LLVSWebDAV` | A `CloudFileSystem`. Base URL plus optional username and password. |
| `GoogleDriveFileSystem` | `LLVSGoogleDrive` | A `CloudFileSystem`. Takes an access token or a `GoogleDriveAuthenticator`. |
| `OneDriveFileSystem` | `LLVSOneDrive` | A `CloudFileSystem`. Takes an access token or a `OneDriveAuthenticator`. |
| `BoxExchange` | `LLVSBox` | Wraps the Box SDK. Needs the `Box` trait. |
| `PCloudExchange` | `LLVSPCloud` | Wraps the pCloud SDK. Needs the `PCloud` trait. |
| `FileSystemExchange` | `LLVS` | A shared directory. Good for tests and syncing between processes. Supports snapshots. |
| `MemoryExchange` | `LLVS` | In memory (an actor). For tests. |
| `MultipeerExchange` | `LLVS` | Peer to peer, over a `PeerTransport` that you supply. |

A few examples:

```swift
// CloudKit, private database
let exchange = CloudKitExchange(
    with: store,
    storeIdentifier: "MyStore",
    cloudDatabaseDescription: .privateDatabaseWithCustomZone(CKContainer.default(), zoneIdentifier: "MyZone")
)

// WebDAV
let webDAV = WebDAVFileSystem(baseURL: serverURL, username: "drew", password: password)
let exchange = CloudFileSystemExchange(cloudFileSystem: webDAV, store: store, basePath: "MyApp")

// A shared directory
let exchange = FileSystemExchange(rootDirectoryURL: sharedDirectoryURL, store: store, usesFileCoordination: false)
```

`CloudFileSystem` is a small protocol (exists, list, upload, download, remove), so supporting another file-based service is not much work. `MultipeerExchange` does not depend on MultipeerConnectivity itself: you implement `PeerTransport.send(_:toPeer:)` to push bytes to the other peer, and call `receiveData(_:)` on the exchange when bytes arrive.

Every exchange has a `newVersionsAvailable` stream (`AsyncStream<Void>`) that you can use to trigger a sync when the backend is able to tell you something changed. For everything else, conform to `Exchange` yourself. You only need to implement the primitive operations; `retrieve()` and `send()` have default implementations that work out what is missing on each side and transfer it in batches.


## Snapshots

When a new device joins, it normally downloads every version from the beginning and rebuilds the store's history. For stores with thousands of versions, this can be slow.

Cloud snapshots solve this by periodically uploading a chunked copy of the entire store. A new device downloads the snapshot, restores it locally, and then uses normal incremental sync to catch up with anything added since. Existing devices are unaffected.

```swift
let coordinator = try StoreCoordinator(
    withStoreDirectoryAt: storeURL,
    cacheDirectoryAt: cacheURL,
    snapshotPolicy: .auto
)
coordinator.exchange = myExchange

// On first launch, try to restore from a snapshot before syncing
try? await coordinator.bootstrapFromSnapshot()
try? await coordinator.exchange()
_ = try? coordinator.merge()
```

`bootstrapFromSnapshot()` checks whether the exchange and storage support snapshots, whether a compatible snapshot exists, and whether the local store is still empty. If so, it downloads and restores the snapshot. If not, it returns without doing anything, and the app falls back to a full sync with no extra code.

With `SnapshotPolicy.auto`, the coordinator uploads a new snapshot after an exchange when enough time has passed (`minimumInterval`, default 7 days) and enough new versions have accumulated (`minimumNewVersions`, default 20). You can build your own `SnapshotPolicy` with different numbers. The default is `.disabled`.

Snapshots need both sides to opt in. The storage must conform to `SnapshotCapable` (`FileStorage` and `SQLiteStorage` do), and the exchange to `SnapshotExchange` (`FileSystemExchange`, `CloudFileSystemExchange`, and `CloudKitExchange` do). If either side doesn't, snapshot operations are silently skipped.


## Samples

The _Samples_ directory has two SwiftUI apps. They are Xcode projects, not part of the package.

- **TheMessage** is a minimal app that syncs a single shared message via the public CloudKit database. Good for understanding the basics.
- **LoCo** is a contact book that uses `LLVSModel`, `@MergeableModel`, and `MergeableArbiter`, and syncs via a private CloudKit zone.


## Upgrading to 0.10

There are two source breaks.

- **`StoreCoordinator.merge()` and `Store.mergeHeads(into:resolvingWith:)` now throw.** A failed merge used to crash the app (it was a `try!` inside). Now you get the error. Add `try`, or `try?` if you just want to try again at the next sync. `StoreCoordinator.merge()` still attempts every head before throwing the first error it met.
- **Box and pCloud need traits.** If you use `LLVSBox` or `LLVSPCloud`, add `traits: ["Box"]` or `traits: ["PCloud"]` to your `.package` entry, otherwise the module will be empty. Traits need swift-tools-version 6.1 in your own manifest.

