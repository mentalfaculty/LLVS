//
//  CloudKitExchange
//  LLVS
//
//  Created by Drew McCormack on 16/03/2019.
//

import Foundation
import CloudKit
import LLVS
import Combine

public class CloudKitExchange: Exchange {

    public enum CloudDatabaseDescription {
        case privateDatabaseWithCustomZone(CKContainer, zoneIdentifier: String)
        case privateDatabaseWithDefaultZone(CKContainer)
        case publicDatabase(CKContainer)
        case sharedDatabase(CKContainer, zoneIdentifier: String)

        var database: CKDatabase {
            switch self {
            case let .privateDatabaseWithCustomZone(container, _):
                return container.privateCloudDatabase
            case let .privateDatabaseWithDefaultZone(container):
                return container.privateCloudDatabase
            case let .publicDatabase(container):
                return container.publicCloudDatabase
            case let .sharedDatabase(container, _):
                return container.sharedCloudDatabase
            }
        }

        var zoneIdentifier: String? {
            switch self {
            case let .privateDatabaseWithCustomZone(_, zoneIdentifier), let .sharedDatabase(_, zoneIdentifier):
                return zoneIdentifier
            default:
                return nil
            }
        }
    }

    public enum Error: Swift.Error {
        case couldNotGetVersionFromRecord
        case noZoneFound
        case invalidValueChangesDataInRecord
        case snapshotManifestDecodingFailed
        case snapshotChunkMissing(Int)
        case snapshotChunkAssetMissing(Int)
    }

    fileprivate lazy var temporaryDirectory: URL = {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: result, withIntermediateDirectories: true, attributes: nil)
        return result
    }()

    /// The store the exchange is updating.
    public var store: Store

    /// Client to inform of updates
    private let _newVersionsSubject = PassthroughSubject<Void, Never>()

    public var newVersionsAvailable: AnyPublisher<Void, Never> {
        _newVersionsSubject.eraseToAnyPublisher()
    }

    /// A store identifier identifies the store in the cloud. This allows multiple stores to use a shared zone like the public database.
    public let storeIdentifier: String

    /// Used only for the private database, when syncing via a custom zone.
    public let zoneIdentifier: String?

    /// Can be private, shared or public database. For private, it is best to provide a zone identifier.
    public let database: CKDatabase

    /// The custom zone being used in the private database, if there is one.
    public let zone: CKRecordZone?

    /// Use to make dependencies when working with a custom zone
    private let createZoneOperation: CKModifyRecordZonesOperation?

    /// Zone identifier if we are using a custom zone
    private var zoneID: CKRecordZone.ID? {
        guard let zoneIdentifier = zoneIdentifier else { return nil }
        return CKRecordZone.ID(zoneName: zoneIdentifier, ownerName: CKCurrentUserDefaultName)
    }

    /// Restoration state
    @Atomic private var restoration: Restoration = .init()

    /// Limit to use for CloudKit fetches. Should be less than actual limit (ie 400)
    private let cloudKitFetchLimit = 200

    /// For single user syncing, it is best to use a zone. In that case, pass in the private database and a zone identifier.
    /// Otherwise, you will be using the default  zone in whichever database you pass.
    public init(with store: Store, storeIdentifier: String, cloudDatabaseDescription: CloudDatabaseDescription) {
        self.store = store
        self.storeIdentifier = storeIdentifier
        self.zoneIdentifier = cloudDatabaseDescription.zoneIdentifier
        self.database = cloudDatabaseDescription.database
        self.zone = zoneIdentifier.flatMap { CKRecordZone(zoneName: $0) }
        if database.databaseScope == .private, let zone = self.zone {
            self.createZoneOperation = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
            self.database.add(self.createZoneOperation!)
        } else {
            self.createZoneOperation = nil
        }
    }

    /// Remove a zone, if there is one. Otherwise will give error.
    public func removeZone(completionHandler completion: @escaping CompletionHandler<Void>) {
        log.trace("Removing zone")
        guard let zone = zone else {
            completion(.failure(Error.noZoneFound))
            return
        }
        database.delete(withRecordZoneID: zone.zoneID) { zoneID, error in
            if let error = error {
                log.error("Removing zone failed: \(error)")
                completion(.failure(error))
            } else {
                log.trace("Removed zone")
                completion(.success(()))
            }
        }
    }
}


// MARK:- Querying Versions in Cloud

