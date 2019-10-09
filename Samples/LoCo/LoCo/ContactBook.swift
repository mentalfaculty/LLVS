//
//  ContactBook.swift
//  LoCo
//
//  Created by Drew McCormack on 20/01/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import Foundation
import LLVS
import LLVSCloudKit
import CloudKit

extension Notification.Name {
    static let contactBookDidSaveLocalChanges = Notification.Name("contactBookDidSaveLocalChanges")
    static let contactBookDidSaveSyncChanges = Notification.Name("contactBookDidSaveSyncChanges")
}

final class ContactBook {

    enum Error: Swift.Error {
        case contactNotFound(String)
    }
    
    let store: Store
    let cloudKitExchange: CloudKitExchange
    private(set) var contacts: [Fault<Contact>] = []
    
    private(set) var lastSyncError: String?
    
    public var exchangeRestorationData: Data? {
        return cloudKitExchange.restorationState
    }
    
    fileprivate static let sharedContactBookIdentifier: Value.Identifier = .init("ContactBook")
    
    var currentVersion: Version.Identifier {
        didSet {
            guard self.currentVersion != oldValue else { return }
            log.trace("Current version of ContactBook changed to \(self.currentVersion.stringValue)")
            try! fetchContacts()
            if !isSyncing {
                NotificationCenter.default.post(name: .contactBookDidSaveLocalChanges, object: self)
            }
        }
    }
    
    init(at version: Version.Identifier, loadingFrom store: Store, exchangeRestorationData: Data?) throws {
        self.store = store
        self.currentVersion = version
        self.cloudKitExchange = CloudKitExchange(with: store, storeIdentifier: "ContactBook", cloudDatabasDescription: .privateDatabaseWithCustomZone(CKContainer.default(), zoneIdentifier: "ContactBook"))
        self.cloudKitExchange.restorationState = exchangeRestorationData
        try fetchContacts()
    }
    
    init(creatingIn store: Store) throws {
        self.store = store
        let emptyArrayData = try JSONSerialization.data(withJSONObject: [], options: [])
        let newValue = Value(id: ContactBook.sharedContactBookIdentifier, data: emptyArrayData)
        let insert: Value.Change = .insert(newValue)
        self.currentVersion = try store.makeVersion(basedOnPredecessor: nil, storing: [insert]).id
        self.cloudKitExchange = CloudKitExchange(with: store, storeIdentifier: "ContactBook", cloudDatabasDescription: .privateDatabaseWithCustomZone(CKContainer.default(), zoneIdentifier: "ContactBook"))
    }
    
    
    // MARK: Work with Contacts
    
    func add(_ contact: Contact) throws {
        var valueIds = contacts.map(\.valueId)
        valueIds.append(contact.valueId)
        
        let insertChanges = try contact.changesSinceLoad(from: store)
        let changes = insertChanges + [try updateContactsChange(withContactIdentifiers: valueIds)]
            
        currentVersion = try store.makeVersion(basedOnPredecessor: currentVersion, storing: changes).id
    }
    
    func update(_ contact: Contact) throws {
        let updateChanges = try contact.changesSinceLoad(from: store)
        guard !updateChanges.isEmpty else { return }
        currentVersion = try store.makeVersion(basedOnPredecessor: currentVersion, storing: updateChanges).id
    }
    
    func delete(_ contact: Contact) throws {
        var valueIds = contacts.map(\.valueId)
        let index = valueIds.firstIndex(of: contact.valueId)!
        valueIds.remove(at: index)
        
        let removal: Value.Change = .remove(contact.valueId)
        let changes = [removal, try updateContactsChange(withContactIdentifiers: valueIds)]
        currentVersion = try store.makeVersion(basedOnPredecessor: currentVersion, storing: changes).id
    }
    
    func move(contactAt index: Int, to destination: Int) throws {
        var identifiers = contacts.map { $0.valueId }
        let identifier = ids.remove(at: index)
        ids.insert(identifier, at: destination)
        let change = try updateContactsChange(withContactIdentifiers: identifiers)
        currentVersion = try store.makeVersion(basedOnPredecessor: currentVersion, storing: [change]).id
    }
    
    
    // MARK: Fetch and Save in Store
    
    fileprivate func fetchContactIdentifiers(atVersionIdentifiedBy versionId: Version.Identifier) throws -> [Value.Identifier] {
        let data = try store.value(ContactBook.sharedContactBookIdentifier, at: versionId)!.data
        let idStrings = try JSONSerialization.jsonObject(with: data, options: []) as! [String]
        return idStrings.map { Value.Identifier($0) }
    }
    
    fileprivate func fetchContacts() throws {
        let contactIds = try fetchContactIdentifiers(atVersionIdentifiedBy: currentVersion)
        self.contacts = contactIds.map { Fault<Contact>($0, atVersion: currentVersion, in: store) }
    }
    
    fileprivate func updateContactsChange(withContactIdentifiers valueIds: [Value.Identifier]) throws -> Value.Change {
        let stringValues = valueIds.map { $0.stringValue }
        let data = try JSONSerialization.data(withJSONObject: stringValues, options: [])
        let newValue = Value(id: ContactBook.sharedContactBookIdentifier, data: data)
        let update: Value.Change = .update(newValue)
        return update
    }

    
    // MARK: Sync
    
    private var isSyncing = false
    
