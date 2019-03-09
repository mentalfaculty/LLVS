//
//  MergeArbiterTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 09/03/2019.
//

import XCTest
import Foundation
@testable import LLVS

class MostRecentBranchMergeArbiterTests: XCTestCase {
    
    let fm = FileManager.default
    
    var store: Store!
    var rootURL: URL!
    var origin: Version!
    
    var recentBranchArbiter: MostRecentBranchFavoringArbiter!
    
    override func setUp() {
        super.setUp()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try! Store(rootDirectoryURL: rootURL)
        let originVal = value("CDEFGH", stringData: "Origin")
        origin = try! store.addVersion(basedOnPredecessor: nil, storing: [.insert(originVal)])
        recentBranchArbiter = MostRecentBranchFavoringArbiter()
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }
    
    private func value(_ identifier: String, stringData: String) -> Value {
        return Value(identifier: .init(identifier), version: nil, data: stringData.data(using: .utf8)!)
    }
    
    func testInsertWithoutConflictBranch1() {
        let val1 = value("ABCDEF", stringData: "Bob")
        let ver1 = try! store.addVersion(basedOnPredecessor: origin.identifier, storing: [.insert(val1)])
        let ver2 = try! store.addVersion(basedOnPredecessor: origin.identifier, storing: [])
        let mergeVersion = try! store.merge(version: ver1.identifier, with: ver2.identifier, resolvingWith: recentBranchArbiter)
        let f = try! store.value(.init("ABCDEF"), prevailingAt: mergeVersion.identifier)!
        XCTAssertEqual(f.data, "Bob".data(using: .utf8))
        XCTAssertEqual(f.version, ver1.identifier)
    }
    
    func testInsertWithoutConflictBranch2() {
        let val1 = value("ABCDEF", stringData: "Bob")
        let ver1 = try! store.addVersion(basedOnPredecessor: origin.identifier, storing: [])
        let ver2 = try! store.addVersion(basedOnPredecessor: origin.identifier, storing: [.insert(val1)])
        let mergeVersion = try! store.merge(version: ver1.identifier, with: ver2.identifier, resolvingWith: recentBranchArbiter)
        let f = try! store.value(.init("ABCDEF"), prevailingAt: mergeVersion.identifier)!
        XCTAssertEqual(f.data, "Bob".data(using: .utf8))
        XCTAssertEqual(f.version, ver2.identifier)
    }
    
    func testTwiceInserted() {
        let val1 = value("ABCDEF", stringData: "Bob")
        let val2 = value("ABCDEF", stringData: "Tom")
        let ver1 = try! store.addVersion(basedOnPredecessor: origin.identifier, storing: [.insert(val1)])
        let ver2 = try! store.addVersion(basedOnPredecessor: origin.identifier, storing: [.insert(val2)])
        let mergeVersion = try! store.merge(version: ver1.identifier, with: ver2.identifier, resolvingWith: recentBranchArbiter)
        let f = try! store.value(.init("ABCDEF"), prevailingAt: mergeVersion.identifier)!
        XCTAssertEqual(f.data, "Tom".data(using: .utf8))
        XCTAssertEqual(f.version, ver2.identifier)
    }
    
    func testUpdated() {
        let val1 = value("CDEFGH", stringData: "Bob")
        let ver1 = try! store.addVersion(basedOnPredecessor: origin.identifier, storing: [.update(val1)])
        let ver2 = try! store.addVersion(basedOnPredecessor: origin.identifier, storing: [])
        let mergeVersion = try! store.merge(version: ver1.identifier, with: ver2.identifier, resolvingWith: recentBranchArbiter)
        let f = try! store.value(.init("CDEFGH"), prevailingAt: mergeVersion.identifier)!
        XCTAssertEqual(f.data, "Bob".data(using: .utf8))
        XCTAssertEqual(f.version, ver1.identifier)
    }
    
    func testTwiceUpdated() {
        let val1 = value("CDEFGH", stringData: "Bob")
        let val2 = value("CDEFGH", stringData: "Tom")
        let ver1 = try! store.addVersion(basedOnPredecessor: origin.identifier, storing: [.update(val1)])
        let ver2 = try! store.addVersion(basedOnPredecessor: origin.identifier, storing: [.update(val2)])
        let mergeVersion = try! store.merge(version: ver1.identifier, with: ver2.identifier, resolvingWith: recentBranchArbiter)
        let f = try! store.value(.init("CDEFGH"), prevailingAt: mergeVersion.identifier)!
        XCTAssertEqual(f.data, "Tom".data(using: .utf8))
        XCTAssertEqual(f.version, ver2.identifier)
    }
    
    func testRemovedAndUpdated() {
        let val1 = value("CDEFGH", stringData: "Bob")
        let ver1 = try! store.addVersion(basedOnPredecessor: origin.identifier, storing: [.update(val1)])
        let ver2 = try! store.addVersion(basedOnPredecessor: origin.identifier, storing: [.remove(.init("CDEFGH"))])
        let mergeVersion = try! store.merge(version: ver1.identifier, with: ver2.identifier, resolvingWith: recentBranchArbiter)
        let f = try! store.value(.init("CDEFGH"), prevailingAt: mergeVersion.identifier)!
        XCTAssertEqual(f.data, "Bob".data(using: .utf8))
        XCTAssertEqual(f.version, ver1.identifier)
    }

    static var allTests = [
        ("testInsertWithoutConflictBranch1", testInsertWithoutConflictBranch1),
        ("testInsertWithoutConflictBranch2", testInsertWithoutConflictBranch2),
        ("testTwiceInserted", testTwiceInserted),
    ]
}
