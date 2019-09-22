//
//  ContactView.swift
//  LoCo-SwiftUI
//
//  Created by Drew McCormack on 15/09/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import SwiftUI

/// Detail view for a Contact
struct ContactView: View {
    @EnvironmentObject var dataSource: ContactsDataSource
    var contactID: Contact.ID
    
    /// Binding used to track edits. When a field is edited, it triggers an update
    /// to this binding, which passes the change directly to the data source, and thus
    /// the store
    private var contact: Binding<Contact> {
        Binding<Contact>(
            get: { () -> Contact in
                self.dataSource.contact(withID: self.contactID)
            },
            set: { newContact in
                self.dataSource.update(newContact)
            }
        )
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Name")) {
                    TextField("First Name", text: contact.person.firstName)
                    TextField("Last Name", text: contact.person.secondName)
                }
                Section(header: Text("Address")) {
                    TextField("Street Address", text: contact.address.streetAddress)
                    TextField("Postcode", text: contact.address.postCode)
                    TextField("City", text: contact.address.city)
                    TextField("Country", text: contact.address.country)
                }
            }
            .navigationBarTitle(Text("Contact"))
        }
    }
}