fileprivate extension CloudKitExchange {

    /// Uses the zone changes API. Requires a custom zone.
    func fetchCloudZoneChanges(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        log.trace("Fetching cloud changes")

        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.desiredKeys = []
        config.previousServerChangeToken = restoration.fetchRecordChangesToken

        let operation = CKFetchRecordZoneChangesOperation()
        operation.recordZoneIDs = [zoneID!]
        operation.configurationsByRecordZoneID = [zoneID! : config]
        operation.addDependency(createZoneOperation!)
        operation.fetchAllChanges = true
        operation.recordChangedBlock = { record in
            let versionId = Version.ID(record.recordID.recordName)
            self.restoration.versionsInCloud.insert(versionId)
            log.verbose("Found record for version: \(versionId)")
        }
        operation.recordZoneFetchCompletionBlock = { zoneID, token, clientData, moreComing, error in
            self.restoration.fetchRecordChangesToken = token
            log.verbose("Stored iCloud token: \(String(describing: token))")
        }
        operation.fetchRecordZoneChangesCompletionBlock = { error in
            if let error = error as? CKError, error.code == .changeTokenExpired || error.code == .partialFailure {
                self.restoration.fetchRecordChangesToken = nil
                self.restoration.versionsInCloud = []
                self.fetchCloudZoneChanges(executingUponCompletion: completionHandler)
                log.error("iCloud token expired. Cleared cached data")
            } else if let error = error {
                completionHandler(.failure(error))
            } else {
                log.trace("Fetched changes")
                completionHandler(.success(()))
            }
        }

        database.add(operation)
    }

    enum QueryInfo {
        case query(CKQuery)
        case cursor(CKQueryOperation.Cursor)

        func makeQueryOperation() -> CKQueryOperation {
            switch self {
            case let .cursor(cursor):
                return CKQueryOperation(cursor: cursor)
            case let .query(query):
                return CKQueryOperation(query: query)
            }
        }
    }

    func makeRecordsQuery() -> CKQuery {
        let predicate: NSPredicate
        if let lastQueryDate = restoration.lastQueryDate {
            predicate = NSPredicate(format: "storeIdentifier = %@ AND (modificationDate >= %@)", storeIdentifier, lastQueryDate as NSDate)
        } else {
            predicate = NSPredicate(format: "storeIdentifier = %@", storeIdentifier)
        }
        return CKQuery(recordType: CKRecord.ExchangeType.Version.rawValue, predicate: predicate)
    }

    /// Get any new version identifiers in cloud
    func queryDatabaseForNewVersions(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        log.trace("Querying cloud for new versions")
        let query = makeRecordsQuery()
        queryDatabase(with: .query(query)) { result in
            switch result {
            case .failure(let error as CKError) where error.code == .unknownItem:
                // Probably don't have data in cloud yet. Ignore error
                self.restoration.lastQueryDate = Date.distantPast
                completionHandler(.success(()))
            case .success(let records):
                let versionIds = records.map { Version.ID($0.recordID.recordName) }
                self.restoration.versionsInCloud.formUnion(versionIds)
                let modificationDates = records.map { $0.modificationDate! }
                self.restoration.lastQueryDate = max(self.restoration.lastQueryDate ?? Date.distantPast, modificationDates.max() ?? Date.distantPast )
                completionHandler(.success(()))
            case .failure(let error):
                completionHandler(.failure(error))
            }
        }
    }

    /// Used when no zone is available. Eg. the public database.
    func queryDatabase(with queryInfo: QueryInfo, executingUponCompletion completionHandler: @escaping CompletionHandler<[CKRecord]>) {
        log.trace("Querying cloud changes")

        let operation = queryInfo.makeQueryOperation()
        var records: [CKRecord] = []
        operation.recordFetchedBlock = { record in
            records.append(record)
        }
        operation.queryCompletionBlock = { cursor, error in
            if let cursor = cursor {
                self.queryDatabase(with: .cursor(cursor)) { result in
                    switch result {
                    case let .failure(error):
                        completionHandler(.failure(error))
                    case let .success(newRecords):
                        completionHandler(.success(records + newRecords))
                    }
                }
            }
            else {
                if let error = error { log.error("Failed to fetch new versions: \(error)") }
                completionHandler(error != nil ? .failure(error!) : .success(records))
            }
        }

        database.add(operation)
    }
}


// MARK:- Retrieving

