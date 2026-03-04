//
//  ContactView.swift
//  LoCo
//
//  Created by Drew McCormack on 04/03/2026.
//

import SwiftUI

struct ContactView: View {
    @Environment(ContactStore.self) var store
    let contactId: UUID

    private var contact: Contact? {
        store.contacts.first(where: { $0.id == contactId })
    }

    var body: some View {
        if var contact {
            Form {
                Section("Name") {
                    TextField("First Name", text: binding(for: \.firstName, on: &contact))
                    TextField("Last Name", text: binding(for: \.lastName, on: &contact))
                }
                Section("Address") {
                    TextField("Street", text: binding(for: \.streetAddress, on: &contact))
                    TextField("Post Code", text: binding(for: \.postCode, on: &contact))
                    TextField("City", text: binding(for: \.city, on: &contact))
                    TextField("Country", text: binding(for: \.country, on: &contact))
                }
            }
            .navigationTitle(contact.fullNameOrPlaceholder)
        } else {
            ContentUnavailableView("Contact Not Found", systemImage: "person.slash")
        }
    }

    private func binding(for keyPath: WritableKeyPath<Contact, String>, on contact: inout Contact) -> Binding<String> {
        Binding(
            get: { self.contact?[keyPath: keyPath] ?? "" },
            set: { newValue in
                if var updated = self.contact {
                    updated[keyPath: keyPath] = newValue
                    store.updateContact(updated)
                }
            }
        )
    }
}
