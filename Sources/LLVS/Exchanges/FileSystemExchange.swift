//
//  FileSystemExchange.swift
//  LLVS
//
//  Created by Drew McCormack on 25/02/2019.
//

import Foundation

public class FileSystemExchange: NSObject, Exchange, NSFilePresenter, SnapshotExchange {

    public enum Error: Swift.Error {
        case versionFileInvalid
        case changesFileInvalid
        case snapshotChunkMissing(Int)
    }

    public let store: Store

    private let minimumDelayBeforeNotifyingOfNewVersions = 1.0

    public let newVersionsAvailable: AsyncStream<Void>
    private let newVersionsContinuation: AsyncStream<Void>.Continuation

    public let rootDirectoryURL: URL
    public var versionsDirectory: URL { return rootDirectoryURL.appendingPathComponent("versions") }
    public var changesDirectory: URL { return rootDirectoryURL.appendingPathComponent("changes") }
    public var snapshotsDirectory: URL { return rootDirectoryURL.appendingPathComponent("snapshots") }

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
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.newVersionsAvailable = stream
        self.newVersionsContinuation = continuation
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
    }

    public func prepareToRetrieve() async throws {
    }

    public func retrieveAllVersionIdentifiers() async throws -> [Version.ID] {
        try await coordinateFileAccess(.read) {
            let contents = try self.fileManager.contentsOfDirectory(at: self.versionsDirectory, includingPropertiesForKeys: nil, options: [])
            return contents.map({ Version.ID($0.lastPathComponent) })
        }
    }

    public func retrieveVersions(identifiedBy versionIds: [Version.ID]) async throws -> [Version] {
        try await coordinateFileAccess(.read) {
            try versionIds.map { versionId in
                let url = self.versionsDirectory.appendingPathComponent(versionId.rawValue)
                let data = try Data(contentsOf: url)
                if let version = try JSONDecoder().decode([String: Version].self, from: data)["version"] {
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
                try changesData.write(to: changesURL)

                let versionURL = self.versionsDirectory.appendingPathComponent(version.id.rawValue)
                let versionData = try JSONEncoder().encode(["version": version])
                try versionData.write(to: versionURL)
            }
        }
    }

    private enum FileAccess {
        case read, write
    }

    private func coordinateFileAccess<T>(_ access: FileAccess, by block: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                if self.usesFileCoordination {
                    let coordinator = NSFileCoordinator(filePresenter: self)
                    var coordinatorError: NSError?

                    let accessor: (URL) -> Void = { url in
                        do {
                            let result = try block()
                            continuation.resume(returning: result)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }

                    switch access {
                    case .read:
                        coordinator.coordinate(readingItemAt: self.rootDirectoryURL, options: [], error: &coordinatorError, byAccessor: accessor)
                    case .write:
                        coordinator.coordinate(writingItemAt: self.rootDirectoryURL, options: [], error: &coordinatorError, byAccessor: accessor)
                    }

                    if let error = coordinatorError {
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
                    continuation.resume(returning: manifest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func retrieveSnapshotChunk(index: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                let chunkURL = self.snapshotsDirectory.appendingPathComponent(String(format: "chunk-%03d", index))
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

    public func sendSnapshot(manifest: SnapshotManifest, chunkProvider: @escaping (Int) throws -> Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            queue.addOperation {
                do {
                    if self.fileManager.fileExists(atPath: self.snapshotsDirectory.path) {
                        try self.fileManager.removeItem(at: self.snapshotsDirectory)
                    }
                    try self.fileManager.createDirectory(at: self.snapshotsDirectory, withIntermediateDirectories: true, attributes: nil)

                    for i in 0..<manifest.chunkCount {
                        let chunkData = try chunkProvider(i)
                        let chunkURL = self.snapshotsDirectory.appendingPathComponent(String(format: "chunk-%03d", i))
                        try chunkData.write(to: chunkURL)
                    }

                    let manifestData = try JSONEncoder().encode(manifest)
                    let manifestURL = self.snapshotsDirectory.appendingPathComponent("manifest.json")
                    try manifestData.write(to: manifestURL)

                    continuation.resume(returning: ())
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
        newVersionsContinuation.yield(())
    }
}
