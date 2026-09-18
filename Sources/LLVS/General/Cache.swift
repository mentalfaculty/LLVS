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
public final class Cache<ValueType: Sendable>: Sendable {

    /// A type-erased key. Like `AnyHashable`, but it carries the promise that the key is `Sendable`.
    private struct Key: Hashable, @unchecked Sendable {
        private let base: AnyHashable
        init(_ base: some Hashable & Sendable) { self.base = AnyHashable(base) }
    }

    // A struct, so that the compiler can see that nothing escapes the lock
    private struct Generation: Sendable {
        private var valuesByIdentifier: [Key:ValueType] = [:]

        subscript(id: Key) -> ValueType? {
            get { valuesByIdentifier[id] }
            set { valuesByIdentifier[id] = newValue }
        }

        var count: Int { return valuesByIdentifier.count }
    }

    private struct State: Sendable {
        var generations: [Generation]
    }

    public let numberOfGenerations: Int
    public let regenerationLimit: Int

    private let state: Mutex<State>

    public init(numberOfGenerations: Int = 2, regenerationLimit: Int = 1000) {
        self.numberOfGenerations = max(1, numberOfGenerations)
        self.regenerationLimit = max(1, regenerationLimit)
        let generations = (0..<max(1, numberOfGenerations)).map { _ in Generation() }
        self.state = Mutex(State(generations: generations))
    }

    public func setValue(_ value: ValueType, for identifier: some Hashable & Sendable) {
        state.withLock { state in
            regenerateIfNeeded(&state)
            state.generations[0][Key(identifier)] = value
        }
    }

    public func removeValue(for identifier: some Hashable & Sendable) {
        state.withLock { state in
            for i in state.generations.indices {
                state.generations[i][Key(identifier)] = nil
            }
        }
    }

    public func value(for identifier: some Hashable & Sendable) -> ValueType? {
        state.withLock { state in
            guard let value = state.generations.lazy.compactMap({ $0[Key(identifier)] }).first else { return nil }
            state.generations[0][Key(identifier)] = value // Keep current by adding to most recent generation
            return value
        }
    }

    public func purgeAllValues() {
        state.withLock { state in
            state.generations = (0..<self.numberOfGenerations).map { _ in Generation() }
        }
    }

    private func regenerateIfNeeded(_ state: inout State) {
        if state.generations[0].count > regenerationLimit {
            regenerate(&state)
        }
    }

    private func regenerate(_ state: inout State) {
        state.generations.removeLast()
        state.generations.insert(Generation(), at: 0)
    }
}
