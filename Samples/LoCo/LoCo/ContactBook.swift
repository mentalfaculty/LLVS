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
    static let contactBookVersionDidChange = Notification.Name("contactBookVersionDidChange")
}

final class ContactBook {

    enum Error: Swift.Error {
        case contactNotFound(String)
    }
    
    let store: Store
    let cloudKitExchange: CloudKitExchange
    private(set) var contacts: [Fault<Contact>] = []
    
    private static let sharedIdentifier: Value.Identifier = .init("ContactBook")
    
    var currentVersion: Version.Identifier {
        didSet {
            try! fetchContacts()
            NotificationCenter.default.post(name: .contactBookVersionDidChange, object: self)
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
        let newValue = Value(identifier: ContactBook.sharedIdentifier, version: nil, data: emptyArrayData)
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
    
    private func fetchContacts() throws {
        let data = try store.value(ContactBook.sharedIdentifier, prevailingAt: currentVersion)!.data
        let idStrings = try JSONSerialization.jsonObject(with: data, options: []) as! [String]
        let contactIds = idStrings.map { Value.Identifier($0) }
        self.contacts = contactIds.map { Fault<Contact>($0, prevailingAtVersion: currentVersion, in: store) }
    }
    
    private func updateContactsChange(withContactIdentifiers valueIdentifiers: [Value.Identifier]) throws -> Value.Change {
        let identifierStrings = valueIdentifiers.map { $0.identifierString }
        let data = try JSONSerialization.data(withJSONObject: identifierStrings, options: [])
        let newValue = Value(identifier: ContactBook.sharedIdentifier, version: nil, data: data)
        let update: Value.Change = .update(newValue)
        return update
    }

    
    // MARK: Sync
    
    func sync() {
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
            switch result {
            case let .failure(error):
                NSLog("Failed to sync: \(error)")
            case .success:
                NSLog("Sync successful")
                if downloadedNewVersions {
                    self.mergeHeads()
                }
            }
        }
    }
    
    func mergeHeads() {
        var heads: Set<Version.Identifier> = []
        store.queryHistory { history in
            heads = history.headIdentifiers
        }
        heads.remove(currentVersion)
        
        let arbiter = ContactMergeArbiter()
        var versionIdentifier: Version.Identifier = currentVersion
        for otherHead in heads {
            let newVersion = try! store.merge(version: versionIdentifier, with: otherHead, resolvingWith: arbiter)
            versionIdentifier = newVersion.identifier
        }
        
        DispatchQueue.main.async {
            self.currentVersion = versionIdentifier
        }
    }

}

class ContactMergeArbiter: MergeArbiter {
    
    func changes(toResolve merge: Merge, in store: Store) throws -> [Value.Change] {
        let defaultArbiter = MostRecentChangeFavoringArbiter()
        return []
    }
    
}
