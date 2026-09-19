//
//  FileSystemExchange.swift
//  LLVS
//
//  Created by Drew McCormack on 25/02/2019.
//

import Foundation

public final class FileSystemExchange: NSObject, Exchange, NSFilePresenter, SnapshotExchange, @unchecked Sendable {

    public enum Error: Swift.Error {
        case versionFileInvalid
        case changesFileInvalid
        case snapshotChunkMissing(Int)
        /// A manifest carried an id that could not be used as a path component.
        case snapshotIdNotPathSafe(String)
    }

    public let store: Store

    private let minimumDelayBeforeNotifyingOfNewVersions = 1.0

    public let newVersionsAvailable: AsyncStream<Void>
    private let newVersionsContinuation: AsyncStream<Void>.Continuation

    public let rootDirectoryURL: URL
    public var versionsDirectory: URL { return rootDirectoryURL.appendingPathComponent("versions") }
    public var changesDirectory: URL { return rootDirectoryURL.appendingPathComponent("changes") }
    public var snapshotsDirectory: URL { return rootDirectoryURL.appendingPathComponent("snapshots") }

    /// Each snapshot's chunks live under its own id, so a new snapshot never overwrites the one
    /// a reader is still fetching.
    func snapshotDirectory(snapshotId: String) -> URL {
        snapshotsDirectory.appendingPathComponent(snapshotId)
    }

    func chunkURL(snapshotId: String, index: Int) -> URL {
        snapshotDirectory(snapshotId: snapshotId).appendingPathComponent(String(format: "chunk-%03d", index))
    }

    public let usesFileCoordination: Bool

    public var restorationState: Data? {
        get { return nil }
        set {}
    }

    fileprivate let fileManager = FileManager()
    fileprivate let queue = OperationQueue()

