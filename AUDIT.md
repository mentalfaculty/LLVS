# LLVS Audit — 2026-09-18

Read-only audit at commit 92fe81b (tag 0.9). `swift test` passes: 170 tests. Findings come from reading the code. Items marked ✔ were re-checked by hand; the rest are reasoned but not reproduced with a failing test.

## Critical

1. ✅ FIXED (branch `safety-pass`) **Cache never evicts** — `Sources/LLVS/General/Cache.swift:88`. `dropLast()` is non-mutating and its result is discarded, so `generations` grows without bound. Lines 43 and 76 use `repeating: Generation()`, which shares one class instance across all generations. Fix: `removeLast()` (done). The shared `Generation()` instance is benign (it ages out) and is still open.
2. ✅ FIXED (branch `safety-pass`; `mergeHeads` and `StoreCoordinator.merge()` now `throws`) **`try!` in `mergeHeads`** — `Sources/LLVS/Core/Store.swift:316`. Any arbiter or I/O error crashes the app. Reachable through `StoreCoordinator.merge()`. Fix: make it `throws`.
3. ✅ FIXED (branch `safety-pass`; `FileZone.swift:64` `try?` on read still open) **Non-atomic writes** — `Store.swift:519`, `FileZone.swift:57`, `FileSystemExchange.swift:104,108`. `data.write(to:)` without `.atomic`. A crash mid-write leaves a truncated version JSON, after which `Store.init` fails. Another process can read a partial file, and `FileZone` caches it. `FileZone.swift:64` uses `try?`, which turns read errors into "missing".
4. ✅ FIXED (branch `safety-pass`) **Greatest common ancestor is not always the greatest** — `History.swift:111-146`. The search from the second version returns the first common ancestor it reaches, which can be an ancestor of a nearer one. The merge is still valid, but it reports false conflicts, and a timestamp arbiter can then discard a newer edit. Fix: gather all common ancestors and drop any that is an ancestor of another.
5. ✅ PARTLY FIXED (no longer crashes; the zone owner is still hardcoded, so shared databases still do not work) **CloudKit shared database crashes** — `CloudKitExchange.swift:101-105,150`. `createZoneOperation` is nil for non-private scopes but is force-unwrapped. `zoneID` hardcodes `CKCurrentUserDefaultName` (:83), which is wrong for another owner's zone.

## Important — core

6. ✅ FIXED (branch `safety-pass`) **Optional merge loses data** — `Sources/LLVSModel/Mergeable.swift:59-60`. `(_, _, .none)` returns `self`, so (nil, some, nil) drops the value the other branch inserted.
7. **Map bucketing degenerates with LLVSModel IDs** — `Map.swift:49`. IDs like `"Contact/uuid"` all land in node `"Co"`, so each save rewrites a node that lists every Contact. O(N) per write. Two options. (a) Bucket by a hash of the whole ID. This is the real fix, but the bucket name is in the stored file paths, so it needs a store format version, a one-time rebuild on open, and a rule that stops two devices syncing under different schemes. (b) Cheaper: have `LLVSModel` build IDs as `"<uuid>/Contact"` instead of `"Contact/<uuid>"`, so the random part is the prefix. No migration, and it fixes the common case, but not a user who picks their own colliding keys. Not measured; deferred 2026-09-18.
8. ✅ PARTLY FIXED (step errors now throw, NULL checked on the right column, empty blob, 5 s busy timeout; still open: no transactions, WAL or statement reuse, and `SQLiteZone` is not thread-safe while `Store` does not serialise zone access) **SQLite** — `SQLiteDatabase.swift:129` treats BUSY/error as end-of-rows (reads as "missing"); no busy timeout; :190-201 checks NULL on column 0 instead of the requested column; zero-length blob crashes on `bytes!`; no transactions, WAL, or statement reuse.
9. ✅ PARTLY FIXED (zones are made in `Store.init`, which now throws; `isExchanging` is behind a `Mutex`; the configuration properties are documented as setup-only; `save` is still read-then-write) **Unprotected shared state** — `Store.swift:50-58` lazy zones race on first access and use `try!`. `StoreCoordinator.swift:27-34,212`: `exchange`, `mergeArbiter`, `isExchanging` are unsynchronised in an `@unchecked Sendable` class. `save` (:169) is read-then-write.
10. ✅ PARTLY FIXED (`Exchange.swift` done; `Version.swift:25` and `Store.swift:279` still open) **Force unwraps on remote data** — `Exchange.swift:99,124`, `Version.swift:25`, `Store.swift:279`. A backend that returns fewer changes than asked crashes the app.
11. ✅ FIXED **Macro defects** — `MergeableModelMacro.swift:46,85`. Only `bindings.first` is merged (`var a, b` skips `b`). Generated methods have no access modifier, so a `public` struct does not compile.

## Important — exchanges

