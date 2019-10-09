//
//  ValueChangesInVersionTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 13/03/2019.
//

import XCTest
import Foundation
@testable import LLVS

class ValueChangesInVersionTests: XCTestCase {

    let fm = FileManager.default
    
    var store: Store!
    var rootURL: URL!
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
        store = try! Store(rootDirectoryURL: rootURL)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }
    
    func testValuesConflictlessMerge() {
        let val1 = Value(id: .init("ABCDEF"), data: "Bob".data(using: .utf8)!)
        var val2 = Value(id: .init("ABCD"), data: "Tom".data(using: .utf8)!)
        let origin = try! store.makeVersion(basedOn: nil, storing: [])
        let ver1 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [.insert(val1)])
        let ver2 = try! store.makeVersion(basedOnPredecessor: origin.id, storing: [.insert(val2)])
        val2.storedVersionId = ver2.id
        let ver3 = try! store.makeVersion(basedOn: .init(idOfFirst: ver1.id, idOfSecond: ver2.id), storing: [.preserve(val2.reference!)])
        let valueChanges = try! store.valueChanges(madeInVersionIdentifiedBy: ver3.id)
        let allPreserves = valueChanges.allSatisfy {
            if case .preserve = $0 {
                return true
            } else {
                return false
            }
        }
        XCTAssertTrue(allPreserves)
    }
    
    static var allTests = [
        ("testValuesConflictlessMerge", testValuesConflictlessMerge),
    ]
}



