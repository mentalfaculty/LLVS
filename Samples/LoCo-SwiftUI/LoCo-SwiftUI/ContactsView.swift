//
//  ContactsView.swift
//  LoCo-SwiftUI
//
//  Created by Drew McCormack on 05/06/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import SwiftUI
import UIKit

struct ContactsView : View {
    
    @EnvironmentObject var dataSource: ContactsDataSource
    
    var body: some View {
        NavigationView {
            List(dataSource.contacts) { contact in
                NavigationLink(destination: ContactView(contact: self.dataSource.binding(forContactWithID: contact.id))) {
                    HStack {
                        Image(uiImage: contact.avatarJPEGData.flatMap({ UIImage(data:$0) }) ?? UIImage(named: "Placeholder")!)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(6.0)
                            .frame(width: 50, height: 50, alignment: .center)
                        VStack(alignment: .leading) {
                            Text(contact.person.fullName)
                                .font(.headline)
                                .foregroundColor(.primary)
                        }
                    }
                }
            }
            .navigationBarTitle(Text("Contacts"))
        }
    }
    
}

struct ContactsViewPreview : PreviewProvider {
    static var previews: some View {
        ContactsView()
    }
}
