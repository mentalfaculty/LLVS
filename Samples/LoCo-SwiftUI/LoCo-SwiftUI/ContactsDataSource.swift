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
    
    private var contactsSubscriber: AnyCancellable?

    init(storeCoordinator: StoreCoordinator) {
        self.storeCoordinator = storeCoordinator
        contactsSubscriber = storeCoordinator.currentVersionSubject
            .receive(on: DispatchQueue.main)
            .map({ self.fetchedContacts(at: $0) })
            .assign(to: \.contacts, on: self)
    }
    
    // MARK: Contacts
    
    @Published var contacts: [Contact] = []
    
    private var identifiersOfNewContacts: Set<Contact.ID> = []
    private var identifiersOfUpdatedContacts: Set<Contact.ID> = []
    private var identifiersOfDeletedContacts: Set<Contact.ID> = []
    
    func contactBinding(for id: Contact.ID) -> Binding<Contact> {
        Binding<Contact>(
            get: { () -> Contact in
                self.contacts.first(where: { id == $0.id })!
            },
            set: { newContact in
                if let index = self.contacts.firstIndex(where: { newContact.id == $0.id }) {
                    self.identifiersOfUpdatedContacts.insert(newContact.id)
                    self.contacts[index] = newContact
                }
            }
        )
    }

    private func fetchedContacts(at version: Version.Identifier) -> [Contact] {
        return try! Contact.all(in: storeCoordinator, at: version).sorted {
            ($0.person.secondName, $0.person.firstName, $0.id.uuidString) < ($1.person.secondName, $1.person.firstName, $1.id.uuidString)
        }
    }
    
    func addNewContact() -> Contact {
        let newContact = Contact()
        contacts.append(newContact)
        identifiersOfNewContacts.insert(newContact.id)
        return newContact
    }
    
    func deleteContact(withID id: Contact.ID) {
        contacts = contacts.filter { $0.id != id }
        identifiersOfDeletedContacts.insert(id)
    }
    
    func contactIndex(forID id: Contact.ID) -> Int {
        return contacts.firstIndex(where: { $0.id == id }) ?? 0
    }
    
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