    public init(rootDirectoryURL: URL, store: Store, usesFileCoordination: Bool) {
        self.rootDirectoryURL = rootDirectoryURL
        self.store = store
        self.usesFileCoordination = usesFileCoordination
        (self.newVersionsAvailable, self.newVersionsContinuation) = AsyncStream<Void>.makeStream()
        super.init()
        try? fileManager.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: versionsDirectory, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: changesDirectory, withIntermediateDirectories: true, attributes: nil)
        if self.usesFileCoordination {
            NSFileCoordinator.addFilePresenter(self)
        }
    }

    deinit {
        if self.usesFileCoordination {
            NSFileCoordinator.removeFilePresenter(self)
        }
        newVersionsContinuation.finish()
    }

    public func prepareToRetrieve() async throws {
    }

    public func retrieveAllVersionIdentifiers() async throws -> [Version.ID] {
        try await coordinateFileAccess(.read) {
            // A version is only complete when its changes file is also present. Changes are written first.
            // This also excludes strays, such as temporary files orphaned by an interrupted atomic write.
            let versionNames = try self.fileManager.contentsOfDirectory(at: self.versionsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).map { $0.lastPathComponent }
            let changesNames = Set(try self.fileManager.contentsOfDirectory(at: self.changesDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).map { $0.lastPathComponent })
            return versionNames.filter({ changesNames.contains($0) }).map({ Version.ID($0) })
        }
    }

    public func retrieveVersions(identifiedBy versionIds: [Version.ID]) async throws -> [Version] {
        try await coordinateFileAccess(.read) {
            try versionIds.map { versionId in
                let url = self.versionsDirectory.appendingPathComponent(versionId.rawValue)
                let data = try Data(contentsOf: url)
                if let version = try JSONDecoder().decode([String:Version].self, from: data)["version"] {
                    return version
                } else {
                    throw Error.versionFileInvalid
                }
            }
        }
    }

    public func retrieveValueChanges(forVersionsIdentifiedBy versionIds: [Version.ID]) async throws -> [Version.ID: [Value.Change]] {
        try await coordinateFileAccess(.read) {
            try versionIds.reduce(into: [:]) { result, versionId in
                let url = self.changesDirectory.appendingPathComponent(versionId.rawValue)
                let data = try Data(contentsOf: url)
                let changes = try JSONDecoder().decode([Value.Change].self, from: data)
                result[versionId] = changes
            }
        }
    }

    public func prepareToSend() async throws {
    }

    public func send(versionChanges: [VersionChanges]) async throws {
        try await coordinateFileAccess(.write) {
            for (version, valueChanges) in versionChanges {
                let changesURL = self.changesDirectory.appendingPathComponent(version.id.rawValue)
                let changesData = try JSONEncoder().encode(valueChanges)
                try changesData.write(to: changesURL, options: .atomic)

                let versionURL = self.versionsDirectory.appendingPathComponent(version.id.rawValue)
                let versionData = try JSONEncoder().encode(["version":version])
                try versionData.write(to: versionURL, options: .atomic)
            }
        }
    }

    private enum FileAccess {
        case read, write
    }

    // The block runs on the operation queue, so it and its result must be safe to hand across threads.
    private func coordinateFileAccess<T: Sendable>(_ access: FileAccess, by block: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                if self.usesFileCoordination {
                    let coordinator = NSFileCoordinator(filePresenter: self)
                    var coordError: NSError?

                    let accessor: (URL) -> Void = { _ in
                        do {
                            let result = try block()
                            continuation.resume(returning: result)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }

                    switch access {
                    case .read:
                        coordinator.coordinate(readingItemAt: self.rootDirectoryURL, options: [], error: &coordError, byAccessor: accessor)
                    case .write:
                        coordinator.coordinate(writingItemAt: self.rootDirectoryURL, options: [], error: &coordError, byAccessor: accessor)
                    }

                    if let error = coordError {
                        continuation.resume(throwing: error)
                    }
                } else {
                    do {
                        let result = try block()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK:- Snapshot Exchange

    public func retrieveSnapshotManifest() async throws -> SnapshotManifest? {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                let manifestURL = self.snapshotsDirectory.appendingPathComponent("manifest.json")
                guard self.fileManager.fileExists(atPath: manifestURL.path) else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    let data = try Data(contentsOf: manifestURL)
                    let manifest = try JSONDecoder().decode(SnapshotManifest.self, from: data)
                    // The id becomes a directory name, so refuse one that could point elsewhere
                    guard manifest.hasPathSafeId else {
                        continuation.resume(throwing: Error.snapshotIdNotPathSafe(manifest.snapshotId))
                        return
                    }
                    continuation.resume(returning: manifest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func retrieveSnapshotChunk(snapshotId: String, index: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                let chunkURL = self.chunkURL(snapshotId: snapshotId, index: index)
                guard self.fileManager.fileExists(atPath: chunkURL.path) else {
                    continuation.resume(throwing: Error.snapshotChunkMissing(index))
                    return
                }
                do {
                    let data = try Data(contentsOf: chunkURL)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func sendSnapshot(manifest: SnapshotManifest, chunkProvider: @escaping @Sendable (Int) throws -> Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            queue.addOperation {
                do {
                    // Which snapshot this one replaces, read before anything is written
                    let manifestURL = self.snapshotsDirectory.appendingPathComponent("manifest.json")
                    var replacedSnapshotId: String?
                    if let existingData = try? Data(contentsOf: manifestURL),
                       let existing = try? JSONDecoder().decode(SnapshotManifest.self, from: existingData),
                       existing.hasPathSafeId {
                        replacedSnapshotId = existing.snapshotId
                    }

                    // Chunks first, in this snapshot's own directory, so the old one is untouched
                    let chunkDirectory = self.snapshotDirectory(snapshotId: manifest.snapshotId)
                    try self.fileManager.createDirectory(at: chunkDirectory, withIntermediateDirectories: true, attributes: nil)
                    for i in 0..<manifest.chunkCount {
                        let chunkData = try chunkProvider(i)
                        try chunkData.write(to: self.chunkURL(snapshotId: manifest.snapshotId, index: i))
                    }

                    // Then the manifest, which is what makes this the current snapshot
                    let manifestData = try JSONEncoder().encode(manifest)
                    try manifestData.write(to: manifestURL)

                    // Only now can the replaced snapshot's chunks go. A reader that started before
                    // the manifest changed may still be reading them, so a failure here is left
                    // for the next upload rather than reported
                    if let replacedSnapshotId, replacedSnapshotId != manifest.snapshotId {
                        try? self.fileManager.removeItem(at: self.snapshotDirectory(snapshotId: replacedSnapshotId))
                    }

                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK:- File Presenter

    public var presentedItemURL: URL? {
        return rootDirectoryURL
    }

    public var presentedItemOperationQueue: OperationQueue {
        return queue
    }

    public func presentedItemDidChange() {
        self.newVersionsContinuation.yield(())
    }
}
