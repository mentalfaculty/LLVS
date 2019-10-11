//
//  Entity.swift
//  LoCo
//
//  Created by Drew McCormack on 17/01/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import Foundation
import LLVS

fileprivate var encoder: JSONEncoder = .init()
fileprivate var decoder: JSONDecoder = .init()

class PropertyLoader<KeyType: StoreKey> {
    let store: Store
    let valueId: Value.Identifier
    let prevailingVersion: Version.Identifier
    
    init(store: Store, valueId: Value.Identifier, prevailingVersion: Version.Identifier) {
        self.store = store
        self.valueId = valueId
        self.prevailingVersion = prevailingVersion
    }
    
    func load<PropertyType: Codable>(_ storeKey: KeyType) throws -> PropertyType? {
        let key = storeKey.key(forIdentifier: valueId)
        guard let value = try store.value(withId: .init(key), at: prevailingVersion) else { return nil }
        let array = try decoder.decode([PropertyType].self, from: value.data) // Properties are in array to please JSON
        return array.first
    }
}

class PropertyChangeGenerator<KeyType: StoreKey> {
    let store: Store
    let valueId: Value.Identifier
    var propertyChanges: [Value.Change] = []
    
    init(store: Store, valueId: Value.Identifier) {
        self.store = store
        self.valueId = valueId
    }
    
    func generate<PropertyType: Codable & Equatable>(_ storeKey: KeyType, propertyValue: PropertyType?, originalPropertyValue: PropertyType?) throws {
        let key = storeKey.key(forIdentifier: valueId)
        guard propertyValue != originalPropertyValue else { return }
        if let propertyValue = propertyValue {
            let data = try encoder.encode([propertyValue]) // Wrap properties in array to please JSON encoding. Requires array or dict root.
            let value = Value(id: .init(key), data: data)
            let change: Value.Change = originalPropertyValue == nil ? .insert(value) : .update(value)
            propertyChanges.append(change)
        } else if originalPropertyValue != nil {
            let change: Value.Change = .remove(.init(key))
            propertyChanges.append(change)
        }
    }
}

protocol StoreKey {
    func key(forIdentifier identifier: Value.Identifier) -> String
}

extension Store {
    func valueContainer<KeyType: StoreKey>(_ valueId: Value.Identifier, prevailingVersion: Version.Identifier) -> PropertyLoader<KeyType> {
        return PropertyLoader(store: self, valueId: valueId, prevailingVersion: prevailingVersion)
    }
}
