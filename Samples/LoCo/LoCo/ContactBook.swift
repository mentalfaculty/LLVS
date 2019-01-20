//
//  ContactBook.swift
//  LoCo
//
//  Created by Drew McCormack on 20/01/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import Foundation
import LLVS

struct Fault<ValueType> {
    enum State {
        case fault
        case fetched(ValueType)
    }
    var valueReference: Value.Reference
    var state: State
}

class ContactBook {
    
    var contacts: [Fault<Contact>] = []
    
    init?(loadingFrom store: Store, atVersion versionIdentifier: Version.Identifier) throws {
        if let data = try store.value(.init("ContactBook"), prevailingAt: versionIdentifier)?.data,
            let contactIds = try JSONSerialization.jsonObject(with: data, options: []) as? [Contact.Identifier] {
            self.contacts = contactIds.map { Fault<Contact>($0) }
        } else {
            return nil
        }
    }
    
    func save(in store: Store) throws {
        let data = try JSONSerialization.data(withJSONObject: contacts, options: [])
    }

}
