# Changelog

## Unreleased

### Added

- `HTTPClient` in the core library: makes an HTTP request and retries while the problem looks temporary (408, 429, 5xx, and transport failures such as a dropped connection). Waits double from half a second and are capped, and a `Retry-After` header wins over that, within the same cap. A 4xx comes back as a response rather than an error, because what a 404 means differs per service. Callers pass `isSafeToRepeat: false` for a request that would do the work twice if repeated. **Nothing uses it yet**: the WebDAV, Google Drive, OneDrive and pCloud backends still make their own unretried requests. Wiring them up, refresh-on-401 and PKCE are still to come.
- `HTTPClient.Response.requireSuccess(allowing:)`, for the codes a service treats as normal, such as WebDAV's 207, or its 405 for a directory that already exists.

### Changed

- `WebDAVFileSystem`, `GoogleDriveFileSystem` and `OneDriveFileSystem` take an optional `URLSession`, so their networking can be tested. They built their own in a `lazy var` before, which no test could reach, and which is not thread-safe. `WebDAVFileSystem.credential` is now a `let`. Passing both a session and a username and password traps, because a supplied session gets no credential delegate and would otherwise make unauthenticated requests silently.

## 0.11.0 (2026-09-18)

### Changed

- Every target builds in Swift 6 language mode, with strict concurrency checking. The public value types (`Version`, `Value`, `Value.Change`, `ZoneReference`, `SnapshotManifest`, `SnapshotPolicy` and their nested types) are `Sendable`, and so are the `Exchange` and `Zone` protocols. A custom `Exchange` or `Zone` in your own code must now be `Sendable` too. `Cache` gained a `ValueType: Sendable` constraint, and its methods take `some Hashable & Sendable` instead of `AnyHashable`. `SQLiteDatabase.Error.bindingFailed` carries a `valueDescription: String` instead of an `Any?` value, so that the error is `Sendable`.
- `Log.level` can be set from any thread.
- The `@Atomic` property wrapper is renamed to `@Guarded`, because the standard library now has its own `Atomic`.

### Fixed

- `CloudKitExchange` had two real data races that strict concurrency brought to light: records were collected from its query callbacks without a lock, and its cached restoration state was read, changed and written back in separate steps, so concurrent callbacks could lose version IDs. Its `store` property is now a `let`, and its temporary directory is no longer a `lazy var`, which is not thread-safe.
- `BoxExchange` used a `lazy var` for its temporary directory.
- `FileSystemExchange` passed a non-`Sendable` closure to its operation queue.

## 0.10.0 (2026-09-18)

### Source breaking

- `StoreCoordinator.merge()` and `Store.mergeHeads(...)` now `throw`. In 0.9 a merge that failed (an arbiter error, an unresolved conflict, an I/O error) crashed the app through a `try!`. Write `try coordinator.merge()`, or `_ = try? coordinator.merge()` to keep the old call sites short.
- The `LLVSBox` and `LLVSPCloud` products are gated by package traits, so other apps no longer download the Box and pCloud SDKs. Enable them on the dependency: `.package(url: "https://github.com/mentalfaculty/LLVS.git", from: "0.10.0", traits: ["Box"])` (or `"PCloud"`). Without the trait the module is empty.

### Fixed

- The merge base (greatest common ancestor) could be an ancestor of a better merge base, which produced false conflicts and could make a timestamp arbiter discard the newer edit. The choice no longer depends on the argument order, so all devices pick the same base. The search is also linear now. It was quadratic on long histories.
- `StoreCoordinator.merge()` merges one head at a time, in an order that is the same on every device, and keeps the heads that merged when another head fails. `currentVersionUpdates` yields once per merged head, not once per call.
- The in-memory value cache never evicted anything, so memory grew without bound.
- Value files, version files, the coordinator cache and `FileSystemExchange` files are written atomically. A crash or a concurrent reader could see a partial file before.
- `FileZone` reported every read error as "value missing". Only a missing file reads as nil now, so `store.value(...)` can throw where it used to return nil.
- `FileSystemExchange` treated `.DS_Store` and other stray files as version identifiers. A version is listed only when its changes file is present.
- `Exchange.retrieve()` crashed when a remote returned fewer, or more, value changes than requested.
- Branch metadata of an unexpected type crashed the store. See the new `Version.MetadataValue.valueIfDecodable()`.
- `@MergeableModel` on a `public struct` did not compile, and `var a = 0, b = 0` merged only `a`.
- `Optional` properties of `Mergeable` types: a value set on only one branch could be dropped, two inserted values now go through `salvaging(from:)`, and an update beats a removal on either side.
- SQLite: errors while reading rows (busy, corrupt) were read as "no rows", `NULL` was checked on the wrong column, and an empty blob crashed. A 5 second busy timeout is set for stores shared between processes.
- `MultipeerExchange` dropped pushed versions that arrived before their predecessors. `Exchange.send()` also sends predecessors first now.
- `CloudKitExchange` crashed on its first fetch with a shared database, and retried without limit when a fetch kept failing. It now retries once, and only when the change token really expired. Shared databases still do not work, because the zone owner is assumed to be the current user.
- Restoring a snapshot verifies the downloaded chunks against a SHA-256 in the manifest (new; older snapshots are checked by size and version count), and unzips to a staging directory before it moves files into the store, version files last. A damaged download used to leave versions in the store without their values, after which the store could fail to open. Restoring into a store directory that already has files (for example `Coordinator.json`) no longer fails, and files in the archive that are not part of a store are ignored. A SQLite snapshot can only be restored into an empty store directory, so restore before you create the `Store`. Anything else now throws, where it used to fail inside the unzip.
- `LLVSWebDAV` listed a folder as empty, with no error, when the server used a namespace prefix other than `D:`. File names also came back empty from servers that report unknown properties (Nextcloud, ownCloud, Apache), because the request asked for `href` as a property.
- A storage backend that fails to create its zones makes `Store.init` throw. It used to crash at the first read or write. `StoreCoordinator.isExchanging` is safe to read from any thread.

### Added

- `Store.headsToMerge(into:headSelection:)`.
- `Version.MetadataValue.valueIfDecodable()`.
- `SnapshotManifest.sha256`.
