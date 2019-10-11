//
//  PrevailingValueTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 23/11/2018.
//

import XCTest
@testable import LLVS

class PrevailingValueTests: XCTestCase {
    
    let fm = FileManager.default
    let valueId = Value.ID("ABCDEF")
    
    var store: Store!
    var rootURL: URL!
    var valuesURL: URL!
    var versions: [Version]!

    override func setUp() {
        func addVersion(withName name: String) {
            let values = [Value(id: valueId, data: "\(name)".data(using: .utf8)!)]
            let changes: [Value.Change] = values.map { .insert($0) }
            let version = try! store.makeVersion(basedOnPredecessor: versions!.last?.id, storing: changes)
            versions.append(version)
        }
        
        func addEmptyVersion() {
            let version = try! store.makeVersion(basedOnPredecessor: versions!.last?.id, storing: [])
            versions.append(version)
        }
        
        super.setUp()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        valuesURL = rootURL.appendingPathComponent("values")
        store = try! Store(rootDirectoryURL: rootURL)
        
        versions = []
        addEmptyVersion()
        addVersion(withName: "1")
        addEmptyVersion()
        addVersion(withName: "2")
        addVersion(withName: "3")
        addEmptyVersion()

    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }
    
    func testNoSavedVersionAtPrevailingVersion() {
        XCTAssertNil(try store.value(id: valueId, at: versions[0].id))
    }
    
    func testSavedVersionMatchesPrevailingVersion() {
        let value = try! store.value(id: valueId, at: versions[1].id)
        XCTAssertEqual(value!.data, "1".data(using: .utf8)!)
    }
    
    func testSavedVersionPrecedesPrevailingVersion() {
        let value = try! store.value(id: valueId, at: versions[5].id)
        XCTAssertEqual(value!.data, "3".data(using: .utf8)!)
    }

    static var allTests = [
        ("testNoSavedVersionAtPrevailingVersion", testNoSavedVersionAtPrevailingVersion),
        ("testSavedVersionMatchesPrevailingVersion", testSavedVersionMatchesPrevailingVersion),
        ("testSavedVersionPrecedesPrevailingVersion", testSavedVersionPrecedesPrevailingVersion),
    ]

}
