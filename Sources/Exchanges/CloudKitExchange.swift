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
    }
    
    public var store: Store
    
    public weak var client: ExchangeClient?

    public let zoneIdentifier: String
    public let database: CKDatabase
    public private(set) var zone: CKRecordZone?
    
    private let createZoneOperation: CKModifyRecordZonesOperation
    private let fetchZoneOperation: CKFetchRecordZonesOperation
    
    private var versionsInCloud: Set<Version.Identifier> = []
    private var fetchRecordChangesToken: CKServerChangeToken?
    
    private var zoneID: CKRecordZone.ID {
        return CKRecordZone.ID(zoneName: zoneIdentifier, ownerName: CKCurrentUserDefaultName)
    }
    
    public init(with store: Store, zoneIdentifier identifier: String, cloudDatabase: CKDatabase) {
        self.store = store
        self.zoneIdentifier = identifier
        self.database = cloudDatabase
        
        let zone = CKRecordZone(zoneName: zoneIdentifier)
        self.createZoneOperation = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
        self.database.add(self.createZoneOperation)
        
        self.fetchZoneOperation = CKFetchRecordZonesOperation(recordZoneIDs: [.init(zoneName: zoneIdentifier)])
        self.fetchZoneOperation.fetchRecordZonesCompletionBlock = { recordZonesByZoneID, error in
            if let zone = recordZonesByZoneID?.first?.value {
                self.zone = zone
            } else {
                NSLog("failed to create zone: \(zone)")
            }
        }
        self.fetchZoneOperation.addDependency(self.createZoneOperation)
        self.database.add(self.fetchZoneOperation)
    }

    public func removeZone(completionHandler completion: @escaping CompletionHandler<Void>) {
        guard let zone = self.zone else {
            completion(.failure(Error.noZoneFound))
            return
        }
        
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
        
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], optionsByRecordZoneID: [zoneID : options])
        operation.addDependency(fetchZoneOperation)
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
        let recordID = CKRecord.ID(recordName: versionIdentifier.identifierString, zoneID: zoneID)
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
