//
//  ContactView.swift
//  LoCo-SwiftUI
//
//  Created by Drew McCormack on 15/09/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import SwiftUI

struct ContactView: View {
    @Binding var contact: Contact

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Name")) {
                    TextField("First Name", text: $contact.person.firstName)
                    TextField("Last Name", text: $contact.person.secondName)
                }
                Section(header: Text("Address")) {
                    TextField("Street Address", text: $contact.address.streetAddress)
                    TextField("Postcode", text: $contact.address.postCode)
                    TextField("City", text: $contact.address.city)
                    TextField("Country", text: $contact.address.country)
                }
            }
            .navigationBarTitle(Text("Contact"))
        }
    }
}

struct ContactViewPreview: PreviewProvider {
    static var previews: some View {
        let contact = Contact()
        return ContactView(contact: .constant(contact))
    }
}
