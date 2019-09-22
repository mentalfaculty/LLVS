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

    private func fetchedContacts(at version: Version.Identifier) -> [Contact] {
        return try! Contact.all(in: storeCoordinator, at: version).sorted {
            ($0.person.secondName, $0.person.firstName, $0.id.uuidString) < ($1.person.secondName, $1.person.firstName, $1.id.uuidString)
        }
    }
    
    func addNewContact() {
        let newContact = Contact()
        let change: Value.Change = .insert(try! newContact.encodeValue())
        try! storeCoordinator.save([change])
    }
    
    func update(_ contact: Contact) {
        let change: Value.Change = .update(try! contact.encodeValue())
        try! storeCoordinator.save([change])
    }
    
    func deleteContact(withID id: Contact.ID) {
        let change: Value.Change = .remove(Contact.storeValueId(for: id))
        try! storeCoordinator.save([change])

    }
    
    func contact(withID id: Contact.ID) -> Contact {
        return contacts.first(where: { $0.id == id }) ?? Contact()
    }
    
    // MARK: Syncing
    
    func sync(executingUponCompletion completionHandler: ((Swift.Error?) -> Void)? = nil) {
        storeCoordinator.exchange { _ in
            self.storeCoordinator.merge()
        }
    }
}