12. ✅ PARTLY FIXED (retries once only; rate-limit and `retryAfter` handling still open) **CloudKit retry loop** — `CloudKitExchange.swift:162` treats `.partialFailure` as an expired token and retries recursively with no limit or backoff. No handling of `requestRateLimited`, `zoneBusy`, `limitExceeded`, `retryAfter`.
13. ✅ FIXED (versions are added in dependency order; there is still no ack to the sender) **Multipeer push drops versions** — `MultipeerExchange.swift:268` adds versions in arrival order; `send` orders them by `Set`. A version whose predecessor has not arrived throws, the rest of the batch is dropped, and the sender reports success.
14. **Box stuck version** — `BoxExchange.swift:109` always creates a new file. If changes upload and the version upload fails, the retry hits a name conflict forever.
15. **Google Drive duplicate folders** — `GoogleDriveFileSystem.swift:271-296` is check-then-create, and Drive allows duplicate names. Two devices on first sync can split permanently.
16. ✔ FIXED (all five: PKCE with S256 and a constant-time `state` check; single-flight refresh in `OAuthTokenStore`; the `SecItemAdd` status is logged; the session is held by a box until its callback fires; form bodies use the RFC 3986 unreserved set) **OAuth** — no PKCE and no `state` parameter; no single-flight token refresh (OneDrive rotates refresh tokens); `SecItemAdd` status ignored; `ASWebAuthenticationSession` is not retained; form bodies use `.urlQueryAllowed`, which leaves `+ & =` unescaped.
17. ✔ FIXED (all four backends route through `HTTPClient`; refresh-on-401 with single-flight in both OAuth backends; pCloud downloads check their status) **No retry/backoff** in WebDAV, Google Drive, OneDrive, pCloud. No 429/`Retry-After` handling, no refresh-and-retry on 401. pCloud downloads ignore HTTP status.
18. ✅ FIXED (branch `safety-pass`) **`FileSystemExchange` lists with `options: []`** (:66), so `.DS_Store` becomes a version ID and `retrieve` throws.

## Important — snapshots

19. ✅ FIXED (chunks live under `snapshots/<snapshotId>/`; upload order is chunks, then manifest, then delete the replaced snapshot; a manifest id that is not path-safe is refused. The hash and size checks arrived with item 20) **Chunk names are not scoped by snapshot ID.** Chunks are overwritten in place and the manifest is written last, so a reader with the old manifest can assemble mixed chunks. No hash or size check.
20. ✅ FIXED (staging directory, then move; size check against the manifest) **Bootstrap unzips straight into the live store root.** A failure midway leaves version files without values, and those versions are never re-fetched.
21. ✅ PARTLY FIXED (manifest is scanned before zipping, so the archive is a superset; still no lock) **The zip is taken from a live store with no lock.** `versionCount` and `latestVersionId` are scanned after zipping and can disagree with the archive.

## Docs, tests, infrastructure

22. ✅ FIXED (README rewritten against the current API) **README code samples do not compile.** L68-72, L227-228, L264-268 use completion handlers; L219-221 omits `usesFileCoordination:`. L100 says macOS 10.15 / iOS 13; L88 says `from: "0.3.0"`; L293-300 says four targets and no dependencies. No mention of LLVSModel or the new backends. L328-332 lists samples that no longer exist.
23. **`docs/` is a 2019 Jekyll blog** that teaches the removed Combine API and links to a deleted sample.
24. 🔶 PARTLY FIXED (Google Drive, OneDrive and WebDAV are now covered through a `URLProtocol` fake server in `LLVSNetworkTests`; CloudKit, Box and pCloud still have none, because each needs its vendor SDK and a live account) **About 3,000 lines of backend code have no tests**: CloudKit, Google Drive, OneDrive, WebDAV (including the pure `WebDAVResponseParser`), Box, pCloud, `FolderBasedExchange`, `Cache`, `ExchangeSerializer`. No `assertMacroExpansion` tests. `StoreCoordinator` has no dedicated tests.
    - Worth doing without a live account: `CloudKitExchange.chunkRecordName` and `legacyChunkRecordName` are `static` and pure, and they encode a wire format. Changing either silently makes every chunk in every existing store unreachable or un-deletable, and nothing would fail. They need a test target for `LLVSCloudKit`, which does not exist yet.
25. ✅ ADDED `.github/workflows/ci.yml` (not yet seen to run on GitHub) **No CI.** No `.github/`.
26. ✅ FIXED going forward (0.10.0 is three-part; the old tags are left as they are) **Tags 0.7, 0.8, 0.9 are two-part.** SPM `from:` needs three-part semver. Duplicate old tags exist (0.1 and 0.1.0, etc.).
27. ✅ FIXED for Box and pCloud (branch `safety-pass`, package traits `Box` / `PCloud`; ZIPFoundation in core still open) **Box and pCloud SDKs are in every consumer's dependency graph**, because they are top-level package dependencies. Core LLVS depends on ZIPFoundation for one file.
28. ✅ FIXED (untracked) Root `Package.resolved` is tracked, but `.gitignore:4` ignores `**/Package.resolved`.
29. ✅ FIXED (renamed to `LICENSE`, with an "MIT License" title) `LICENCE.txt` uses the British spelling; GitHub and Swift Package Index licence detection may miss it.
30. ✅ FIXED (every target is in Swift 6 language mode; the named blockers are all resolved) Swift 5 language mode everywhere. Swift 6 blockers: global `log` (non-Sendable, shadows Foundation `log()`), `History` escapes from `queryHistory`, non-Sendable `Store` captured in `@Sendable` closures, `Zone`/`MergeArbiter`/`DynamicTaskBatcher` not Sendable.

