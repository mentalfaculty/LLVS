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

@available(macOS 10.12, iOS 10.0, *)
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
    }
    
    fileprivate lazy var temporaryDirectory: URL = {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: result, withIntermediateDirectories: true, attributes: nil)
        return result
    }()
    
    /// The store the exchange is updating.
    public var store: Store
    
    /// Client to inform of updates
    public let newVersionsAvailable: AnyPublisher<Void, Never> = PassthroughSubject<Void, Never>().eraseToAnyPublisher()

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
    private var restoration: Restoration = .init()
    
    /// For single user syncing, it is best to use a zone. In that case, pass in the private database and a zone identifier.
    /// Otherwise, you will be using the default  zone in whichever database you pass.
    public init(with store: Store, storeIdentifier: String, cloudDatabasDescription: CloudDatabaseDescription) {
        self.store = store
        self.storeIdentifier = storeIdentifier
        self.zoneIdentifier = cloudDatabasDescription.zoneIdentifier
        self.database = cloudDatabasDescription.database
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
            guard let versionIdentifier = record.recordID.versionIdentifier(forStore: self.storeIdentifier) else { return }
            self.restoration.versionsInCloud.insert(versionIdentifier)
            log.verbose("Found record for version: \(versionIdentifier)")
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
        let prefix = CKRecord.ID.prefix(forStoreIdentifier: storeIdentifier)
        if let lastQueryDate = restoration.lastQueryDate {
            predicate = NSPredicate(format: "(recordName BEGINSWITH %@) AND (modifedAt >= %@)", prefix, lastQueryDate as NSDate)
        } else {
            predicate = NSPredicate(format: "recordName BEGINSWITH %@", prefix)
        }
        return CKQuery(recordType: CKRecord.ExchangeType.Version.rawValue, predicate: predicate)
    }
    
    /// Get any new version identifiers in cloud
    func queryDatabaseForNewVersions(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        log.trace("Querying cloud for new versions")
        let query = makeRecordsQuery()
        queryDatabase(with: .query(query)) { result in
            switch result {
            case .failure(let error):
                completionHandler(.failure(error))
            case .success(let records):
                let versionIdentifiers = records.map { $0.recordID.versionIdentifier(forStore: self.storeIdentifier)! }
                self.restoration.versionsInCloud.formUnion(versionIdentifiers)
                let modificationDates = records.map { $0.modificationDate! }
                self.restoration.lastQueryDate = max(self.restoration.lastQueryDate ?? Date.distantPast, modificationDates.max() ?? Date.distantPast )
                completionHandler(.success(()))
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

@available(macOS 10.12, *)
public extension CloudKitExchange {
    
    func prepareToRetrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        log.trace("Preparing to retrieve")
        if zone != nil {
            fetchCloudZoneChanges(executingUponCompletion: completionHandler)
        } else {
            queryDatabaseForNewVersions(executingUponCompletion: completionHandler)
        }
    }
    
    func retrieveVersions(identifiedBy versionIdentifiers: [Version.Identifier], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version]>) {
        log.trace("Retrieving versions")
        let recordIDs = versionIdentifiers.map { CKRecord.ID(versionIdentifier: $0, storeIdentifier: storeIdentifier, zoneID: zoneID ?? .default) }
        let fetchOperation = CKFetchRecordsOperation(recordIDs: recordIDs)
        fetchOperation.desiredKeys = [CKRecord.ExchangeKey.version.rawValue]
        fetchOperation.fetchRecordsCompletionBlock = { recordsByRecordID, error in
            guard error == nil else {
                completionHandler(.failure(error!))
                return
            }
            
            do {
                var versions: [Version] = []
                for record in recordsByRecordID!.values {
                    if let data = record.exchangeValue(forKey: .version) as? Data, let version = try JSONDecoder().decode([Version].self, from: data).first {
                        versions.append(version)
                    } else {
                        throw Error.couldNotGetVersionFromRecord
                    }
                }
                log.verbose("Retrieved versions: \(versions)")
                completionHandler(.success(versions))
            } catch {
                completionHandler(.failure(error))
            }
        }
        database.add(fetchOperation)
    }
    
    func retrieveAllVersionIdentifiers(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier]>) {
        log.verbose("Retrieved all versions: \(restoration.versionsInCloud.map({ $0.identifierString }))")
        completionHandler(.success(Array(restoration.versionsInCloud)))
    }
    
    func retrieveValueChanges(forVersionsIdentifiedBy versionIdentifiers: [Version.Identifier], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier:[Value.Change]]>) {
        log.trace("Retrieving value changes for versions: \(versionIdentifiers)")
        let recordIDs = versionIdentifiers.map { CKRecord.ID(versionIdentifier: $0, storeIdentifier: storeIdentifier, zoneID: zoneID ?? .default) }
        let fetchOperation = CKFetchRecordsOperation(recordIDs: recordIDs)
        fetchOperation.desiredKeys = [CKRecord.ExchangeKey.valueChanges.rawValue, CKRecord.ExchangeKey.valueChangesAsset.rawValue]
        fetchOperation.fetchRecordsCompletionBlock = { recordsByRecordID, error in
            guard error == nil, let recordsByRecordID = recordsByRecordID else {
                completionHandler(.failure(error!))
                return
            }
            
            do {
                let changesByVersion: [(Version.Identifier, [Value.Change])] = try recordsByRecordID.map { keyValue in
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
                    return (recordID.versionIdentifier(forStore: self.storeIdentifier)!, valueChanges)
                }
                
                completionHandler(.success(.init(uniqueKeysWithValues: changesByVersion)))
            } catch {
                log.error("Failed to retrieve: \(error)")
                completionHandler(.failure(error))
            }
        }
        database.add(fetchOperation)
    }
}