public extension CloudKitExchange {

    func prepareToRetrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        log.trace("Preparing to retrieve")
        if zone != nil {
            fetchCloudZoneChanges(executingUponCompletion: completionHandler)
        } else {
            queryDatabaseForNewVersions(executingUponCompletion: completionHandler)
        }
    }

    func retrieveVersions(identifiedBy versionIds: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version]>) {
        log.trace("Retrieving versions: \(versionIds)")

        guard !versionIds.isEmpty else {
            completionHandler(.success([]))
            return
        }

        // Use batches, because CloudKit will give limit error at 400 records
        let batchRanges = (0...versionIds.count-1).split(intoRangesOfLength: cloudKitFetchLimit)
        var versions: [Version] = []
        let tasks = batchRanges.map { range in
            AsynchronousTask { finish in
                autoreleasepool {
                    let batchVersionIds = Array(versionIds[range])
                    self.retrieve(batchOfVersionsIdentifiedBy: batchVersionIds) { result in
                        switch result {
                        case .success(let batchVersions):
                            versions.append(contentsOf: batchVersions)
                            finish(.success(()))
                        case .failure(let error):
                            finish(.failure(error))
                        }
                    }
                }
            }
        }
        tasks.executeInOrder { result in
            switch result {
            case .success:
                completionHandler(.success(versions))
            case .failure(let error):
                completionHandler(.failure(error))
            }
        }
    }

    /// Assumes that the batch size is less than the limits imposed by CloudKit (ie 400)
    private func retrieve(batchOfVersionsIdentifiedBy versionIds: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version]>) {
        log.trace("Retrieving versions")
        let recordIDs = versionIds.map { CKRecord.ID(recordName: $0.rawValue, zoneID: zoneID ?? .default) }
        let fetchOperation = CKFetchRecordsOperation(recordIDs: recordIDs)
        fetchOperation.desiredKeys = [CKRecord.ExchangeKey.version.rawValue]
        fetchOperation.fetchRecordsCompletionBlock = { recordsByRecordID, error in
            guard error == nil else {
                completionHandler(.failure(error!))
                return
            }

            do {
                try autoreleasepool {
                    var versions: [Version] = []
                    for record in recordsByRecordID!.values {
                        try autoreleasepool {
                            if let data = record.exchangeValue(forKey: .version) as? Data, let version = try JSONDecoder().decode([Version].self, from: data).first {
                                versions.append(version)
                            } else {
                                throw Error.couldNotGetVersionFromRecord
                            }
                        }
                    }
                    log.verbose("Retrieved versions: \(versions)")
                    completionHandler(.success(versions))
                }
            } catch {
                completionHandler(.failure(error))
            }
        }
        database.add(fetchOperation)
    }

    func retrieveAllVersionIdentifiers(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID]>) {
        log.verbose("Retrieved all versions: \(restoration.versionsInCloud.map({ $0.rawValue }))")
        completionHandler(.success(Array(restoration.versionsInCloud)))
    }

    func retrieveValueChanges(forVersionsIdentifiedBy versionIds: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID:[Value.Change]]>) {
        log.trace("Retrieving value changes for versions: \(versionIds)")

        guard !versionIds.isEmpty else {
            completionHandler(.success([:]))
            return
        }

        // Use batches of length 200, because CloudKit will give limit error at 400 records
        let batchRanges = (0...versionIds.count-1).split(intoRangesOfLength: cloudKitFetchLimit)
        var changesByVersionId: [Version.ID:[Value.Change]] = [:]
        let tasks = batchRanges.map { range in
            AsynchronousTask { finish in
                autoreleasepool {
                    let batchVersionIds = Array(versionIds[range])
                    self.retrieve(batchOfValueChangesForVersionsIdentifiedBy: batchVersionIds) { result in
                        autoreleasepool {
                            switch result {
                            case .success(let newChangesByVersionId):
                                changesByVersionId.merge(newChangesByVersionId) { current, _ in current }
                                finish(.success(()))
                            case .failure(let error):
                                finish(.failure(error))
                            }
                        }
                    }
                }
            }
        }
        tasks.executeInOrder { result in
            autoreleasepool {
                switch result {
                case .success:
                    completionHandler(.success(changesByVersionId))
                case .failure(let error):
                    completionHandler(.failure(error))
                }
            }
        }
    }

    /// Retrieves a batch of value changes, assuming batch is smaller than the CloudKit limit
    private func retrieve(batchOfValueChangesForVersionsIdentifiedBy versionIds: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID:[Value.Change]]>) {
        log.trace("Retrieving value changes for versions: \(versionIds)")
        let recordIDs = versionIds.map { CKRecord.ID(recordName: $0.rawValue, zoneID: zoneID ?? .default) }
        let fetchOperation = CKFetchRecordsOperation(recordIDs: recordIDs)
        fetchOperation.desiredKeys = [CKRecord.ExchangeKey.valueChanges.rawValue, CKRecord.ExchangeKey.valueChangesAsset.rawValue]
        fetchOperation.fetchRecordsCompletionBlock = { recordsByRecordID, error in
            autoreleasepool {
                guard error == nil, let recordsByRecordID = recordsByRecordID else {
                    completionHandler(.failure(error!))
                    return
                }

                do {
                    var changesByVersion: [(Version.ID, [Value.Change])]!
                    changesByVersion = try recordsByRecordID.map { keyValue in
                        let record = keyValue.value
                        let recordID = keyValue.key
                        let data: Data
                        if let d = record.exchangeValue(forKey: .valueChanges) as? Data {
                            data = d
                        } else if let asset = record.exchangeValue(forKey: .valueChangesAsset) as? CKAsset, let url = asset.fileURL {
                            data = try Data(contentsOf: url)
                        } else {
                            throw Error.invalidValueChangesDataInRecord
                        }
                        let valueChanges: [Value.Change] = try JSONDecoder().decode([Value.Change].self, from: data)
                        log.verbose("Retrieved value changes for \(recordID.recordName): \(valueChanges)")
                        return (Version.ID(recordID.recordName), valueChanges)
                    }
                    completionHandler(.success(.init(uniqueKeysWithValues: changesByVersion)))
                } catch {
                    log.error("Failed to retrieve: \(error)")
                    completionHandler(.failure(error))
                }
            }
        }
        database.add(fetchOperation)
    }
}


