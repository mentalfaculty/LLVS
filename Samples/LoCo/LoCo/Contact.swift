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

    var fullName: String {
        var result = firstName
        if let s = secondName {
            result += " \(s)"
        }
        return result
    }
    
    init(firstName: String, secondName: String?) {
        self.firstName = firstName
        self.secondName = secondName
    }
}

struct Address: Codable, Equatable {
    var streetAddress: String
    var postCode: String?
    var city: String?
    var country: String?
    
    init(streetAddress: String, postCode: String?, city: String?, country: String?) {
        self.streetAddress = streetAddress
        self.postCode = postCode
        self.city = city
        self.country = country
    }
}

struct Contact: Equatable, Faultable {
    
    var valueIdentifier: Value.Identifier
    var prevailingVersionWhenLoaded: Version.Identifier?
    
    var person: Person?
    var address: Address?
    var email: String?
    var phoneNumber: String?
    var friends: [Value.Identifier] = []
    
    init() {
        valueIdentifier = .init(UUID().uuidString)
    }
    
    init(_ valueIdentifier: Value.Identifier, prevailingAt version: Version.Identifier, loadingFrom store: Store) throws {
        let loader = PropertyLoader<StoreKeys>(store: store, valueIdentifier: valueIdentifier, prevailingVersion: version)
        self.person = try loader.load(.person)
        self.address = try loader.load(.address)
        self.email = try loader.load(.email)
        self.phoneNumber = try loader.load(.phoneNumber)
        self.friends = try loader.load(.friends)!
        self.valueIdentifier = valueIdentifier
        self.prevailingVersionWhenLoaded = version
    }
    
    func changesSinceLoad(from store: Store) throws -> [Value.Change] {
        let originalContact = try prevailingVersionWhenLoaded.flatMap { try Contact(valueIdentifier, prevailingAt: $0, loadingFrom: store) }
        let changeGenerator = PropertyChangeGenerator<StoreKeys>(store: store, valueIdentifier: valueIdentifier)
        try changeGenerator.generate(.person, propertyValue: person, originalPropertyValue: originalContact?.person)
        try changeGenerator.generate(.address, propertyValue: address, originalPropertyValue: originalContact?.address)
        try changeGenerator.generate(.email, propertyValue: email, originalPropertyValue: originalContact?.email)
        try changeGenerator.generate(.phoneNumber, propertyValue: phoneNumber, originalPropertyValue: originalContact?.phoneNumber)
        try changeGenerator.generate(.friends, propertyValue: friends, originalPropertyValue: originalContact?.friends)
        return changeGenerator.propertyChanges
    }
    
    private enum StoreKeys: String, StoreKey {
        case person
        case address
        case email
        case phoneNumber
        case friends
        
        func key(forIdentifier identifier: Value.Identifier) -> String {
            return "\(identifier.identifierString).Contact.\(self)"
        }
    }
}