    private lazy var syncQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    
    func enqueueSync(executingUponCompletion completionHandler: ((Swift.Error?) -> Void)? = nil) {
        syncQueue.addOperation {
            self.sync(executingUponCompletion: completionHandler)
        }
    }
    
    func sync(executingUponCompletion completionHandler: ((Swift.Error?) -> Void)? = nil) {
        isSyncing = true
    
        var downloadedNewVersions = false
        let retrieve = AsynchronousTask { finish in
            self.cloudKitExchange.retrieve { result in
                switch result {
                case let .failure(error):
                    finish(.failure(error))
                case let .success(versionIds):
                    downloadedNewVersions = !versionIds.isEmpty
                    finish(.success)
                }
            }
        }
        
        let send = AsynchronousTask { finish in
            self.cloudKitExchange.send { result in
                switch result {
                case let .failure(error):
                    finish(.failure(error))
                case .success:
                    finish(.success)
                }
            }
        }
        
        [retrieve, send].executeInOrder { result in
            var madeChanges = false
            var returnError: Swift.Error?
            switch result {
            case let .failure(error):
                returnError = error
                self.lastSyncError = error.localizedDescription
                log.error("Failed to sync: \(error)")
            case .success:
                log.trace("Sync successful")
                if downloadedNewVersions {
                    madeChanges = self.mergeHeads()
                }
            }
            DispatchQueue.main.async {
                completionHandler?(returnError)
                if madeChanges {
                    NotificationCenter.default.post(name: .contactBookDidSaveSyncChanges, object: self, userInfo: nil)
                }
                self.isSyncing = false
            }
        }
    }
    
    func send(executingUponCompletion completionHandler: ((Swift.Error?) -> Void)? = nil) {
        self.cloudKitExchange.send { result in
            DispatchQueue.main.async {
                switch result {
                case let .failure(error):
                    completionHandler?(error)
                case .success:
                    completionHandler?(nil)
                }
            }
        }
    }
    
    func mergeHeads() -> Bool {
        var heads: Set<Version.Identifier> = []
        store.queryHistory { history in
            heads = history.headIdentifiers
        }
        heads.remove(currentVersion)
        
        guard !heads.isEmpty else { return false }
        
        let arbiter = ContactMergeArbiter(contactBook: self)
        var versionId: Version.Identifier = currentVersion
        for otherHead in heads {
            let newVersion = try! store.merge(version: versionId, with: otherHead, resolvingWith: arbiter)
            versionId = newVersion.id
        }
        
        DispatchQueue.main.async {
            self.currentVersion = versionId
        }
        
        return true
    }

}

class ContactMergeArbiter: MergeArbiter {
    
    weak var contactBook: ContactBook!
    
    init(contactBook: ContactBook) {
        self.contactBook = contactBook
    }
    
    func changes(toResolve merge: Merge, in store: Store) throws -> [Value.Change] {
        var contactBookChanges: [Value.Change] = []
        if let contactBookFork = merge.forksByValueIdentifier[ContactBook.sharedContactBookIdentifier] {
            switch contactBookFork {
            case .twiceUpdated, .twiceInserted:
                let contactIdsAncestor:  [Value.Identifier]
                if let v = merge.commonAncestor?.id {
                    contactIdsAncestor = try contactBook.fetchContactIdentifiers(atVersionIdentifiedBy: v)
                } else {
                    contactIdsAncestor = []
                }
                
                let contactIds1 = try contactBook.fetchContactIdentifiers(atVersionIdentifiedBy: merge.versions.first.id)
                let contactIds2 = try contactBook.fetchContactIdentifiers(atVersionIdentifiedBy: merge.versions.second.id)
                let diff1 = ArrayDiff(originalValues: contactIdsAncestor, finalValues: contactIds1)
                let diff2 = ArrayDiff(originalValues: contactIdsAncestor, finalValues: contactIds2)
                let mergedDiff = ArrayDiff(merging: diff1, with: diff2)
                var mergedContactIds = contactIdsAncestor.applying(mergedDiff)
                
                // Need to guarantee that any deleted contact is really deleted
                let deletes1 = Set(contactIdsAncestor).subtracting(contactIds1)
                let deletes2 = Set(contactIdsAncestor).subtracting(contactIds2)
                mergedContactIds = mergedContactIds.filter { !deletes1.contains($0) && !deletes2.contains($0) }
                
                // Need to enforce uniqueness
                var encountered: Set<Value.Identifier> = []
                var uniqued: [Value.Identifier] = []
                for id in mergedContactIds {
                    guard !encountered.contains(id) else { continue }
                    uniqued.append(id)
                    encountered.insert(id)
                }
                mergedContactIds = uniqued
                
                // Convert these ids to a change
                let change = try contactBook.updateContactsChange(withContactIdentifiers: mergedContactIds)
                contactBookChanges.append(change)
            case .inserted, .updated:
                break
            case .removedAndUpdated, .removed, .twiceRemoved:
                fatalError("ContactBook should never be removed")
            }
        }
        
        // Remove the contact book from the remaining merge
        var defaultMerge: Merge = merge
        defaultMerge.forksByValueIdentifier[ContactBook.sharedContactBookIdentifier] = nil
        
        // Use a standard merge arbiter
        let defaultArbiter = MostRecentChangeFavoringArbiter()
        let defaultChanges = try defaultArbiter.changes(toResolve: defaultMerge, in: store)

        return defaultChanges + contactBookChanges
    }
    
}
