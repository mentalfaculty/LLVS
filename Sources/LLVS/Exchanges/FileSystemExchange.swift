//
//  FileSystemExchange.swift
//  LLVS
//
//  Created by Drew McCormack on 25/02/2019.
//

import Foundation
import Combine

public class FileSystemExchange: NSObject, Exchange, NSFilePresenter, SnapshotExchange {

    public enum Error: Swift.Error {
        case versionFileInvalid
        case changesFileInvalid
        case snapshotChunkMissing(Int)
    }

    public let store: Store

    private let minimumDelayBeforeNotifyingOfNewVersions = 1.0

    public let newVersionsSubject = PassthroughSubject<Void, Never>()

    public var newVersionsAvailable: AnyPublisher<Void, Never> {
        newVersionsSubject
            .debounce(for: .seconds(minimumDelayBeforeNotifyingOfNewVersions), scheduler: RunLoop.main)
            .eraseToAnyPublisher()
    }

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

    public func prepareToRetrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        completionHandler(.success(()))
    }

    public func retrieveAllVersionIdentifiers(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID]>) {
        coordinateFileAccess(.read, completionHandler: completionHandler) {
            let contents = try self.fileManager.contentsOfDirectory(at: self.versionsDirectory, includingPropertiesForKeys: nil, options: [])
            let versionIds = contents.map({ Version.ID($0.lastPathComponent) })
            completionHandler(.success(versionIds))
        }
    }

    public func retrieveVersions(identifiedBy versionIds: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version]>) {
        coordinateFileAccess(.read, completionHandler: completionHandler) {
            let versions: [Version] = try versionIds.map { versionId in
                let url = self.versionsDirectory.appendingPathComponent(versionId.rawValue)
                let data = try Data(contentsOf: url)
                if let version = try JSONDecoder().decode([String:Version].self, from: data)["version"] {
                    return version
                } else {
                    throw Error.versionFileInvalid
                }
            }
            completionHandler(.success(versions))
        }
    }

    public func retrieveValueChanges(forVersionsIdentifiedBy versionIds: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID:[Value.Change]]>) {
        coordinateFileAccess(.read, completionHandler: completionHandler) {
            let result: [Version.ID:[Value.Change]] = try versionIds.reduce(into: [:]) { result, versionId in
                let url = self.changesDirectory.appendingPathComponent(versionId.rawValue)
                let data = try Data(contentsOf: url)
                let changes = try JSONDecoder().decode([Value.Change].self, from: data)
                result[versionId] = changes
            }
            completionHandler(.success(result))
        }
    }

    public func prepareToSend(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        completionHandler(.success(()))
    }

    public func send(versionChanges: [VersionChanges], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        coordinateFileAccess(.write, completionHandler: completionHandler) {
             for (version, valueChanges) in versionChanges {
                 let changesURL = self.changesDirectory.appendingPathComponent(version.id.rawValue)
                 let changesData = try JSONEncoder().encode(valueChanges)
                 try changesData.write(to: changesURL)

                 let versionURL = self.versionsDirectory.appendingPathComponent(version.id.rawValue)
                 let versionData = try JSONEncoder().encode(["version":version])
                 try versionData.write(to: versionURL)
             }
            completionHandler(.success(()))
         }
    }

    private enum FileAccess {
        case read, write
    }

    private func coordinateFileAccess<ResultType>(_ access: FileAccess, completionHandler: @escaping CompletionHandler<ResultType>, by block: @escaping () throws -> Void) {
        queue.addOperation {
            if self.usesFileCoordination {
                let coordinator = NSFileCoordinator(filePresenter: self)
                var error: NSError?

                let accessor: (URL)->Void = { url in
                    do {
                        try block()
                    } catch {
                        completionHandler(.failure(error))
                    }
                }

                switch access {
                case .read:
                    coordinator.coordinate(readingItemAt: self.rootDirectoryURL, options: [], error: &error, byAccessor: accessor)
                case .write:
                    coordinator.coordinate(writingItemAt: self.rootDirectoryURL, options: [], error: &error, byAccessor: accessor)
                }

                if let error = error {
                    completionHandler(.failure(error))
                }
            } else {
                do {
                    try block()
                } catch {
                    completionHandler(.failure(error))
                }
            }
        }
    }

    // MARK:- Snapshot Exchange

    public func retrieveSnapshotManifest(completionHandler: @escaping CompletionHandler<SnapshotManifest?>) {
        queue.addOperation {
            let manifestURL = self.snapshotsDirectory.appendingPathComponent("manifest.json")
            guard self.fileManager.fileExists(atPath: manifestURL.path) else {
                completionHandler(.success(nil))
                return
            }
            do {
                let data = try Data(contentsOf: manifestURL)
                let manifest = try JSONDecoder().decode(SnapshotManifest.self, from: data)
                completionHandler(.success(manifest))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }

    public func retrieveSnapshotChunk(index: Int, completionHandler: @escaping CompletionHandler<Data>) {
        queue.addOperation {
            let chunkURL = self.snapshotsDirectory.appendingPathComponent(String(format: "chunk-%03d", index))
            guard self.fileManager.fileExists(atPath: chunkURL.path) else {
                completionHandler(.failure(Error.snapshotChunkMissing(index)))
                return
            }
            do {
                let data = try Data(contentsOf: chunkURL)
                completionHandler(.success(data))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }

    public func sendSnapshot(manifest: SnapshotManifest, chunkProvider: @escaping (Int) throws -> Data, completionHandler: @escaping CompletionHandler<Void>) {
        queue.addOperation {
            do {
                // Remove previous snapshot if any
                if self.fileManager.fileExists(atPath: self.snapshotsDirectory.path) {
                    try self.fileManager.removeItem(at: self.snapshotsDirectory)
                }
                try self.fileManager.createDirectory(at: self.snapshotsDirectory, withIntermediateDirectories: true, attributes: nil)

                // Write chunks
                for i in 0..<manifest.chunkCount {
                    let chunkData = try chunkProvider(i)
                    let chunkURL = self.snapshotsDirectory.appendingPathComponent(String(format: "chunk-%03d", i))
                    try chunkData.write(to: chunkURL)
                }

                // Write manifest
                let manifestData = try JSONEncoder().encode(manifest)
                let manifestURL = self.snapshotsDirectory.appendingPathComponent("manifest.json")
                try manifestData.write(to: manifestURL)

                completionHandler(.success(()))
            } catch {
                completionHandler(.failure(error))
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
        self.newVersionsSubject.send(())
    }
}
