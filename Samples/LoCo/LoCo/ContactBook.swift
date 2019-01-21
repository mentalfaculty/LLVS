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

class ContactBook {
    
    let store: Store
    private(set) var contacts: [Fault<Contact>] = []
    
    var currentVersion: Version.Identifier {
        didSet {
            NotificationCenter.default.post(name: .contactBookVersionDidChange, object: self)
        }
    }
    
    required init?(_ valueIdentifier: Value.Identifier, prevailingAt version: Version.Identifier, loadingFrom store: Store) throws {
        self.store = store
        self.currentVersion = version
        try fetchContacts()
    }
    
    func add(_ contact: Contact) throws {
        var valueIdentifiers = contacts.map { $0.valueIdentifier }
        valueIdentifiers.append(contact.valueIdentifier)
        let data = try JSONSerialization.data(withJSONObject: valueIdentifiers, options: [])
        let newValue = Value(identifier: .init("ContactBook"), version: nil, data: data)
        let update: Value.Change = .update(newValue)
        
        let contact = Contact()
        let insertChanges = try contact.changesSinceLoad(from: store)
        
        currentVersion = try store.addVersion(basedOnPredecessor: currentVersion, storing: insertChanges + [update]).identifier
        
        try fetchContacts()
    }
    
    func fetchContacts() throws {
        let data = try store.value(.init("ContactBook"), prevailingAt: currentVersion)!.data
        let contactIds = try JSONSerialization.jsonObject(with: data, options: []) as! [Value.Identifier]
        self.contacts = contactIds.map { Fault<Contact>($0, prevailingAtVersion: currentVersion, in: store) }
    }
    
    func delete(_ contact: Contact) throws {
        
    }

}
