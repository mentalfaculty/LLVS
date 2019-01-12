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
        
        originalValue = Value(identifier: .init("ABCDEF"), version: nil, data: "Bob".data(using: .utf8)!)
        let changes: [Value.Change] = [.insert(originalValue!)]
        originalVersion = try! store.addVersion(basedOn: nil, storing: changes)
        
        newValue1 = Value(identifier: .init("ABCDEF"), version: nil, data: "Tom".data(using: .utf8)!)
        let changes1: [Value.Change] = [.insert(newValue1)]
        let predecessors: Version.Predecessors = .init(identifierOfFirst: originalVersion.identifier, identifierOfSecond: nil)
        branch1 = try! store.addVersion(basedOn: predecessors, storing: changes1)
        
        let newValue2 = Value(identifier: .init("ABCDEF"), version: nil, data: "Jerry".data(using: .utf8)!)
        let changes2: [Value.Change] = [.insert(newValue2)]
        branch2 = try! store.addVersion(basedOn: predecessors, storing: changes2)
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
        XCTAssertThrowsError(try store.merge(version: branch1.identifier, with: branch2.identifier, resolvingWith: Arbiter()))
    }
    
    func testResolvedMergeSucceeds() {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                let value = Value(identifier: .init("ABCDEF"), version: nil, data: "Jack".data(using: .utf8)!)
                return [.insert(value)]
            }
        }
        XCTAssertNoThrow(try store.merge(version: branch1.identifier, with: branch2.identifier, resolvingWith: Arbiter()))
    }
    
    func testIncompletelyResolvedMergeFails() {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                let value = Value(identifier: .init("CDEDEF"), version: nil, data: "Jack".data(using: .utf8)!)
                return [.insert(value)]
            }
        }
        XCTAssertThrowsError(try store.merge(version: branch1.identifier, with: branch2.identifier, resolvingWith: Arbiter()))
    }
    
    func testPreserve() {
        class Arbiter: MergeArbiter {
            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
                let fork = merge.forksByValueIdentifier[.init("ABCDEF")]
                XCTAssertEqual(fork, .twiceUpdated)
                let firstValue = try! store.value(.init("ABCDEF"), prevailingAt: merge.versions.first.identifier)!
                return [.preserve(firstValue.reference!)]
            }
        }
        let mergeVersion = try! store.merge(version: branch1.identifier, with: branch2.identifier, resolvingWith: Arbiter())
        let mergeValue = try! store.value(.init("ABCDEF"), prevailingAt: mergeVersion.identifier)!
        XCTAssertEqual(mergeValue.data, "Tom".data(using: .utf8)!)
    }
    
    func testAsymmetricBranchPreserve() {
//        class Arbiter: MergeArbiter {
//            func changes(toResolve merge: Merge, in store: Store) -> [Value.Change] {
//                let fork = merge.forksByValueIdentifier[.init("ABCDEF")]
//                XCTAssertEqual(fork, .twiceUpdated)
//                let firstValue = try! store.value(.init("ABCDEF"), prevailingAt: merge.versions.first.identifier)!
//                return [.preserve(firstValue.reference!)]
//            }
//        }
//        
//        let predecessors: Version.Predecessors = .init(identifierOfFirst: branch1.identifier, identifierOfSecond: nil)
//        branch1 = try! store.addVersion(basedOn: predecessors, storing: changes1)
//        
//        let mergeVersion = try! store.merge(version: branch1.identifier, with: branch2.identifier, resolvingWith: Arbiter())
//        let mergeValue = try! store.value(.init("ABCDEF"), prevailingAt: mergeVersion.identifier)!
//        XCTAssertEqual(mergeValue.data, "Tom".data(using: .utf8)!)
    }
    
    
    static var allTests = [
        ("testUnresolveMergeFails", testUnresolveMergeFails),
        ("testResolvedMergeSucceeds", testResolvedMergeSucceeds),
        ("testIncompletelyResolvedMergeFails", testIncompletelyResolvedMergeFails),
        ("testPreserve", testPreserve),
        ("testAsymmetricBranchPreserve", testAsymmetricBranchPreserve),
    ]
}



