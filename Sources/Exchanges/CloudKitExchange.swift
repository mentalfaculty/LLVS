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
    }
    
    public var store: Store
    
    public weak var client: ExchangeClient?

    public let zoneIdentifier: String
    public let database: CKDatabase
    public let zone: CKRecordZone
    private let prepareZoneOperation: CKDatabaseOperation
    
    private var versionsInCloud: Set<Version.Identifier> = []
    private var fetchRecordChangesToken: CKServerChangeToken?
    
    public init(with store: Store, zoneIdentifier identifier: String, cloudDatabase: CKDatabase) {
        self.store = store
        self.zoneIdentifier = identifier
        self.database = cloudDatabase
        self.zone = CKRecordZone(zoneName: zoneIdentifier)
        self.prepareZoneOperation = CKModifyRecordZonesOperation(recordZonesToSave: [self.zone], recordZoneIDsToDelete: nil)
        self.database.add(self.prepareZoneOperation)
    }
    
    public func removeZone(completionHandler completion: @escaping CompletionHandler<Void>) {
        database.delete(withRecordZoneID: zone.zoneID) { zoneID, error in
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }
    
    fileprivate func fetchCloudChanges(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        let options = CKFetchRecordZoneChangesOperation.ZoneOptions()
        options.previousServerChangeToken = fetchRecordChangesToken
        
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zone.zoneID], optionsByRecordZoneID: [zone.zoneID : options])
        operation.addDependency(prepareZoneOperation)
        operation.fetchAllChanges = true
        operation.recordChangedBlock = { record in
            let versionString = record.recordID.recordName
            self.versionsInCloud.insert(.init(versionString))
        }
        operation.recordZoneFetchCompletionBlock = { zoneID, token, clientData, moreComing, error in
            self.fetchRecordChangesToken = token
        }
        operation.fetchRecordZoneChangesCompletionBlock = { error in
            if let error = error as? CKError, error.code == .changeTokenExpired {
                self.fetchRecordChangesToken = nil
                self.versionsInCloud = []
                self.fetchCloudChanges(executingUponCompletion: completionHandler)
            } else if let error = error {
                completionHandler(.failure(error))
            } else {
                completionHandler(.success(()))
            }
        }
        
        database.add(operation)
    }
}


@available(macOS 10.12, *)
public extension CloudKitExchange {
    
    func prepareToRetrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        fetchCloudChanges(executingUponCompletion: completionHandler)
    }
    
    func retrieveVersions(identifiedBy versionIdentifiers: [Version.Identifier], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version]>) {
        let recordIDs = versionIdentifiers.map { CKRecord.ID(recordName: $0.identifierString) }
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
                completionHandler(.success(versions))
            } catch {
                completionHandler(.failure(error))
            }
        }
        database.add(fetchOperation)
    }
    
    func retrieveAllVersionIdentifiers(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.Identifier]>) {
        completionHandler(.success(Array(versionsInCloud)))
    }
    
    func retrieveValueChanges(forVersionIdentifiedBy versionIdentifier: Version.Identifier, executingUponCompletion completionHandler: @escaping CompletionHandler<[Value.Change]>) {
        let recordID = CKRecord.ID(recordName: versionIdentifier.identifierString)
        let fetchOperation = CKFetchRecordsOperation(recordIDs: [recordID])
        fetchOperation.desiredKeys = ["valueChanges"]
        fetchOperation.fetchRecordsCompletionBlock = { recordsByRecordID, error in
            guard error == nil else {
                completionHandler(.failure(error!))
                return
            }
            
            do {
                if let record = recordsByRecordID?.values.first, let data = record.value(forKey: "valueChanges") as? Data {
                    let valueChanges: [Value.Change] = try JSONDecoder().decode([Value.Change].self, from: data)
                    completionHandler(.success(valueChanges))
                } else {
                    completionHandler(.success([]))
                }
            } catch {
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
        do {
            let record = CKRecord(recordType: .init("Version"), recordID: .init(recordName: version.identifier.identifierString))
            let versionData = try JSONEncoder().encode([version]) // Use an array, because JSON needs root dict or array
            let changesData = try JSONEncoder().encode(valueChanges)
            record.setValue(versionData, forKey: "version")
            record.setValue(changesData, forKey: "valueChanges")
            
            let modifyOperation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            modifyOperation.isAtomic = true
            modifyOperation.savePolicy = .allKeys
            modifyOperation.modifyRecordsCompletionBlock = { _, _, error in
                if let error = error {
                    completionHandler(.failure(error))
                } else {
                    completionHandler(.success(()))
                }
            }
            self.database.add(modifyOperation)
        } catch {
            completionHandler(.failure(error))
        }
    }
    
}


public extension CloudKitExchange {
    
    func subscribeForPushNotifications() {
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        
        let predicate = NSPredicate(value: true)
        let subscription = CKQuerySubscription(recordType: .init("Version"), predicate: predicate, subscriptionID: "VersionCreated", options: CKQuerySubscription.Options.firesOnRecordCreation)
        subscription.notificationInfo = info
        
        database.save(subscription) { (_, error) in
            if let error = error {
                NSLog("Error creating subscription: \(error)")
            }
        }
    }
    
}
