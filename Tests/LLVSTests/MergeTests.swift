//
//  MergeTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 12/01/2019.
//

import XCTest
import Foundation
@testable import LLVS

class MergeTests: XCTestCase {

    let fm = FileManager.default
    
    var store: Store!
    var rootURL: URL!
    var valuesURL: URL!
    var originalVersion: Version!
    var branch1: Version!
    var branch2: Version!
    var originalValue: Value!
    var newValue1: Value!
    var newValue2: Value!
    
    var valueForMerge: Value!
    
    override func setUp() {
        super.setUp()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        valuesURL = rootURL.appendingPathComponent("values")
        store = try! Store(rootDirectoryURL: rootURL)
        
        originalValue = Value(id: .init("ABCDEF"), data: "Bob".data(using: .utf8)!)
        let changes: [Value.Change] = [.insert(originalValue!)]
        originalVersion = try! store.makeVersion(basedOn: nil, storing: changes)
        
        newValue1 = Value(id: .init("ABCDEF"), data: "Tom".data(using: .utf8)!)
        let changes1: [Value.Change] = [.insert(newValue1)]
        let predecessors: Version.Predecessors = .init(idOfFirst: originalVersion.id, idOfSecond: nil)
        branch1 = try! store.makeVersion(basedOn: predecessors, storing: changes1)
        
        let newValue2 = Value(id: .init("ABCDEF"), data: "Jerry".data(using: .utf8)!)
        let changes2: [Value.Change] = [.insert(newValue2)]
        branch2 = try! store.makeVersion(basedOn: predecessors, storing: changes2)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }
    
