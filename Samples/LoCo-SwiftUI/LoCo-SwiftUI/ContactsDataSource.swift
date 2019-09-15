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

final class ContactsDataSource: ObservableObject  {
    
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
    
    // MARK: Contacts
    
    @Published var contacts: [Contact] = []
    
    private var identifiersOfNewContacts: Set<Contact.ID> = []
    private var identifiersOfUpdatedContacts: Set<Contact.ID> = []
    private var identifiersOfDeletedContacts: Set<Contact.ID> = []

    private func fetchedContacts(at version: Version.Identifier) -> [Contact] {
        return try! Contact.all(in: storeCoordinator, at: version).sorted {
            ($0.person.secondName, $0.person.firstName, $0.id.uuidString) < ($1.person.secondName, $0.person.firstName, $1.id.uuidString)
        }
    }
    
    func binding(forContactWithID id: Contact.ID) -> Binding<Contact> {
        return Binding<Contact>(
            get: { () -> Contact in
                return self.contacts.first(where: { $0.id == id }) ?? Contact()
            },
            set: { newContact in
                self.identifiersOfUpdatedContacts.insert(newContact.id)
                self.contacts = self.contacts.map { oldContact in
                    if oldContact.id == newContact.id {
                        return newContact
                    }
                    return oldContact
                }
            }
        )
    }
    
//    // MARK: Contact Selection
//
//    @Published var selectedContactID: Contact.ID?
//
//    var selectedContactIndex: Int {
//        contacts.firstIndex(where: { $0.id == selectedContactID }) ?? 0
//    }
//
//    var selectedContact: Contact? {
//        contacts.first(where: { $0.id == selectedContactID })
//    }
    
    // MARK: Saving
    
    func save() throws {
        identifiersOfUpdatedContacts.subtract(identifiersOfNewContacts)
        identifiersOfUpdatedContacts.subtract(identifiersOfDeletedContacts)
        identifiersOfNewContacts.subtract(identifiersOfDeletedContacts)
                
        let inserts: [Value.Change] = try contacts
            .filter { identifiersOfNewContacts.contains($0.id) }
            .map { .insert(try $0.encodeValue()) }
        let updates: [Value.Change] = try contacts
            .filter { identifiersOfUpdatedContacts.contains($0.id) }
            .map { .update(try $0.encodeValue()) }
        let deletes: [Value.Change] = identifiersOfDeletedContacts
            .map { .remove(Contact.storeValueId(for: $0)) }
        
        identifiersOfNewContacts.removeAll()
        identifiersOfDeletedContacts.removeAll()
        identifiersOfUpdatedContacts.removeAll()
        
        let changes = updates + inserts + deletes
        guard !changes.isEmpty else { return }

        try storeCoordinator.save(changes)
    }
    
//    func save<T:Model>(_ modelValue: T, isNew: Bool) {
//        let value = try! modelValue.encodeValue()
//        let change: Value.Change = isNew ? .insert(value) : .update(value)
//        try! storeCoordinator.save([change])
//    }
    
//    func save() throws {
//        // Use diff to determine what has changed since last fetch
//        let storedContacts = fetchedContacts(at: versionAtFetch)
//        let diff = contacts.difference(from: storedContacts)
//
//        var inserted: Set<Contact.ID> = []
//        var removed: Set<Contact.ID> = []
//        var contactsByID: [Contact.ID:Contact] = [:]
//        for diff in diff {
//            switch diff {
//            case let .insert(_, contact, _):
//                inserted.insert(contact.id)
//                contactsByID[contact.id] = contact
//            case let .remove(_, contact, _):
//                removed.insert(contact.id)
//            }
//        }
//
//        // An update will appear as a remove and insert of contacts with the same id.
//        let updated = inserted.intersection(removed)
//        inserted.subtract(updated)
//        removed.subtract(updated)
//
//        // Convert to value changes for LLVS
//        let updateChanges: [Value.Change] = try updated.map {
//            let contact = contactsByID[$0]!
//            let value = try contact.encodeValue()
//            return .update(value)
//        }
//        let insertChanges: [Value.Change] = try inserted.map {
//            let contact = contactsByID[$0]!
//            let value = try contact.encodeValue()
//            return .insert(value)
//        }
//        let deleteChanges: [Value.Change] = removed.map {
//            return .remove(Contact.storeValueId(for: $0))
//        }
//        let changes = updateChanges + insertChanges + deleteChanges
//        guard !changes.isEmpty else { return }
//
//        // Store a new version
//        try storeCoordinator.save(changes)
//    }
    
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
