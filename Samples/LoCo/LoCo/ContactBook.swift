//
//  ContactBook.swift
//  LoCo
//
//  Created by Drew McCormack on 20/01/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import Foundation
import LLVS
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
    
    fileprivate static let sharedContactBookIdentifier: Value.Identifier = .init("ContactBook")
    
    var currentVersion: Version.Identifier {
        didSet {
            guard self.currentVersion != oldValue else { return }
            log.trace("Current version of ContactBook changed to \(self.currentVersion.identifierString)")
            try! fetchContacts()
            if !isSyncing {
                NotificationCenter.default.post(name: .contactBookDidSaveLocalChanges, object: self)
            }
        }
    }
    
    init(prevailingAt version: Version.Identifier, loadingFrom store: Store) throws {
        self.store = store
        self.currentVersion = version
        self.cloudKitExchange = CloudKitExchange(with: store, zoneIdentifier: "ContactBook", cloudDatabase: CKContainer.default().privateCloudDatabase)
        try fetchContacts()
    }
    
    init(creatingIn store: Store) throws {
        self.store = store
        let emptyArrayData = try JSONSerialization.data(withJSONObject: [], options: [])
        let newValue = Value(identifier: ContactBook.sharedContactBookIdentifier, version: nil, data: emptyArrayData)
        let insert: Value.Change = .insert(newValue)
        self.currentVersion = try store.addVersion(basedOnPredecessor: nil, storing: [insert]).identifier
        self.cloudKitExchange = CloudKitExchange(with: store, zoneIdentifier: "ContactBook", cloudDatabase: CKContainer.default().privateCloudDatabase)
    }
    
    
    // MARK: Work with Contacts
    
    func add(_ contact: Contact) throws {
        var valueIdentifiers = contacts.map { $0.valueIdentifier }
        valueIdentifiers.append(contact.valueIdentifier)
        
        let insertChanges = try contact.changesSinceLoad(from: store)
        let changes = insertChanges + [try updateContactsChange(withContactIdentifiers: valueIdentifiers)]
            
        currentVersion = try store.addVersion(basedOnPredecessor: currentVersion, storing: changes).identifier
    }
    
    func update(_ contact: Contact) throws {
        let updateChanges = try contact.changesSinceLoad(from: store)
        currentVersion = try store.addVersion(basedOnPredecessor: currentVersion, storing: updateChanges).identifier
    }
    
    func delete(_ contact: Contact) throws {
        var valueIdentifiers = contacts.map { $0.valueIdentifier }
        let index = valueIdentifiers.firstIndex(of: contact.valueIdentifier)!
        valueIdentifiers.remove(at: index)
        
        let removal: Value.Change = .remove(contact.valueIdentifier)
        let changes = [removal, try updateContactsChange(withContactIdentifiers: valueIdentifiers)]
        currentVersion = try store.addVersion(basedOnPredecessor: currentVersion, storing: changes).identifier
    }
    
    func move(contactWithIdentifier moved: Value.Identifier, afterContactWithIdentifier target: Value.Identifier?) throws {
        var identifiers = contacts.compactMap { $0.valueIdentifier != moved ? $0.valueIdentifier : nil }
        if let target = target {
            guard let index = identifiers.firstIndex(of: target) else { throw Error.contactNotFound("No target found") }
            identifiers.insert(moved, at: index+1)
        } else {
            identifiers.insert(moved, at: 0)
        }
        let change = try updateContactsChange(withContactIdentifiers: identifiers)
        currentVersion = try store.addVersion(basedOnPredecessor: currentVersion, storing: [change]).identifier
    }
    
    
    // MARK: Fetch and Save in Store
    
    fileprivate func fetchContactIdentifiers(atVersionIdentifiedBy versionId: Version.Identifier) throws -> [Value.Identifier] {
        let data = try store.value(ContactBook.sharedContactBookIdentifier, prevailingAt: versionId)!.data
        let idStrings = try JSONSerialization.jsonObject(with: data, options: []) as! [String]
        return idStrings.map { Value.Identifier($0) }
    }
    
    fileprivate func fetchContacts() throws {
        let contactIds = try fetchContactIdentifiers(atVersionIdentifiedBy: currentVersion)
        self.contacts = contactIds.map { Fault<Contact>($0, prevailingAtVersion: currentVersion, in: store) }
    }
    
    fileprivate func updateContactsChange(withContactIdentifiers valueIdentifiers: [Value.Identifier]) throws -> Value.Change {
        let identifierStrings = valueIdentifiers.map { $0.identifierString }
        let data = try JSONSerialization.data(withJSONObject: identifierStrings, options: [])
        let newValue = Value(identifier: ContactBook.sharedContactBookIdentifier, version: nil, data: data)
        let update: Value.Change = .update(newValue)
        return update
    }

    
    // MARK: Sync
    
    private var isSyncing = false
    
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
            var syncMadeChanges = false
            var returnError: Swift.Error?
            switch result {
            case let .failure(error):
                returnError = error
                log.error("Failed to sync: \(error)")
            case .success:
                log.trace("Sync successful")
                if downloadedNewVersions {
                    syncMadeChanges = self.mergeHeads()
                }
            }
            DispatchQueue.main.async {
                completionHandler?(returnError)
                if syncMadeChanges {
                    NotificationCenter.default.post(name: .contactBookDidSaveSyncChanges, object: self, userInfo: nil)
                }
                
                self.isSyncing = false
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
        var versionIdentifier: Version.Identifier = currentVersion
        for otherHead in heads {
            let newVersion = try! store.merge(version: versionIdentifier, with: otherHead, resolvingWith: arbiter)
            versionIdentifier = newVersion.identifier
        }
        
        DispatchQueue.main.async {
            self.currentVersion = versionIdentifier
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
                if let v = merge.commonAncestor?.identifier {
                    contactIdsAncestor = try contactBook.fetchContactIdentifiers(atVersionIdentifiedBy: v)
                } else {
                    contactIdsAncestor = []
                }
                
                let contactIds1 = try contactBook.fetchContactIdentifiers(atVersionIdentifiedBy: merge.versions.first.identifier)
                let contactIds2 = try contactBook.fetchContactIdentifiers(atVersionIdentifiedBy: merge.versions.second.identifier)
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
