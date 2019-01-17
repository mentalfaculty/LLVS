//
//  Contact.swift
//  LoCo
//
//  Created by Drew McCormack on 17/01/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import Foundation
import LLVS

extension Store {
    func valueCluster<KeyType: StoreKey>(_ reference: Value.Reference) -> Entity<KeyType> {
        return Entity(store: self, reference: reference)
    }
}

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
    
    struct Identifier: Equatable {
        var string: String
    }
    
    private enum StoreKeys: String, StoreKey {
        case person
        case address
        case age
        case email
        case phoneNumber
        
        func key(forIdentifier identifier: Value.Identifier) -> String {
            return "\(identifier).Contact.\(self)"
        }
    }
    
    var valueReference: Value.Reference
    
    var person: Person
    var address: Address?
    var age: Int?
    var email: String?
    var phoneNumber: String?
    
    var friends: [Identifier] = []
    
    init(with reference: Value.Reference, loadingFrom store: Store) throws {
        let cluster = Entity<StoreKeys>(store: store, reference: reference)
        self.person = try cluster.load(.person)!
        self.address = try cluster.load(.address)
        self.age = try cluster.load(.age)
        self.email = try cluster.load(.email)
        self.phoneNumber = try cluster.load(.phoneNumber)
        self.valueReference = reference
    }
    
    func changesSinceLoad(from store: Store) throws -> [Value.Change] {
        let originalContact = try Contact(with: valueReference, loadingFrom: store)
        var changes: [Value.Change] = []
        
        // Form changes by comparing values with original
//        let cluster = Entity<StoreKeys>(store: store, reference: reference)
//        if person != originalContact.person {
//            changes.append(.update(person.value))
//        }
        
        return changes
    }
}
