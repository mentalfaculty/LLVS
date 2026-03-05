//
//  Contact.swift
//  LoCo
//
//  Created by Drew McCormack on 04/03/2026.
//

import Foundation
import LLVS
import LLVSModel

@MergeableModel
struct Contact: StorableModel, Equatable, Identifiable, Codable {
    static let modelTypeIdentifier = "Contact"
    var id: UUID = .init()
    var firstName: String = ""
    var lastName: String = ""
    var streetAddress: String = ""
    var postCode: String = ""
    var city: String = ""
    var country: String = ""
    var avatarJPEGData: Data?

    var fullName: String {
        switch (firstName.isEmpty, lastName.isEmpty) {
        case (true, true):
            return ""
        case (true, false):
            return lastName
        case (false, true):
            return firstName
        case (false, false):
            return "\(firstName) \(lastName)"
        }
    }

    var fullNameOrPlaceholder: String {
        fullName.isEmpty ? "New Contact" : fullName
    }
}