// MARK:- Sending

public extension CloudKitExchange {

    func prepareToSend(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        if zone != nil {
            fetchCloudZoneChanges(executingUponCompletion: completionHandler)
        } else {
            queryDatabaseForNewVersions(executingUponCompletion: completionHandler)
        }
    }

    func send(versionChanges: [VersionChanges], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        log.trace("Sending versions: \(versionChanges.map({ $0.0.id }))")
        log.verbose("Value changes: \(versionChanges)")

        guard !versionChanges.isEmpty else {
            completionHandler(.success(()))
            return
        }

        // Use batches of length 200, because CloudKit will give limit error at 400 records
        let batchRanges = (0...versionChanges.count-1).split(intoRangesOfLength: cloudKitFetchLimit)
        let tasks = batchRanges.map { range in
            AsynchronousTask { finish in
                let batchChanges = versionChanges[range]
                self.send(batchOfVersionChanges: batchChanges) { result in
                    finish(result)
                }
            }
        }
        tasks.executeInOrder(completingWith: completionHandler)
    }

    private func send(batchOfVersionChanges versionChanges: ArraySlice<VersionChanges>, executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        do {
            try autoreleasepool {
                var tempFileURLs: [URL] = []
                let records: [CKRecord] = try versionChanges.map { t in
                    let version = t.version
                    let valueChanges = t.valueChanges
                    let recordID = CKRecord.ID(recordName: version.id.rawValue, zoneID: zoneID ?? .default)
                    let record = CKRecord(recordType: .init(CKRecord.ExchangeType.Version.rawValue), recordID: recordID)
                    let versionData = try JSONEncoder().encode([version]) // Use an array, because JSON needs root dict or array
                    let changesData = try JSONEncoder().encode(valueChanges)
                    record.setExchangeValue(versionData, forKey: .version)
                    record.setExchangeValue(storeIdentifier, forKey: .storeIdentifier)

                    // Use an asset for bigger values (>10Kb)
                    if changesData.count <= 10000 {
                        record.setExchangeValue(changesData, forKey: .valueChanges)
                    } else {
                        let tempFileURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        try changesData.write(to: tempFileURL)
                        let asset = CKAsset(fileURL: tempFileURL)
                        record.setExchangeValue(asset, forKey: .valueChangesAsset)
                        tempFileURLs.append(tempFileURL)
                    }

                    return record
                }

                let modifyOperation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
                modifyOperation.isAtomic = true
                modifyOperation.savePolicy = .allKeys
                modifyOperation.modifyRecordsCompletionBlock = { _, _, error in
                    tempFileURLs.forEach { try? FileManager.default.removeItem(at: $0) }
                    if let error = error {
                        log.error("Failed to send: \(error)")
                        completionHandler(.failure(error))
                    } else {
                        log.trace("Succeeded in sending")
                        completionHandler(.success(()))
                    }
                }
                self.database.add(modifyOperation)
            }
        } catch {
            log.error("Failed to send: \(error)")
            completionHandler(.failure(error))
        }
    }

}


