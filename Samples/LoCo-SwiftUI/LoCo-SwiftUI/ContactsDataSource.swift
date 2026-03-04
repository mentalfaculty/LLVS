//
//  ContactsDataSource.swift
//  LoCo-SwiftUI
//
//  Created by Drew McCormack on 09/07/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import Foundation
import SwiftUI
import LLVS
import LLVSCloudKit
import CloudKit

/// The data controller. Mediates between UI and data store.
@MainActor
final class ContactsDataSource: ObservableObject  {

    let storeCoordinator: StoreCoordinator

    private var versionTask: Task<Void, Never>?

    init(storeCoordinator: StoreCoordinator) {
        self.storeCoordinator = storeCoordinator
        versionTask = Task { [weak self] in
            for await versionId in storeCoordinator.currentVersionUpdates {
                self?.contacts = self?.fetchedContacts(at: versionId) ?? []
            }
        }
    }

    deinit {
        versionTask?.cancel()
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
        sync()
    }

    func update(_ contact: Contact) {
        let change: Value.Change = .update(try! contact.encodeValue())
        try! storeCoordinator.save([change])
        sync()
    }

    func deleteContact(withID id: Contact.ID) {
        let change: Value.Change = .remove(Contact.storeValueId(for: id))
        try! storeCoordinator.save([change])
        sync()

    }

    func contact(withID id: Contact.ID) -> Contact {
        return contacts.first(where: { $0.id == id }) ?? Contact()
    }

    // MARK: Syncing

    func sync() {
        Task {
            try? await storeCoordinator.exchange()
            storeCoordinator.merge()
        }
    }
}
