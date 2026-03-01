//
//  Cache.swift
//  LLVS
//
//  Created by Drew McCormack on 14/05/2019.
//

import Foundation
import Synchronization

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

    private struct State {
        var generations: [Generation]
    }

    public let numberOfGenerations: Int
    public let regenerationLimit: Int

    private let state: Mutex<State>

    public init(numberOfGenerations: Int = 2, regenerationLimit: Int = 1000) {
        self.numberOfGenerations = max(1, numberOfGenerations)
        self.regenerationLimit = max(1, regenerationLimit)
        let generations: [Generation] = .init(repeating: Generation(), count: max(1, numberOfGenerations))
        self.state = Mutex(State(generations: generations))
    }

    public func setValue(_ value: ValueType, for identifier: AnyHashable) {
        state.withLock { state in
            regenerateIfNeeded(&state)
            state.generations.first![identifier] = value
        }
    }

    public func removeValue(for identifier: AnyHashable) {
        state.withLock { state in
            state.generations.forEach { generation in
                generation[identifier] = nil
            }
        }
    }

    public func value(for identifier: AnyHashable) -> ValueType? {
        state.withLock { state in
            if let generation = state.generations.first(where: { $0[identifier] != nil }) {
                let value = generation[identifier]
                state.generations.first![identifier] = value // Keep current by adding to most recent generation
                return value
            } else {
                return nil
            }
        }
    }

    public func purgeAllValues() {
        state.withLock { state in
            state.generations = .init(repeating: Generation(), count: self.numberOfGenerations)
        }
    }

    private func regenerateIfNeeded(_ state: inout State) {
        let generation = state.generations.first!
        if generation.count > regenerationLimit {
            regenerate(&state)
        }
    }

    private func regenerate(_ state: inout State) {
        let _ = state.generations.dropLast()
        state.generations.insert(Generation(), at: 0)
    }
}
