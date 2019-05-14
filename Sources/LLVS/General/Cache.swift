//
//  Cache.swift
//  LLVS
//
//  Created by Drew McCormack on 14/05/2019.
//

import Foundation

/// Generational cache. Fills up each generation to a limit, then discards oldest creating a new generation.
/// When you retrieve a value, it automatically adds that value to the newest generation, to keep it around.
/// Creating generations is based on the number of values in the latest generation, not on time or data size.
public final class Cache<ValueType> {
    
    private class Generation {
        private var valuesByIdentifier: [AnyHashable:ValueType] = [:]
        
        subscript(id: AnyHashable) -> ValueType? {
            get {
                return valuesByIdentifier[id]
            }
            set(newValue) {
                valuesByIdentifier[id] = newValue
            }
        }
        
        var count: Int { return valuesByIdentifier.count }
    }
    
    public let numberOfGenerations: Int
    public let regenerationLimit: Int
    
    private var generations: [Generation] = []
    
    public init(numberOfGenerations: Int = 2, regenerationLimit: Int = 1000) {
        self.numberOfGenerations = max(1, numberOfGenerations)
        self.regenerationLimit = max(1, regenerationLimit)
        generations = .init(repeating: Generation(), count: self.numberOfGenerations)
    }
    
    public func setValue(_ value: ValueType, for identifier: AnyHashable) {
        regenerateIfNeeded()
        generations.first![identifier] = value
    }
    
    public func removeValue(for identifier: AnyHashable) {
        generations.forEach { generation in
            generation[identifier] = nil
        }
    }
    
    public func value(for identifier: AnyHashable) -> ValueType? {
        if let generation = generations.first(where: { $0[identifier] != nil }) {
            let value = generation[identifier]
            generations.first![identifier] = value // Keep current by adding to most recent generation
            return value
        } else {
            return nil
        }
    }
    
    public func purgeAllValues() {
        generations = .init(repeating: Generation(), count: self.numberOfGenerations)
    }
    
    private func regenerateIfNeeded() {
        let generation = generations.first!
        if generation.count > regenerationLimit {
            regenerate()
        }
    }
    
    private func regenerate() {
        let _ = generations.dropLast()
        generations.insert(Generation(), at: 0)
    }
}