// MARK:- Snapshot Exchange

extension CloudKitExchange: SnapshotExchange {

    public func retrieveSnapshotManifest(completionHandler: @escaping CompletionHandler<SnapshotManifest?>) {
        log.trace("Retrieving snapshot manifest from CloudKit")
        let recordName = "\(storeIdentifier)_snapshot_manifest"
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID ?? .default)
        let operation = CKFetchRecordsOperation(recordIDs: [recordID])
        operation.desiredKeys = [CKRecord.ExchangeKey.snapshotManifest.rawValue]
        if let createZoneOp = createZoneOperation {
            operation.addDependency(createZoneOp)
        }
        operation.fetchRecordsCompletionBlock = { recordsByID, error in
            if let ckError = error as? CKError {
                if ckError.code == .unknownItem {
                    completionHandler(.success(nil))
                    return
                }
                if ckError.code == .partialFailure,
                   let partialErrors = ckError.partialErrorsByItemID,
                   partialErrors.values.contains(where: { ($0 as? CKError)?.code == .unknownItem }) {
                    completionHandler(.success(nil))
                    return
                }
                completionHandler(.failure(ckError))
                return
            }
            guard let record = recordsByID?[recordID],
                  let manifestData = record.exchangeValue(forKey: .snapshotManifest) as? Data else {
                completionHandler(.success(nil))
                return
            }
            do {
                let manifest = try JSONDecoder().decode(SnapshotManifest.self, from: manifestData)
                log.trace("Retrieved snapshot manifest: \(manifest.snapshotId)")
                completionHandler(.success(manifest))
            } catch {
                log.error("Failed to decode snapshot manifest: \(error)")
                completionHandler(.failure(Error.snapshotManifestDecodingFailed))
            }
        }
        database.add(operation)
    }

    public func retrieveSnapshotChunk(index: Int, completionHandler: @escaping CompletionHandler<Data>) {
        log.trace("Retrieving snapshot chunk \(index) from CloudKit")
        let recordName = "\(storeIdentifier)_snapshot_chunk_\(index)"
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID ?? .default)
        let operation = CKFetchRecordsOperation(recordIDs: [recordID])
        operation.desiredKeys = [CKRecord.ExchangeKey.snapshotChunkData.rawValue]
        if let createZoneOp = createZoneOperation {
            operation.addDependency(createZoneOp)
        }
        operation.fetchRecordsCompletionBlock = { recordsByID, error in
            if let error = error {
                log.error("Failed to retrieve snapshot chunk \(index): \(error)")
                completionHandler(.failure(Error.snapshotChunkMissing(index)))
                return
            }
            guard let record = recordsByID?[recordID],
                  let asset = record.exchangeValue(forKey: .snapshotChunkData) as? CKAsset,
                  let fileURL = asset.fileURL else {
                log.error("Snapshot chunk \(index) has no asset")
                completionHandler(.failure(Error.snapshotChunkAssetMissing(index)))
                return
            }
            do {
                let data = try Data(contentsOf: fileURL)
                log.trace("Retrieved snapshot chunk \(index): \(data.count) bytes")
                completionHandler(.success(data))
            } catch {
                log.error("Failed to read snapshot chunk \(index) asset: \(error)")
                completionHandler(.failure(error))
            }
        }
        database.add(operation)
    }

    public func sendSnapshot(manifest: SnapshotManifest, chunkProvider: @escaping (Int) throws -> Data, completionHandler: @escaping CompletionHandler<Void>) {
        log.trace("Sending snapshot to CloudKit: \(manifest.chunkCount) chunks")

        let deleteExcess = AsynchronousTask { finish in
            self.deleteExcessSnapshotChunks(keepingCount: manifest.chunkCount) { result in
                finish(result)
            }
        }

        let uploadChunks = AsynchronousTask { finish in
            self.uploadSnapshotChunks(manifest: manifest, chunkProvider: chunkProvider) { result in
                finish(result)
            }
        }

        let uploadManifest = AsynchronousTask { finish in
            self.uploadSnapshotManifest(manifest) { result in
                finish(result)
            }
        }

        [deleteExcess, uploadChunks, uploadManifest].executeInOrder(completingWith: completionHandler)
    }

    // MARK: Snapshot Helpers

    private func deleteExcessSnapshotChunks(keepingCount: Int, completionHandler: @escaping CompletionHandler<Void>) {
        log.trace("Querying for excess snapshot chunks beyond index \(keepingCount)")
        let predicate = NSPredicate(format: "storeIdentifier = %@ AND snapshotChunkIndex >= %d", storeIdentifier, keepingCount)
        let query = CKQuery(recordType: CKRecord.ExchangeType.SnapshotChunk.rawValue, predicate: predicate)
        queryDatabase(with: .query(query)) { result in
            switch result {
            case .success(let records):
                if records.isEmpty {
                    log.trace("No excess snapshot chunks to delete")
                    completionHandler(.success(()))
                } else {
                    log.trace("Deleting \(records.count) excess snapshot chunks")
                    self.deleteRecords(records.map { $0.recordID }, completionHandler: completionHandler)
                }
            case .failure(let error as CKError) where error.code == .unknownItem:
                completionHandler(.success(()))
            case .failure(let error):
                log.error("Failed to query excess snapshot chunks: \(error)")
                completionHandler(.failure(error))
            }
        }
    }

    private func deleteRecords(_ recordIDs: [CKRecord.ID], completionHandler: @escaping CompletionHandler<Void>) {
        guard !recordIDs.isEmpty else {
            completionHandler(.success(()))
            return
        }
        let batchRanges = (0...recordIDs.count-1).split(intoRangesOfLength: cloudKitFetchLimit)
        let tasks = batchRanges.map { range in
            AsynchronousTask { finish in
                let batchIDs = Array(recordIDs[range])
                let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: batchIDs)
                operation.modifyRecordsCompletionBlock = { _, _, error in
                    if let error = error {
                        log.error("Failed to delete records: \(error)")
                        finish(.failure(error))
                    } else {
                        finish(.success(()))
                    }
                }
                self.database.add(operation)
            }
        }
        tasks.executeInOrder(completingWith: completionHandler)
    }

    private func uploadSnapshotChunks(manifest: SnapshotManifest, chunkProvider: @escaping (Int) throws -> Data, completionHandler: @escaping CompletionHandler<Void>) {
        guard manifest.chunkCount > 0 else {
            completionHandler(.success(()))
            return
        }
        let batchRanges = (0...manifest.chunkCount-1).split(intoRangesOfLength: cloudKitFetchLimit)
        let tasks = batchRanges.map { range in
            AsynchronousTask { finish in
                do {
                    var tempFileURLs: [URL] = []
                    let records: [CKRecord] = try range.map { index in
                        let chunkData = try chunkProvider(index)
                        let recordName = "\(self.storeIdentifier)_snapshot_chunk_\(index)"
                        let recordID = CKRecord.ID(recordName: recordName, zoneID: self.zoneID ?? .default)
                        let record = CKRecord(recordType: .init(CKRecord.ExchangeType.SnapshotChunk.rawValue), recordID: recordID)
                        record.setExchangeValue(self.storeIdentifier, forKey: .storeIdentifier)
                        record.setExchangeValue(index, forKey: .snapshotChunkIndex)

                        let tempFileURL = self.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        try chunkData.write(to: tempFileURL)
                        let asset = CKAsset(fileURL: tempFileURL)
                        record.setExchangeValue(asset, forKey: .snapshotChunkData)
                        tempFileURLs.append(tempFileURL)

                        return record
                    }
                    let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
                    operation.savePolicy = .allKeys
                    operation.modifyRecordsCompletionBlock = { _, _, error in
                        tempFileURLs.forEach { try? FileManager.default.removeItem(at: $0) }
                        if let error = error {
                            log.error("Failed to upload snapshot chunks: \(error)")
                            finish(.failure(error))
                        } else {
                            log.trace("Uploaded snapshot chunks \(range)")
                            finish(.success(()))
                        }
                    }
                    self.database.add(operation)
                } catch {
                    log.error("Failed to prepare snapshot chunks: \(error)")
                    finish(.failure(error))
                }
            }
        }
        tasks.executeInOrder(completingWith: completionHandler)
    }

    private func uploadSnapshotManifest(_ manifest: SnapshotManifest, completionHandler: @escaping CompletionHandler<Void>) {
        do {
            let manifestData = try JSONEncoder().encode(manifest)
            let recordName = "\(storeIdentifier)_snapshot_manifest"
            let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID ?? .default)
            let record = CKRecord(recordType: .init(CKRecord.ExchangeType.SnapshotManifest.rawValue), recordID: recordID)
            record.setExchangeValue(manifestData, forKey: .snapshotManifest)
            record.setExchangeValue(storeIdentifier, forKey: .storeIdentifier)
            let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            operation.savePolicy = .allKeys
            operation.modifyRecordsCompletionBlock = { _, _, error in
                if let error = error {
                    log.error("Failed to upload snapshot manifest: \(error)")
                    completionHandler(.failure(error))
                } else {
                    log.trace("Uploaded snapshot manifest")
                    completionHandler(.success(()))
                }
            }
            database.add(operation)
        } catch {
            log.error("Failed to encode snapshot manifest: \(error)")
            completionHandler(.failure(error))
        }
    }
}


