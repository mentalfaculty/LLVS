//
//  ContactsView.swift
//  LoCo-SwiftUI
//
//  Created by Drew McCormack on 05/06/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import SwiftUI
import UIKit

/// A list of contacts.
struct ContactsView : View {
    @EnvironmentObject var dataSource: ContactsDataSource
    
    private func thumbnail(for contact: Contact) -> Image {
        if let data = contact.avatarJPEGData {
            return Image(uiImage: UIImage(data:data)!)
        } else {
            return Image(systemName: "person.crop.rectangle.fill")
        }
    }
    
    var body: some View {
        NavigationView {
            List {
                ForEach(dataSource.contacts) { contact in
                    ContactCell(contactID: contact.id)
                        .environmentObject(self.dataSource)
                }.onDelete { indices in
                    indices.forEach {
                        self.dataSource.deleteContact(withID: self.dataSource.contacts[$0].id)
                    }
                }
            }
            .navigationBarTitle(Text("Contacts"))
            .navigationBarItems(
                leading: EditButton(),
                trailing: Button(
                    action: {
                        withAnimation {
                            self.dataSource.addNewContact()
                        }
                    }
                ) {
                    Image(systemName: "plus.circle.fill")
                }
            )
        }
    }
}

struct ContactsViewPreview : PreviewProvider {
    static var previews: some View {
        ContactsView()
    }
}
