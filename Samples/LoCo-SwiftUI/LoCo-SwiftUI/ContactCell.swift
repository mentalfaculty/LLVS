//
//  ContactCell.swift
//  LoCo-SwiftUI
//
//  Created by Drew McCormack on 18/09/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import SwiftUI

/// Cell used in the main contacts list. When tapped, it pushes
/// the ContactView to edit the Contact
struct ContactCell: View {
    @EnvironmentObject var dataSource: ContactsDataSource
    var contactID: Contact.ID
    var contact: Contact { dataSource.contact(withID: contactID) }

    var body: some View {
        NavigationLink(
            destination:
                ContactView(contactID: contactID)
                    .environmentObject(dataSource)
        ) {
            HStack {
                Thumbnail(contact: contact)
                VStack(alignment: .leading) {
                    Text(contact.person.fullNameOrPlaceholder)
                        .font(.headline)
                        .foregroundColor(.primary)
                }
            }
        }
    }
}

struct Thumbnail: View {
    var contact: Contact
    var body: some View {
        var image: Image
        if let data = contact.avatarJPEGData {
            image = Image(uiImage: UIImage(data:data)!)
        } else {
            image = Image(systemName: "person.crop.rectangle.fill")
        }
        return image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .cornerRadius(4.0)
            .frame(width: 40, height: 40, alignment: .center)
            .foregroundColor(.green)
    }
}