// MARK:- Subscriptions

public extension CloudKitExchange {

    func subscribeForPushNotifications() {
        log.trace("Subscribing for CloudKit push notifications")

        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true

        let predicate = NSPredicate(value: true)
        let subscription = CKQuerySubscription(recordType: .init(CKRecord.ExchangeType.Version.rawValue), predicate: predicate, subscriptionID: CKRecord.ExchangeSubscription.VersionCreated.rawValue, options: CKQuerySubscription.Options.firesOnRecordCreation)
        subscription.notificationInfo = info

        database.save(subscription) { (_, error) in
            if let error = error {
                log.error("Error creating subscription: \(error)")
            } else {
                log.trace("Successfully subscribed")
            }
        }
    }

}


// MARK:- Restoration

extension CloudKitExchange {

    public var restorationState: Data? {
        get {
            try? JSONEncoder().encode(restoration)
        }
        set {
            if let newValue = newValue, let state = try? JSONDecoder().decode(Restoration.self, from: newValue) {
                restoration = state
            }
        }
    }

    fileprivate struct Restoration: Codable {

        enum CodingKeys: String, CodingKey {
            case versionsInCloud, fetchRecordChangesToken, lastQueryDate
        }

        /// Set of all version ids in cloud
        var versionsInCloud: Set<Version.ID> = []

        /// Used for private database with custom zone
        var fetchRecordChangesToken: CKServerChangeToken?

        /// Used when there is no custom zone
        var lastQueryDate: Date?

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            versionsInCloud = try container.decode(type(of: versionsInCloud), forKey: .versionsInCloud)
            if let tokenData = try container.decodeIfPresent(Data.self, forKey: .fetchRecordChangesToken) {
                fetchRecordChangesToken = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: tokenData)
            }
            lastQueryDate = try container.decodeIfPresent(Date.self, forKey: .lastQueryDate)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(versionsInCloud, forKey: .versionsInCloud)
            let tokenData = try fetchRecordChangesToken.flatMap {
                try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: false)
            }
            try container.encodeIfPresent(tokenData, forKey: .fetchRecordChangesToken)
            try container.encodeIfPresent(lastQueryDate, forKey: .lastQueryDate)
        }
    }

}


// MARK:- CKRecord

fileprivate extension CKRecord {

    enum ExchangeSubscription: String {
        case VersionCreated
    }

    enum ExchangeType: String {
        case Version = "LLVS_Version"
        case SnapshotManifest = "LLVS_SnapshotManifest"
        case SnapshotChunk = "LLVS_SnapshotChunk"
    }

    enum ExchangeKey: String {
        case version, storeIdentifier, valueChanges, valueChangesAsset
        case snapshotManifest, snapshotChunkIndex, snapshotChunkData
    }

    func exchangeValue(forKey key: ExchangeKey) -> Any? {
        return value(forKey: key.rawValue)
    }

    func setExchangeValue(_ value: Any, forKey key: ExchangeKey) {
        setValue(value, forKey: key.rawValue)
    }

}
