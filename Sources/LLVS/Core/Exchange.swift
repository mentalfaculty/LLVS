//
//  Exchange.swift
//  LLVS
//
//  Created by Drew McCormack on 25/02/2019.
//

import Foundation

enum ExchangeError: Swift.Error {
    case remoteVersionsWithUnknownPredecessors
    case missingVersion
    case unknown(error: Swift.Error)
}

public typealias VersionChanges = (version: Version, valueChanges: [Value.Change])

public protocol SnapshotExchange {
    func retrieveSnapshotManifest() async throws -> SnapshotManifest?
    func retrieveSnapshotChunk(index: Int) async throws -> Data
    func sendSnapshot(manifest: SnapshotManifest, chunkProvider: @escaping (Int) throws -> Data) async throws
}

public protocol Exchange: AnyObject {

    var newVersionsAvailable: AsyncStream<Void> { get }

    var store: Store { get }

    var restorationState: Data? { get set }

    func retrieve() async throws -> [Version.ID]
    func prepareToRetrieve() async throws
    func retrieveAllVersionIdentifiers() async throws -> [Version.ID]
    func retrieveVersions(identifiedBy versionIds: [Version.ID]) async throws -> [Version]
    func retrieveValueChanges(forVersionsIdentifiedBy versionIds: [Version.ID]) async throws -> [Version.ID: [Value.Change]]

    func send() async throws -> [Version.ID]
    func prepareToSend() async throws
    func send(versionChanges: [VersionChanges]) async throws
}

// MARK:- Retrieving

public extension Exchange {

    func retrieve() async throws -> [Version.ID] {
        log.trace("Retrieving")

        try await prepareToRetrieve()

        let remoteIds = try await retrieveAllVersionIdentifiers()

        let toRetrieveIds = versionIdsMissingFromHistory(forRemoteIdentifiers: remoteIds)
        log.verbose("Version identifiers to retrieve: \(toRetrieveIds.idStrings)")

        let remoteVersions = try await retrieveVersions(identifiedBy: toRetrieveIds)

        log.verbose("Adding to history versions: \(remoteVersions.idStrings)")
        try await addToHistory(remoteVersions)

        log.trace("Retrieved")
        return remoteIds
    }

    private func versionIdsMissingFromHistory(forRemoteIdentifiers remoteIdentifiers: [Version.ID]) -> [Version.ID] {
        var toRetrieveIds: [Version.ID]!
        self.store.queryHistory { history in
            let storeVersionIds = Set(history.allVersionIdentifiers)
            let remoteVersionIds = Set(remoteIdentifiers)
            toRetrieveIds = Array(remoteVersionIds.subtracting(storeVersionIds))
        }
        return toRetrieveIds
    }

    private func addToHistory(_ versions: [Version]) async throws {
        let versionsByIdentifier = versions.reduce(into: [:]) { result, version in
            result[version.id] = version
        }

        let sortedVersions = versions.sorted { $0.timestamp < $1.timestamp }

        func batchSizeCostEvaluator(index: Int) -> Float {
            let batchDataSizeLimit = 5000000 // 5MB
            let version = sortedVersions[index]
            return Float(version.valueDataSize ?? 100000) / Float(batchDataSizeLimit)
        }

        let dynamicBatcher = DynamicTaskBatcher(numberOfTasks: sortedVersions.count, taskCostEvaluator: batchSizeCostEvaluator) { range in
            let batchVersions = Array(sortedVersions[range])
            let valueChangesByVersionIdentifier = try await self.retrieveValueChanges(forVersionsIdentifiedBy: batchVersions.ids)

            let valueChangesByVersionID: [Version.ID: [Value.Change]] = valueChangesByVersionIdentifier.reduce(into: [:]) { result, keyValue in
                var version = versionsByIdentifier[keyValue.key]!
                let decompressedChanges = DataCompression.decompressValueChanges(keyValue.value)
                if version.valueDataSize == nil { version.valueDataSize = decompressedChanges.valueDataSize }
                result[version.id] = decompressedChanges
            }

            do {
                try self.addToHistory(sortedVersions: batchVersions, valueChangesByVersionID: valueChangesByVersionID)
                return .completed
            } catch let error as ExchangeError where error.isUnknownPredecessors {
                return .growBatchAndRetry
            }
        }
        try await dynamicBatcher.start()
    }

    private func addToHistory(sortedVersions: [Version], valueChangesByVersionID: [Version.ID: [Value.Change]]) throws {
        var remaining = sortedVersions
        while !remaining.isEmpty {
            guard let version = appendableVersion(from: remaining) else {
                throw ExchangeError.remoteVersionsWithUnknownPredecessors
            }
            autoreleasepool {
                let valueChanges = valueChangesByVersionID[version.id]!
                log.trace("Adding version to store: \(version.id.rawValue)")
                log.verbose("Value changes for \(version.id.rawValue): \(valueChanges)")

                do {
                    try self.store.addVersion(version, storing: valueChanges)
                } catch Store.Error.attemptToAddExistingVersion {
                    log.error("Failed adding to history because version already exists. Ignoring error")
                } catch {
                    log.error("Failed adding to history: \(error)")
                }
            }
            remaining = remaining.filter { $0.id != version.id }
        }
    }

    private func appendableVersion(from versions: [Version]) -> Version? {
        return versions.first { v in
            return store.historyIncludesVersions(identifiedBy: v.predecessors?.ids ?? [])
        }
    }

}

// MARK:- Sending

public extension Exchange {

    func send() async throws -> [Version.ID] {
        try await prepareToSend()

        let remoteIds = try await retrieveAllVersionIdentifiers()
        let toSendIds = versionIdsMissingRemotely(forRemoteIdentifiers: remoteIds)

        func batchSizeCostEvaluator(index: Int) -> Float {
            let batchDataSizeLimit: Int64 = 5000000 // 5MB
            let defaultDataSize: Int64 = 100000 // 100KB
            if let version = try? self.store.version(identifiedBy: toSendIds[index]) {
                return Float(version.valueDataSize ?? defaultDataSize) / Float(batchDataSizeLimit)
            } else {
                return Float(defaultDataSize) / Float(batchDataSizeLimit)
            }
        }

        let taskBatcher = DynamicTaskBatcher(numberOfTasks: toSendIds.count, taskCostEvaluator: batchSizeCostEvaluator) { range in
            let versionChanges: [VersionChanges] = try toSendIds[range].map { versionId in
                guard let version = try self.store.version(identifiedBy: versionId) else {
                    throw ExchangeError.missingVersion
                }
                let changes = try self.store.valueChanges(madeInVersionIdentifiedBy: versionId)
                let compressedChanges = DataCompression.compressValueChanges(changes)
                return (version, compressedChanges)
            }

            guard !versionChanges.isEmpty else {
                return .completed
            }

            try await self.send(versionChanges: versionChanges)
            return .completed
        }
        try await taskBatcher.start()

        return toSendIds
    }

    private func versionIdsMissingRemotely(forRemoteIdentifiers remoteIdentifiers: [Version.ID]) -> [Version.ID] {
        var toSendIds: [Version.ID]!
        self.store.queryHistory { history in
            let storeVersionIds = Set(history.allVersionIdentifiers)
            let remoteVersionIds = Set(remoteIdentifiers)
            toSendIds = Array(storeVersionIds.subtracting(remoteVersionIds))
        }
        return toSendIds
    }
}

// MARK: - Helpers

extension ExchangeError {
    var isUnknownPredecessors: Bool {
        if case .remoteVersionsWithUnknownPredecessors = self { return true }
        return false
    }
}
