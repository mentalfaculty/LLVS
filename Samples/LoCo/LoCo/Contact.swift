//
//  Contact.swift
//  LoCo
//
//  Created by Drew McCormack on 17/01/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import Foundation
import LLVS

struct Person: Codable, Equatable {
    var firstName: String
    var secondName: String?
}

struct Address: Codable, Equatable {
    var streetName: String
    var streetNumber: Int
    var city: String
    var country: String
}

struct Contact: Equatable {
    
    var valueIdentifier: Value.Identifier
    var valueReferenceWhenLoaded: Value.Reference?
    
    var person: Person
    var address: Address?
    var age: Int?
    var email: String?
    var phoneNumber: String?
    var friends: [Identifier] = []
    
    init(with reference: Value.Reference, loadingFrom store: Store) throws {
        let container = PropertyLoader<StoreKeys>(store: store, reference: reference)
        self.person = try container.load(.person)!
        self.address = try container.load(.address)
        self.age = try container.load(.age)
        self.email = try container.load(.email)
        self.phoneNumber = try container.load(.phoneNumber)
        self.friends = try container.load(.friends)!
        self.valueIdentifier = reference.identifier
        self.valueReferenceWhenLoaded = reference
    }
    
    func changesSinceLoad(from store: Store) throws -> [Value.Change] {
        let originalContact = try valueReferenceWhenLoaded.flatMap { try Contact(with: $0, loadingFrom: store) }
        let changeGenerator = PropertyChangeGenerator<StoreKeys>(store: store, valueIdentifier: valueIdentifier)
        try changeGenerator.generate(.person, propertyValue: person, originalPropertyValue: originalContact?.person)
        try changeGenerator.generate(.address, propertyValue: address, originalPropertyValue: originalContact?.address)
        try changeGenerator.generate(.age, propertyValue: age, originalPropertyValue: originalContact?.age)
        try changeGenerator.generate(.email, propertyValue: email, originalPropertyValue: originalContact?.email)
        try changeGenerator.generate(.phoneNumber, propertyValue: phoneNumber, originalPropertyValue: originalContact?.phoneNumber)
        try changeGenerator.generate(.friends, propertyValue: friends, originalPropertyValue: originalContact?.friends)
        return changeGenerator.propertyChanges
    }
    
    struct Identifier: Equatable, Codable {
        var string: String
    }
    
    private enum StoreKeys: String, StoreKey {
        case person
        case address
        case age
        case email
        case phoneNumber
        case friends
        
        func key(forIdentifier identifier: Value.Identifier) -> String {
            return "\(identifier).Contact.\(self)"
        }
    }
}