    func testUnresolveMergeFails() {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                XCTAssertEqual(merge.forksByValueIdentifier.count, 1)
                return []
            }
        }
        XCTAssertThrowsError(try store.mergeRelated(version: branch1.id, with: branch2.id, resolvingWith: Arbiter()))
    }
    
    func testResolvedMergeSucceeds() {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                let value = Value(id: .init("ABCDEF"), data: "Jack".data(using: .utf8)!)
                return [.insert(value)]
            }
        }
        XCTAssertNoThrow(try store.mergeRelated(version: branch1.id, with: branch2.id, resolvingWith: Arbiter()))
    }
    
    func testIncompletelyResolvedMergeFails() {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                let value = Value(id: .init("CDEDEF"), data: "Jack".data(using: .utf8)!)
                return [.insert(value)]
            }
        }
        XCTAssertThrowsError(try store.mergeRelated(version: branch1.id, with: branch2.id, resolvingWith: Arbiter()))
    }
    
    func testPreserve() {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                let fork = merge.forksByValueIdentifier[.init("ABCDEF")]
                XCTAssertEqual(fork, .twiceUpdated)
                let firstValue = try! store.value(id: .init("ABCDEF"), at: merge.versions.first.id)!
                return [.preserve(firstValue.reference!)]
            }
        }
        let mergeVersion = try! store.mergeRelated(version: branch1.id, with: branch2.id, resolvingWith: Arbiter())
        let mergeValue = try! store.value(id: .init("ABCDEF"), at: mergeVersion.id)!
        XCTAssertEqual(mergeValue.data, "Tom".data(using: .utf8)!)
    }
    
    func testAsymmetricBranchPreserve() {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                let fork = merge.forksByValueIdentifier[.init("ABCDEF")]
                XCTAssertEqual(fork, .twiceUpdated)
                let firstValue = try! store.value(id: .init("ABCDEF"), at: merge.versions.second.id)!
                return [.preserve(firstValue.reference!)]
            }
        }
        
        let predecessors: Version.Predecessors = .init(idOfFirst: branch2.id, idOfSecond: nil)
        let newValue = Value(id: .init("ABCDEF"), data: "Pete".data(using: .utf8)!)
        branch2 = try! store.makeVersion(basedOn: predecessors, storing: [.update(newValue)])
        
        let mergeVersion = try! store.mergeRelated(version: branch1.id, with: branch2.id, resolvingWith: Arbiter())
        let mergeValue = try! store.value(id: .init("ABCDEF"), at: mergeVersion.id)!
        XCTAssertEqual(mergeValue.data, "Pete".data(using: .utf8)!)
    }
    
    func testRemove() {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                let fork = merge.forksByValueIdentifier[.init("ABCDEF")]
                XCTAssertEqual(fork, .removedAndUpdated(removedOn: .second))
                return [.preserveRemoval(.init("ABCDEF"))]
            }
        }
        
        let predecessors: Version.Predecessors = .init(idOfFirst: branch2.id, idOfSecond: nil)
        branch2 = try! store.makeVersion(basedOn: predecessors, storing: [.remove(.init("ABCDEF"))])
        
        let mergeVersion = try! store.mergeRelated(version: branch1.id, with: branch2.id, resolvingWith: Arbiter())
        let mergeValue = try! store.value(id: .init("ABCDEF"), at: mergeVersion.id)
        XCTAssertNil(mergeValue)
    }
    
    func testTwiceRemoved() {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                let fork = merge.forksByValueIdentifier[.init("ABCDEF")]
                XCTAssertEqual(fork, .twiceRemoved)
                return [.preserveRemoval(.init("ABCDEF"))]
            }
        }
        
        let predecessors1: Version.Predecessors = .init(idOfFirst: branch1.id, idOfSecond: nil)
        branch1 = try! store.makeVersion(basedOn: predecessors1, storing: [.remove(.init("ABCDEF"))])
        
        let predecessors2: Version.Predecessors = .init(idOfFirst: branch2.id, idOfSecond: nil)
        branch2 = try! store.makeVersion(basedOn: predecessors2, storing: [.remove(.init("ABCDEF"))])
        
        let mergeVersion = try! store.mergeRelated(version: branch1.id, with: branch2.id, resolvingWith: Arbiter())
        let mergeValue = try! store.value(id: .init("ABCDEF"), at: mergeVersion.id)
        XCTAssertNil(mergeValue)
    }
    
    func testTwiceUpdated() {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                let fork = merge.forksByValueIdentifier[.init("ABCDEF")]
                XCTAssertEqual(fork, .twiceUpdated)
                let secondValue = try! store.value(id: .init("ABCDEF"), at: merge.versions.second.id)!
                return [.preserve(secondValue.reference!)]
            }
        }
        
        let predecessors1: Version.Predecessors = .init(idOfFirst: branch1.id, idOfSecond: nil)
        let newValue1 = Value(id: .init("ABCDEF"), data: "Pete".data(using: .utf8)!)
        branch1 = try! store.makeVersion(basedOn: predecessors1, storing: [.update(newValue1)])
        
        let predecessors2: Version.Predecessors = .init(idOfFirst: branch2.id, idOfSecond: nil)
        let newValue2 = Value(id: .init("ABCDEF"), data: "Joyce".data(using: .utf8)!)
        branch2 = try! store.makeVersion(basedOn: predecessors2, storing: [.update(newValue2)])
        
        let mergeVersion = try! store.mergeRelated(version: branch1.id, with: branch2.id, resolvingWith: Arbiter())
        let mergeValue = try! store.value(id: .init("ABCDEF"), at: mergeVersion.id)!
        XCTAssertEqual(mergeValue.data, "Joyce".data(using: .utf8)!)
    }
    
    func testTwoWayMerge() {
        let secondValue = Value(id: .init("CDEFGH"), data: "Dave".data(using: .utf8)!)
        let newValue = Value(id: .init("ABCDEF"), data: "Joyce".data(using: .utf8)!)
        let changes: [Value.Change] = [.insert(secondValue), .update(newValue)]
        let secondVersion = try! store.makeVersion(basedOn: nil, storing: changes)
        let arbiter = MostRecentChangeFavoringArbiter()
        let mergeVersion = try! store.mergeUnrelated(version: originalVersion.id, with: secondVersion.id, resolvingWith: arbiter)
        let mergeValue = try! store.value(id: .init("ABCDEF"), at: mergeVersion.id)!
        XCTAssertEqual(mergeValue.data, "Joyce".data(using: .utf8)!)
        let insertedValue = try! store.value(id: .init("CDEFGH"), at: mergeVersion.id)!
        XCTAssertEqual(insertedValue.data, "Dave".data(using: .utf8)!)
    }
    
    func testTwoWayMergeDeletion() {
        let changes: [Value.Change] = []
        let arbiter = MostRecentChangeFavoringArbiter()
        let secondVersion = try! store.makeVersion(basedOn: nil, storing: changes)
        let mergeVersion = try! store.mergeUnrelated(version: originalVersion.id, with: secondVersion.id, resolvingWith: arbiter)
        let mergeValue = try! store.value(id: .init("ABCDEF"), at: mergeVersion.id)
        XCTAssertNotNil(mergeValue)
    }
    
    static var allTests = [
        ("testUnresolveMergeFails", testUnresolveMergeFails),
        ("testResolvedMergeSucceeds", testResolvedMergeSucceeds),
        ("testIncompletelyResolvedMergeFails", testIncompletelyResolvedMergeFails),
        ("testPreserve", testPreserve),
        ("testAsymmetricBranchPreserve", testAsymmetricBranchPreserve),
        ("testRemove", testRemove),
        ("testTwiceRemoved", testTwiceRemoved),
        ("testTwiceUpdated", testTwiceUpdated),
        ("testTwoWayMerge", testTwoWayMerge),
        ("testTwoWayMergeDeletion", testTwoWayMergeDeletion),
    ]
}