## Minor / dead code

- `StoreCoordinator.swift:95` hard-codes `FileStorage`; SQLite cannot be used through the coordinator. `defaultCacheDirectory` is unused.
- `DataCompression.swift:34-45`: an uncompressed payload that starts with `"LLZF"` gets decompressed on read.
- `FileZone.swift:71-74`: IDs that differ only in case collide on case-insensitive APFS.
- Dead: `Map.zoneReferences`, `purgeCache`, `Store.storedVersionIds`, `versionIds` on both zones, `greatestCommonAncestor(ofAll:)`, `Result.voidResult`/`isSuccess`, `MapType.userDefined` (hits `fatalError`), `Exchange.swift:98-102`, `ArrayDiff` (unused inside the package).
- `CONTRIBUTING.md` is only a 2019 CLA. `SQLite3` is exposed as a public product. Stale remote branches: `api-refactor`, `indexes`, `loco-swiftui/*`, `claude/*`, `lowdown`.

## Suggested order

1. **Safety pass** (small, test-first): items 1, 2, 3, 6, 10, 18. One failing test each, then the fix.
2. **GCA fix** (item 4) with a DAG test that reproduces the false conflict.
3. **CI**: a GitHub Actions workflow that runs `swift test` on macOS.
4. **README rewrite** against the current API; delete or archive `docs/`.
5. **Tag `0.10.0`** in three-part semver.
6. **Split heavy backends**: move Box and pCloud to their own packages, or behind package traits, so consumers do not pull the SDKs.
7. **Shared HTTP layer** for WebDAV / Google Drive / OneDrive with retry, backoff, and 401 refresh. Add PKCE.
8. **Snapshot hardening**: snapshot-ID-scoped chunk names, a hash in the manifest, unzip to a temp directory and then move.
9. **Map bucketing by hash** (format change; needs a migration plan).
10. **Swift 6 language mode**, target by target, starting with LLVSModel.

## Follow-ups from the code reviews of `safety-pass`

Done: `StoreCoordinator.merge()` merges head by head in a stable order and keeps the heads that merged; branch metadata of the wrong type no longer traps (`valueIfDecodable()`); twice-inserted optionals use `salvaging(from:)`; `FileZone` rethrows real read errors; each cache generation has its own object; dead `greatestCommonAncestor(ofAll:)` deleted; `Package.resolved` untracked.

Open:
- `README.md:70` and `:266` call `merge()` without `try`. Fix in the README rewrite. Put the source breaks (`merge()` and `mergeHeads` now throw; Box and pCloud need traits) in the release notes.
- `.atomic` costs about 2x on small value writes (measured 0.43 s vs 0.85 s per 5000 writes). Accepted.
- Criss-cross merges have more than one greatest common ancestor. LLVS picks one (the most recent). Like non-recursive git, this can silently pick a side: value R=0, X=0, Y=1; M1 keeps 1, M2 deliberately resolves back to 0; with base X the merge takes 1 with no conflict. A recursive merge base would fix it. Out of scope for now.
- `Version.MetadataValue.value()` and `init(_:)` still use `try!` (documented; public API).
- `@MergeableModel` silently skips tuple patterns (`var (a, b) = (1, 2)`), and `lazy var` gives a confusing compile error. Emit a macro diagnostic for both.
- `SQLiteDatabase.Error.queryFailed` carries the code but not `sqlite3_errmsg`.
- `StoreCoordinator` never calls `store.reloadHistory()` except in `bootstrapFromSnapshot`, so a process does not see versions written by another process (app extension) until the app calls it. Consider calling it at the start of `merge()`.
- `StoreCoordinator.init(snapshotPolicy:)` passes `defaultStoreDirectory` as the cache directory; `defaultCacheDirectory` is unused.
- CI has not run yet. The first run is also the first real Swift 6.1 build (local toolchain is newer).
- Snapshot restore: done are the manifest SHA-256, the staging directory, versions-last moves, store directories only, and an error when an existing file differs in size (eg a SQLite database). Still open: chunk names are not scoped by snapshot ID (item 19), so a download during a replacement now fails cleanly and must be retried; a version file can be zipped without its values when the store is written during the zip.
- Snapshots from 0.9 have no hash. The version-count guard for them depends on the order of entries in the archive. Comparing the staged file count with the archive's entry count would be stronger.
- Zipping a live SQLite database in the middle of a transaction can capture a hot journal or a torn file.
- `Store.init` derives `values/`, `versions/` and `maps/` from the unresolved root URL, while `rootDirectoryURL` is resolved. No failure seen.
- `WebDAVResponseParser` ignores the namespace URI. Turning on `shouldProcessNamespaces` and checking for `DAV:` would be stricter.
- `Store` is `@unchecked Sendable`, and vouches transitively for whatever `Storage` the caller supplies. The protocol now documents that implementations must be thread-safe, but nothing enforces it.

