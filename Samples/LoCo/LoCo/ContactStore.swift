//
//  ContactStore.swift
//  LoCo
//
//  Created by Drew McCormack on 04/03/2026.
//

import Foundation
import LLVS
import LLVSModel
import LLVSCloudKit
import CloudKit

@MainActor @Observable
class ContactStore {
    var contacts: [Contact] = []

    private let storeCoordinator: StoreCoordinator
    @ObservationIgnored nonisolated(unsafe) private var versionTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var pollingTask: Task<Void, Never>?

    init() {
        LLVS.log.level = .verbose

        let coordinator = try! StoreCoordinator()

        let arbiter = MergeableArbiter()
        arbiter.register(Contact.self)
        coordinator.mergeArbiter = arbiter

        let container = CKContainer(identifier: "iCloud.com.mentalfaculty.loco")
        let exchange = CloudKitExchange(with: coordinator.store, storeIdentifier: "MainStore", cloudDatabaseDescription: .privateDatabaseWithCustomZone(container, zoneIdentifier: "LoCo"))
        coordinator.exchange = exchange

        self.storeCoordinator = coordinator

        contacts = fetchContacts()

        versionTask = Task { [weak self] in
            guard let self else { return }
            for await _ in coordinator.currentVersionUpdates {
                self.contacts = self.fetchContacts()
            }
        }

        startPolling()
    }

    private func fetchContacts() -> [Contact] {
        (try? storeCoordinator.fetchAllModels(Contact.self)) ?? []
    }

    func addContact() -> Contact {
        let contact = Contact()
        try! storeCoordinator.save(contact, instanceIdentifier: contact.id.uuidString)
        sync()
        return contact
    }

    func updateContact(_ contact: Contact) {
        try! storeCoordinator.save(contact, instanceIdentifier: contact.id.uuidString)
        sync()
    }

    func deleteContact(_ contact: Contact) {
        try! storeCoordinator.removeModel(Contact.self, instanceIdentifier: contact.id.uuidString)
        sync()
    }

    func sync() {
        Task {
            try? await storeCoordinator.exchange()
            storeCoordinator.merge()
        }
    }

    private func startPolling() {
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                try? await storeCoordinator.exchange()
                storeCoordinator.merge()
            }
        }
    }

    deinit {
        versionTask?.cancel()
        pollingTask?.cancel()
    }
}
