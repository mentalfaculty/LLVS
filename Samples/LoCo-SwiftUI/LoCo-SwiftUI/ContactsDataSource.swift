//
//  ContactsDataSource.swift
//  LoCo-SwiftUI
//
//  Created by Drew McCormack on 09/07/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import Foundation
import SwiftUI
import Combine
import LLVS
import LLVSCloudKit
import CloudKit

final class ContactsDataSource: BindableObject  {
    let didChange = PassthroughSubject<ContactsDataSource, Never>()
    
    let storeCoordinator: StoreCoordinator
    private(set) var versionAtFetch: Version.Identifier = .init()
    
    private var versionAtFetchSubscriber: AnyCancellable?
    private var contactsSubscriber: AnyCancellable?

    init(storeCoordinator: StoreCoordinator) {
        self.storeCoordinator = storeCoordinator
        let subject = storeCoordinator.currentVersionSubject.receive(on: DispatchQueue.main)
        versionAtFetchSubscriber = subject.assign(to: \.versionAtFetch, on: self)
        contactsSubscriber = subject.map({ self.fetchedContacts(at: $0) }).assign(to: \.contacts, on: self)
    }
    
    // MARK: Saving
    
    func save<T:Model>(_ modelValue: T, isNew: Bool) {
        let value = try! modelValue.encodeValue()
        let change: Value.Change = isNew ? .insert(value) : .update(value)
        try! storeCoordinator.save([change])
    }
    
    // MARK: Contacts
    
    var contacts: [Contact] = [] {
        didSet {
            didChange.send(self)
        }
    }
    
    func fetchedContacts(at version: Version.Identifier) -> [Contact] {
        return try! Contact.all(in: storeCoordinator, at: version).sorted {
            ($0.person.secondName, $0.id.uuidString) < ($1.person.secondName, $1.id.uuidString)
        }
    }
    
    // MARK: Contact Selection
    
    var selectedContactID: Contact.ID? {
        didSet {
            didChange.send(self)
        }
    }
    
    var selectedContactIndex: Int {
        contacts.firstIndex(where: { $0.id == selectedContactID }) ?? 0
    }
    
    var selectedContact: Contact? {
        contacts.first(where: { $0.id == selectedContactID })
    }
    
    // MARK: Saving
    
    func save() throws {
        // Use diff to determine what has changed since last fetch
        let storedContacts = fetchedContacts(at: versionAtFetch)
        let diff = contacts.difference(from: storedContacts)
        
        var inserted: Set<Contact.ID> = []
        var removed: Set<Contact.ID> = []
        var contactsByID: [Contact.ID:Contact] = [:]
        for diff in diff {
            switch diff {
            case let .insert(_, contact, _):
                inserted.insert(contact.id)
                contactsByID[contact.id] = contact
            case let .remove(_, contact, _):
                removed.insert(contact.id)
            }
        }
        
        // An update will appear as a remove and insert of contacts with the same id.
        let updated = inserted.intersection(removed)
        inserted.subtract(updated)
        removed.subtract(updated)
        
        // Convert to value changes for LLVS
        let updateChanges: [Value.Change] = try updated.map {
            let contact = contactsByID[$0]!
            let value = try contact.encodeValue()
            return .update(value)
        }
        let insertChanges: [Value.Change] = try inserted.map {
            let contact = contactsByID[$0]!
            let value = try contact.encodeValue()
            return .insert(value)
        }
        let deleteChanges: [Value.Change] = removed.map {
            return .remove(Contact.storeValueId(for: $0))
        }
        let changes = updateChanges + insertChanges + deleteChanges
        guard !changes.isEmpty else { return }
        
        // Store a new version
        try storeCoordinator.save(changes)
    }
    
    // MARK: Syncing
    
    func sync(executingUponCompletion completionHandler: ((Swift.Error?) -> Void)? = nil) {
        storeCoordinator.exchange { _ in
            do {
                try self.save() // Commit in view changes, so they are not "clobbered"
                self.storeCoordinator.merge()
            } catch {
                log.error("Error \(error)")
            }
        }
    }
}
