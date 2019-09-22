//
//  Contact.swift
//  LoCo-SwiftUI
//
//  Created by Drew McCormack on 09/07/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import Foundation
import SwiftUI
import LLVS

/// The main model type. It conforms to Model, which includes Codable.
struct Contact: Model {
    static let storeIdentifierTypeTag = "Contact"
    var id: UUID = .init()
    var person: Person = .init()
    var address: Address = .init()
    var avatarJPEGData: Data?
}

/// Person is embedded in Contact, and so not a Model type. It is just Codable.
struct Person: Codable, Equatable {
    var firstName: String = ""
    var secondName: String = ""
    
    var fullName: String {
        switch (firstName.isEmpty, secondName.isEmpty) {
        case (true, true):
            return ""
        case (true, false):
            return secondName
        case (false, true):
            return firstName
        case (false, false):
            return "\(firstName) \(secondName)"
        }
    }
    
    var fullNameOrPlaceholder: String {
        fullName.isEmpty ? "New Contact" : fullName
    }
    
    init(firstName: String = "", secondName: String = "") {
        self.firstName = firstName
        self.secondName = secondName
    }
}

/// Address is also embedded, so only Codable.
struct Address: Codable, Equatable {
    var streetAddress: String = ""
    var postCode: String = ""
    var city: String = ""
    var country: String = ""
    
    init(streetAddress: String = "", postCode: String = "", city: String = "", country: String = "") {
        self.streetAddress = streetAddress
        self.postCode = postCode
        self.city = city
        self.country = country
    }
}

