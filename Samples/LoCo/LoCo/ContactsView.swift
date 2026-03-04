//
//  ContactsView.swift
//  LoCo
//
//  Created by Drew McCormack on 04/03/2026.
//

import SwiftUI

struct ContactsView: View {
    @Environment(ContactStore.self) var store

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.contacts.sorted(by: { $0.fullNameOrPlaceholder < $1.fullNameOrPlaceholder })) { contact in
                    NavigationLink(value: contact.id) {
                        VStack(alignment: .leading) {
                            Text(contact.fullNameOrPlaceholder)
                                .font(.headline)
                            if !contact.city.isEmpty {
                                Text(contact.city)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete(perform: deleteContacts)
            }
            .navigationTitle("Contacts")
            .navigationDestination(for: UUID.self) { contactId in
                ContactView(contactId: contactId)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        _ = store.addContact()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    private func deleteContacts(at offsets: IndexSet) {
        let sorted = store.contacts.sorted(by: { $0.fullNameOrPlaceholder < $1.fullNameOrPlaceholder })
        for index in offsets {
            store.deleteContact(sorted[index])
        }
    }
}
