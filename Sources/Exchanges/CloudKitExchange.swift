//
//  CloudKitExchange
//  LLVS
//
//  Created by Drew McCormack on 16/03/2019.
//

import Foundation
import CloudKit

@available(macOS 10.12, *)
public class CloudKitExchange: Exchange {
    
    public enum Error: Swift.Error {
        case couldNotGetVersionFromRecord
        case noZoneFound
        case invalidValueChangesDataInRecord
    }
    
    public var store: Store
    
    public weak var client: ExchangeClient?

    public let zoneIdentifier: String
    public let database: CKDatabase
    public let zone: CKRecordZone
    
    private let createZoneOperation: CKModifyRecordZonesOperation
    
    private var versionsInCloud: Set<Version.Identifier> = []
    private var fetchRecordChangesToken: CKServerChangeToken?
    
    private var zoneID: CKRecordZone.ID {
        return CKRecordZone.ID(zoneName: zoneIdentifier, ownerName: CKCurrentUserDefaultName)
    }
    
    public init(with store: Store, zoneIdentifier identifier: String, cloudDatabase: CKDatabase) {
        self.store = store
        self.zoneIdentifier = identifier
        self.database = cloudDatabase
        self.zone = CKRecordZone(zoneName: zoneIdentifier)
        self.createZoneOperation = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
        self.database.add(self.createZoneOperation)
    }

    public func removeZone(completionHandler completion: @escaping CompletionHandler<Void>) {
        log.trace("Removing zone")
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
    
    fileprivate func fetchCloudChanges(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        log.trace("Fetching cloud changes")

        let options = CKFetchRecordZoneChangesOperation.ZoneOptions()
        options.previousServerChangeToken = fetchRecordChangesToken
        
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], optionsByRecordZoneID: [zoneID : options])
        operation.addDependency(createZoneOperation)
        operation.fetchAllChanges = true
        operation.recordChangedBlock = { record in
            let versionString = record.recordID.recordName
            self.versionsInCloud.insert(.init(versionString))
            log.verbose("Found record for version: \(versionString)")
        }
        operation.recordZoneFetchCompletionBlock = { zoneID, token, clientData, moreComing, error in
            self.fetchRecordChangesToken = token
            log.verbose("Stored iCloud token: \(String(describing: token))")
        }
        operation.fetchRecordZoneChangesCompletionBlock = { error in
            if let error = error as? CKError, error.code == .changeTokenExpired {
                self.fetchRecordChangesToken = nil
                self.versionsInCloud = []
                self.fetchCloudChanges(executingUponCompletion: completionHandler)
                log.error("iCloud token expired. Cleared cached data")
            } else if let error = error {
                log.error("Error fetching changes: \(error)")
                completionHandler(.failure(error))
            } else {
                log.trace("Fetched changes")
                completionHandler(.success(()))
            }
        }
        
        database.add(operation)
    }
}


@available(macOS 10.12, *)
public extension CloudKitExchange {
    
    func prepareToRetrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        log.trace("Preparing to retrieve")
        fetchCloudChanges(executingUponCompletion: completionHandler)
    }
    
    func retrieveVersions(identifiedBy versionIdentifiers: [Version.Identifier], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version]>) {
        log.trace("Retrieving versions")
        let recordIDs = versionIdentifiers.map { CKRecord.ID(recordName: $0.identifierString, zoneID: zoneID) }
        let fetchOperation = CKFetchRecordsOperation(recordIDs: recordIDs)
        fetchOperation.desiredKeys = ["version"]
        fetchOperation.fetchRecordsCompletionBlock = { recordsByRecordID, error in
            guard error == nil else {
                completionHandler(.failure(error!))
                return
            }
            
            do {
                var versions: [Version] = []
                for record in recordsByRecordID!.values {
                    if let data = record.value(forKey: "version") as? Data, let version = try JSONDecoder().decode([Version].self, from: data).first {
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
        log.verbose("Retrieved all versions: \(versionsInCloud.map({ $0.identifierString }))")
        completionHandler(.success(Array(versionsInCloud)))
    }
    
    func retrieveValueChanges(forVersionsIdentifiedBy versionIdentifiers: [Version.Identifier], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier:[Value.Change]]>) {
        log.trace("Retrieving value changes for versions: \(versionIdentifiers)")
        let recordIDs = versionIdentifiers.map { CKRecord.ID(recordName: $0.identifierString, zoneID: zoneID) }
        let fetchOperation = CKFetchRecordsOperation(recordIDs: recordIDs)
        fetchOperation.desiredKeys = ["valueChanges"]
        fetchOperation.fetchRecordsCompletionBlock = { recordsByRecordID, error in
            guard error == nil, let recordsByRecordID = recordsByRecordID else {
                completionHandler(.failure(error!))
                return
            }
            
            do {
                let changesByVersion: [(Version.Identifier, [Value.Change])] = try recordsByRecordID.map { keyValue in
                    let record = keyValue.value
                    let recordID = keyValue.key
                    guard let data = record.value(forKey: "valueChanges") as? Data else {
                        throw Error.invalidValueChangesDataInRecord
                    }
                    let valueChanges: [Value.Change] = try JSONDecoder().decode([Value.Change].self, from: data)
                    log.verbose("Retrieved value changes for \(recordID.recordName): \(valueChanges)")
                    return (Version.Identifier(recordID.recordName), valueChanges)
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


@available(macOS 10.12, *)
public extension CloudKitExchange {
    
    func prepareToSend(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        fetchCloudChanges(executingUponCompletion: completionHandler)
    }
    
    func send(_ version: Version, with valueChanges: [Value.Change], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        log.trace("Sending version: \(version.identifier)")
        log.verbose("Value changes: \(valueChanges)")
        do {
            let recordID = CKRecord.ID(recordName: version.identifier.identifierString, zoneID: zoneID)
            let record = CKRecord(recordType: .init("Version"), recordID: recordID)
            let versionData = try JSONEncoder().encode([version]) // Use an array, because JSON needs root dict or array
            let changesData = try JSONEncoder().encode(valueChanges)
            record.setValue(versionData, forKey: "version")
            record.setValue(changesData, forKey: "valueChanges")
            
            let modifyOperation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            modifyOperation.isAtomic = true
            modifyOperation.savePolicy = .allKeys
            modifyOperation.modifyRecordsCompletionBlock = { _, _, error in
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


public extension CloudKitExchange {
    
    func subscribeForPushNotifications() {
        log.trace("Subscribing for CloudKit push notifications")
        
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        
        let predicate = NSPredicate(value: true)
        let subscription = CKQuerySubscription(recordType: .init("Version"), predicate: predicate, subscriptionID: "VersionCreated", options: CKQuerySubscription.Options.firesOnRecordCreation)
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
