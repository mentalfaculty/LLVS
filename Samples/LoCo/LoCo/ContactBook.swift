//
//  ContactBook.swift
//  LoCo
//
//  Created by Drew McCormack on 20/01/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import Foundation
import LLVS

extension Notification.Name {
    static let contactBookVersionDidChange = Notification.Name("contactBookVersionDidChange")
}

final class ContactBook {
    
    let store: Store
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
        currentVersion = version
        try fetchContacts()
    }
    
    init(creatingIn store: Store) throws {
        self.store = store
        currentVersion = try store.addVersion(basedOnPredecessor: nil, storing: []).identifier
    }
    
    func add(_ contact: Contact) throws {
        var valueIdentifiers = contacts.map { $0.valueIdentifier }
        valueIdentifiers.append(contact.valueIdentifier)
        
        let contact = Contact()
        let insertChanges = try contact.changesSinceLoad(from: store)
        let changes = insertChanges + [try updateContactsChange(withContactIdentifiers: valueIdentifiers)]
            
        currentVersion = try store.addVersion(basedOnPredecessor: currentVersion, storing: changes).identifier
        
        try fetchContacts()
    }
    
    func delete(_ contact: Contact) throws {
        var valueIdentifiers = contacts.map { $0.valueIdentifier }
        let index = valueIdentifiers.firstIndex(of: contact.valueIdentifier)!
        valueIdentifiers.remove(at: index)
        
        let removal: Value.Change = .remove(contact.valueIdentifier)
        let changes = [removal, try updateContactsChange(withContactIdentifiers: valueIdentifiers)]
        currentVersion = try store.addVersion(basedOnPredecessor: currentVersion, storing: changes).identifier
        
        try fetchContacts()
    }
    
    private func fetchContacts() throws {
        let data = try store.value(ContactBook.sharedIdentifier, prevailingAt: currentVersion)!.data
        let contactIds = try JSONSerialization.jsonObject(with: data, options: []) as! [Value.Identifier]
        self.contacts = contactIds.map { Fault<Contact>($0, prevailingAtVersion: currentVersion, in: store) }
    }
    
    private func updateContactsChange(withContactIdentifiers valueIdentifiers: [Value.Identifier]) throws -> Value.Change {
        let data = try JSONSerialization.data(withJSONObject: valueIdentifiers, options: [])
        let newValue = Value(identifier: ContactBook.sharedIdentifier, version: nil, data: data)
        let update: Value.Change = .update(newValue)
        return update
    }

}