// MARK:- Sending

@available(macOS 10.12, *)
public extension CloudKitExchange {
    
    func prepareToSend(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        if zone != nil {
            fetchCloudZoneChanges(executingUponCompletion: completionHandler)
        } else {
            queryDatabaseForNewVersions(executingUponCompletion: completionHandler)
        }
    }
    
    func send(_ version: Version, with valueChanges: [Value.Change], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        log.trace("Sending version: \(version.identifier)")
        log.verbose("Value changes: \(valueChanges)")
    
        do {
            var tempFileURL: URL?
            let recordID = CKRecord.ID(versionIdentifier: version.identifier, storeIdentifier: storeIdentifier, zoneID: zoneID ?? .default)
            let record = CKRecord(recordType: .init(CKRecord.ExchangeType.Version.rawValue), recordID: recordID)
            let versionData = try JSONEncoder().encode([version]) // Use an array, because JSON needs root dict or array
            let changesData = try JSONEncoder().encode(valueChanges)
            record.setExchangeValue(versionData, forKey: .version)
            
            // Use an asset for bigger values (>10Kb)
            if changesData.count <= 10000 {
                record.setExchangeValue(changesData, forKey: .valueChanges)
            } else {
                tempFileURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try changesData.write(to: tempFileURL!)
                let asset = CKAsset(fileURL: tempFileURL!)
                record.setExchangeValue(asset, forKey: .valueChangesAsset)
            }
            
            let modifyOperation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            modifyOperation.isAtomic = true
            modifyOperation.savePolicy = .allKeys
            modifyOperation.modifyRecordsCompletionBlock = { _, _, error in
                tempFileURL.flatMap { try? FileManager.default.removeItem(at: $0) }
                if let error = error {
                    log.error("Failed to send: \(error)")
                    completionHandler(.failure(error))
                } else {
                    log.trace("Succeeded in sending")
                    completionHandler(.success(()))
                }
            }
            self.database.add(modifyOperation)
        } catch {
            log.error("Failed to send: \(error)")
            completionHandler(.failure(error))
        }
    }
    
}


// MARK:- Subscriptions

@available(macOS 10.12, *)
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
        var versionsInCloud: Set<Version.Identifier> = []
        
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

@available(macOS 10.12, *)
fileprivate extension CKRecord {
    
    enum ExchangeSubscription: String {
        case VersionCreated
    }
    
    enum ExchangeType: String {
        case Version = "LLVS_Version"
    }
    
    enum ExchangeKey: String {
        case version, valueChanges, valueChangesAsset
    }
    
    func exchangeValue(forKey key: ExchangeKey) -> Any? {
        return value(forKey: key.rawValue)
    }
    
    func setExchangeValue(_ value: Any, forKey key: ExchangeKey) {
        setValue(value, forKey: key.rawValue)
    }
    
}


@available(macOS 10.12, *)
fileprivate extension CKRecord.ID {
    
    static func prefix(forStoreIdentifier storeIdentifier: String) -> String {
        "LLVS_\(storeIdentifier)_"
    }
    
    convenience init(versionIdentifier: Version.Identifier, storeIdentifier: String, zoneID: CKRecordZone.ID) {
        let prefix = Self.prefix(forStoreIdentifier: storeIdentifier)
        self.init(recordName: prefix + versionIdentifier.identifierString, zoneID: zoneID)
    }
    
    func versionIdentifier(forStore storeIdentifier: String) -> Version.Identifier? {
        let prefix = Self.prefix(forStoreIdentifier: storeIdentifier)
        guard recordName.hasPrefix(prefix) else { return nil }
        return Version.Identifier(String(recordName.dropFirst(prefix.count)))
    }
    
}
