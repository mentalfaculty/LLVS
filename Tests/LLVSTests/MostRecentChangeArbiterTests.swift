//
//  MostRecentChangeFavoringArbiterTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 10/03/2019.
//

import XCTest
import Foundation
@testable import LLVS

class MostRecentChangeMergeArbiterTests: XCTestCase {
    
    let fm = FileManager.default
    
    var store: Store!
    var rootURL: URL!
    var origin: Version!
    
    var recentChangeArbiter: MostRecentChangeFavoringArbiter!
    
    override func setUp() {
        super.setUp()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try! Store(rootDirectoryURL: rootURL)
        let originVal = value("CDEFGH", stringData: "Origin")
        origin = try! store.makeVersion(basedOnPredecessor: nil, storing: [.insert(originVal)])
        recentChangeArbiter = MostRecentChangeFavoringArbiter()
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }
    
    private func value(_ identifier: String, stringData: String) -> Value {
        return Value(id: .init(identifier), data: stringData.data(using: .utf8)!)
    }
    
    func testRemove() {
        let ver1 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [.remove(.init("CDEFGH"))])
        let ver2 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [])
        let mergeVersion = try! store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentChangeArbiter)
        let f = try! store.value(id: .init("CDEFGH"), at: mergeVersion.id)
        XCTAssertNil(f)
    }
    
    func testTwiceRemove() {
        let ver1 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [.remove(.init("CDEFGH"))])
        let ver2 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [.remove(.init("CDEFGH"))])
        let ver3 = try! store.makeVersion(basedOnPredecessor: ver2.id, storing: [])
        let mergeVersion = try! store.mergeRelated(version: ver1.id, with: ver3.id, resolvingWith: recentChangeArbiter)
        let f = try! store.value(id: .init("CDEFGH"), at: mergeVersion.id)
        XCTAssertNil(f)
    }
    
    func testInsert() {
        do {
            let val1 = value("ABCDEF", stringData: "Bob")
            let ver1 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [.insert(val1)])
            let ver2 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [])
            let ver3 = try! store.makeVersion(basedOnPredecessor: ver1.id, storing: [])
            let mergeVersion = try! store.mergeRelated(version: ver3.id, with: ver2.id, resolvingWith: recentChangeArbiter)
            let f = try! store.value(id: .init("ABCDEF"), at: mergeVersion.id)!
            XCTAssertEqual(f.data, "Bob".data(using: .utf8))
            XCTAssertEqual(f.storedVersionId, ver1.id)
        }
        
        do {
            let val1 = value("ABCDEF", stringData: "Bob")
            let ver1 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [])
            let ver2 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [.insert(val1)])
            let mergeVersion = try! store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentChangeArbiter)
            let f = try! store.value(id: .init("ABCDEF"), at: mergeVersion.id)!
            XCTAssertEqual(f.data, "Bob".data(using: .utf8))
            XCTAssertEqual(f.storedVersionId, ver2.id)
        }
    }
    
    func testTwiceInserted() {
        let val1 = value("ABCDEF", stringData: "Bob")
        let val2 = value("ABCDEF", stringData: "Tom")
        let ver1 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [.insert(val1)])
        let ver2 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [.insert(val2)])
        let ver3 = try! store.makeVersion(basedOnPredecessor: ver1.id, storing: [])
        let mergeVersion = try! store.mergeRelated(version: ver3.id, with: ver2.id, resolvingWith: recentChangeArbiter)
        let f = try! store.value(id: .init("ABCDEF"), at: mergeVersion.id)!
        XCTAssertEqual(f.data, "Tom".data(using: .utf8))
        XCTAssertEqual(f.storedVersionId, ver2.id)
    }
    
    func testTwiceInsertedAndUpdated() {
        let val1 = value("ABCDEF", stringData: "Bob")
        let val2 = value("ABCDEF", stringData: "Tom")
        let val3 = value("ABCDEF", stringData: "Dave")
        let ver1 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [.insert(val1)])
        let ver2 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [.insert(val2)])
        let ver3 = try! store.makeVersion(basedOnPredecessor: ver1.id, storing: [.update(val3)])
        let mergeVersion = try! store.mergeRelated(version: ver3.id, with: ver2.id, resolvingWith: recentChangeArbiter)
        let f = try! store.value(id: .init("ABCDEF"), at: mergeVersion.id)!
        XCTAssertEqual(f.data, "Dave".data(using: .utf8))
        XCTAssertEqual(f.storedVersionId, ver3.id)
    }
    
    func testUpdated() {
        let val1 = value("CDEFGH", stringData: "Bob")
        let ver1 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [.update(val1)])
        let ver2 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [])
        let mergeVersion = try! store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentChangeArbiter)
        let f = try! store.value(id: .init("CDEFGH"), at: mergeVersion.id)!
        XCTAssertEqual(f.data, "Bob".data(using: .utf8))
        XCTAssertEqual(f.storedVersionId, ver1.id)
    }
    
    func testTwiceUpdated() {
        let val1 = value("CDEFGH", stringData: "Bob")
        let val2 = value("CDEFGH", stringData: "Tom")
        let val3 = value("CDEFGH", stringData: "Dave")
        let ver1 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [.update(val1)])
        let ver2 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [.update(val2)])
        let ver3 = try! store.makeVersion(basedOnPredecessor: ver1.id, storing: [.update(val3)])
        let mergeVersion = try! store.mergeRelated(version: ver3.id, with: ver2.id, resolvingWith: recentChangeArbiter)
        let f = try! store.value(id: .init("CDEFGH"), at: mergeVersion.id)!
        XCTAssertEqual(f.data, "Dave".data(using: .utf8))
        XCTAssertEqual(f.storedVersionId, ver3.id)
    }
    
    func testRemovedAndUpdated() {
        do {
            let val1 = value("CDEFGH", stringData: "Bob")
            let ver1 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [.update(val1)])
            let ver2 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [.remove(.init("CDEFGH"))])
            let mergeVersion = try! store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentChangeArbiter)
            let f = try! store.value(id: .init("CDEFGH"), at: mergeVersion.id)!
            XCTAssertEqual(f.data, "Bob".data(using: .utf8))
            XCTAssertEqual(f.storedVersionId, ver1.id)
        }
        do {
            let val1 = value("CDEFGH", stringData: "Bob")
            let ver1 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [.remove(.init("CDEFGH"))])
            let ver2 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [.update(val1)])
            let mergeVersion = try! store.mergeRelated(version: ver1.id, with: ver2.id, resolvingWith: recentChangeArbiter)
            let f = try! store.value(id: .init("CDEFGH"), at: mergeVersion.id)!
            XCTAssertEqual(f.data, "Bob".data(using: .utf8))
            XCTAssertEqual(f.storedVersionId, ver2.id)
        }
    }
    
    static var allTests = [
        ("testRemove", testRemove),
        ("testInsert", testInsert),
        ("testTwiceInserted", testTwiceInserted),
        ("testTwiceInsertedAndUpdated", testTwiceInsertedAndUpdated),
        ("testUpdated", testUpdated),
        ("testTwiceUpdated", testTwiceUpdated),
        ("testRemovedAndUpdated", testRemovedAndUpdated)
    ]
}
