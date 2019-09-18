//
//  ContactCell.swift
//  LoCo-SwiftUI
//
//  Created by Drew McCormack on 18/09/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import SwiftUI

struct ContactCell: View {
    @Binding var contact: Contact
    var body: some View {
        NavigationLink(destination: ContactView(contact: $contact)) {
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

struct ContactCellPreview: PreviewProvider {
    static var previews: some View {
        ContactCell(contact: .constant(Contact()))
    }
}
