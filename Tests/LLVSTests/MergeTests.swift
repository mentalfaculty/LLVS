//
//  MergeTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 12/01/2019.
//

import Testing
import Foundation
@testable import LLVS

@Suite class MergeTests {

    let fm = FileManager.default

    let store: Store
    let rootURL: URL
    let valuesURL: URL
    let originalVersion: Version
    var branch1: Version
    var branch2: Version
    let originalValue: Value
    let newValue1: Value
    let newValue2: Value

    var valueForMerge: Value?

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        valuesURL = rootURL.appendingPathComponent("values")
        store = try Store(rootDirectoryURL: rootURL)

        originalValue = Value(id: .init("ABCDEF"), data: "Bob".data(using: .utf8)!)
        let changes: [Value.Change] = [.insert(originalValue)]
        originalVersion = try store.makeVersion(basedOn: nil, storing: changes)

        newValue1 = Value(id: .init("ABCDEF"), data: "Tom".data(using: .utf8)!)
        let changes1: [Value.Change] = [.insert(newValue1)]
        let predecessors: Version.Predecessors = .init(idOfFirst: originalVersion.id, idOfSecond: nil)
        branch1 = try store.makeVersion(basedOn: predecessors, storing: changes1)

        newValue2 = Value(id: .init("ABCDEF"), data: "Jerry".data(using: .utf8)!)
        let changes2: [Value.Change] = [.insert(newValue2)]
        branch2 = try store.makeVersion(basedOn: predecessors, storing: changes2)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    @Test func unresolvedMergeFails() {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                #expect(merge.forksByValueIdentifier.count == 1)
                return []
            }
        }
        #expect(throws: (any Error).self) { try store.mergeRelated(version: branch1.id, with: branch2.id, resolvingWith: Arbiter()) }
    }

    @Test func resolvedMergeSucceeds() throws {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                let value = Value(id: .init("ABCDEF"), data: "Jack".data(using: .utf8)!)
                return [.insert(value)]
            }
        }
        _ = try store.mergeRelated(version: branch1.id, with: branch2.id, resolvingWith: Arbiter())
    }

    @Test func incompletelyResolvedMergeFails() {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                let value = Value(id: .init("CDEDEF"), data: "Jack".data(using: .utf8)!)
                return [.insert(value)]
            }
        }
        #expect(throws: (any Error).self) { try store.mergeRelated(version: branch1.id, with: branch2.id, resolvingWith: Arbiter()) }
    }

    @Test func preserve() throws {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                let fork = merge.forksByValueIdentifier[.init("ABCDEF")]
                #expect(fork == .twiceUpdated)
                let firstValue = try! store.value(id: .init("ABCDEF"), at: merge.versions.first.id)!
                return [.preserve(firstValue.reference!)]
            }
        }
        let mergeVersion = try store.mergeRelated(version: branch1.id, with: branch2.id, resolvingWith: Arbiter())
        let mergeValue = try store.value(id: .init("ABCDEF"), at: mergeVersion.id)!
        #expect(mergeValue.data == "Tom".data(using: .utf8)!)
    }

    @Test func asymmetricBranchPreserve() throws {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                let fork = merge.forksByValueIdentifier[.init("ABCDEF")]
                #expect(fork == .twiceUpdated)
                let firstValue = try! store.value(id: .init("ABCDEF"), at: merge.versions.second.id)!
                return [.preserve(firstValue.reference!)]
            }
        }

        let predecessors: Version.Predecessors = .init(idOfFirst: branch2.id, idOfSecond: nil)
        let newValue = Value(id: .init("ABCDEF"), data: "Pete".data(using: .utf8)!)
        branch2 = try store.makeVersion(basedOn: predecessors, storing: [.update(newValue)])

        let mergeVersion = try store.mergeRelated(version: branch1.id, with: branch2.id, resolvingWith: Arbiter())
        let mergeValue = try store.value(id: .init("ABCDEF"), at: mergeVersion.id)!
        #expect(mergeValue.data == "Pete".data(using: .utf8)!)
    }

    @Test func remove() throws {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                let fork = merge.forksByValueIdentifier[.init("ABCDEF")]
                #expect(fork == .removedAndUpdated(removedOn: .second))
                return [.preserveRemoval(.init("ABCDEF"))]
            }
        }

        let predecessors: Version.Predecessors = .init(idOfFirst: branch2.id, idOfSecond: nil)
        branch2 = try store.makeVersion(basedOn: predecessors, storing: [.remove(.init("ABCDEF"))])

        let mergeVersion = try store.mergeRelated(version: branch1.id, with: branch2.id, resolvingWith: Arbiter())
        let mergeValue = try store.value(id: .init("ABCDEF"), at: mergeVersion.id)
        #expect(mergeValue == nil)
    }

    @Test func twiceRemoved() throws {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                let fork = merge.forksByValueIdentifier[.init("ABCDEF")]
                #expect(fork == .twiceRemoved)
                return [.preserveRemoval(.init("ABCDEF"))]
            }
        }

        let predecessors1: Version.Predecessors = .init(idOfFirst: branch1.id, idOfSecond: nil)
        branch1 = try store.makeVersion(basedOn: predecessors1, storing: [.remove(.init("ABCDEF"))])

        let predecessors2: Version.Predecessors = .init(idOfFirst: branch2.id, idOfSecond: nil)
        branch2 = try store.makeVersion(basedOn: predecessors2, storing: [.remove(.init("ABCDEF"))])

        let mergeVersion = try store.mergeRelated(version: branch1.id, with: branch2.id, resolvingWith: Arbiter())
        let mergeValue = try store.value(id: .init("ABCDEF"), at: mergeVersion.id)
        #expect(mergeValue == nil)
    }

    @Test func twiceUpdated() throws {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                let fork = merge.forksByValueIdentifier[.init("ABCDEF")]
                #expect(fork == .twiceUpdated)
                let secondValue = try! store.value(id: .init("ABCDEF"), at: merge.versions.second.id)!
                return [.preserve(secondValue.reference!)]
            }
        }

        let predecessors1: Version.Predecessors = .init(idOfFirst: branch1.id, idOfSecond: nil)
        let newValue1 = Value(id: .init("ABCDEF"), data: "Pete".data(using: .utf8)!)
        branch1 = try store.makeVersion(basedOn: predecessors1, storing: [.update(newValue1)])

        let predecessors2: Version.Predecessors = .init(idOfFirst: branch2.id, idOfSecond: nil)
        let newValue2 = Value(id: .init("ABCDEF"), data: "Joyce".data(using: .utf8)!)
        branch2 = try store.makeVersion(basedOn: predecessors2, storing: [.update(newValue2)])

        let mergeVersion = try store.mergeRelated(version: branch1.id, with: branch2.id, resolvingWith: Arbiter())
        let mergeValue = try store.value(id: .init("ABCDEF"), at: mergeVersion.id)!
        #expect(mergeValue.data == "Joyce".data(using: .utf8)!)
    }

    @Test func twoWayMerge() throws {
        let secondValue = Value(id: .init("CDEFGH"), data: "Dave".data(using: .utf8)!)
        let newValue = Value(id: .init("ABCDEF"), data: "Joyce".data(using: .utf8)!)
        let changes: [Value.Change] = [.insert(secondValue), .update(newValue)]
        let secondVersion = try store.makeVersion(basedOn: nil, storing: changes)
        let arbiter = MostRecentChangeFavoringArbiter()
        let mergeVersion = try store.mergeUnrelated(version: originalVersion.id, with: secondVersion.id, resolvingWith: arbiter)
        let mergeValue = try store.value(id: .init("ABCDEF"), at: mergeVersion.id)!
        #expect(mergeValue.data == "Joyce".data(using: .utf8)!)
        let insertedValue = try store.value(id: .init("CDEFGH"), at: mergeVersion.id)!
        #expect(insertedValue.data == "Dave".data(using: .utf8)!)
    }

    @Test func twoWayMergeDeletion() throws {
        let changes: [Value.Change] = []
        let arbiter = MostRecentChangeFavoringArbiter()
        let secondVersion = try store.makeVersion(basedOn: nil, storing: changes)
        let mergeVersion = try store.mergeUnrelated(version: originalVersion.id, with: secondVersion.id, resolvingWith: arbiter)
        let mergeValue = try store.value(id: .init("ABCDEF"), at: mergeVersion.id)
        #expect(mergeValue != nil)
    }
}
