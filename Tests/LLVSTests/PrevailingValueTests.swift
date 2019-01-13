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
    let valueIdentifier = Value.Identifier("ABCDEF")
    
    var store: Store!
    var rootURL: URL!
    var valuesURL: URL!
    var versions: [Version]!

    override func setUp() {
        func addVersion(withName name: String) {
            let values = [Value(identifier: valueIdentifier, version: nil, data: "\(name)".data(using: .utf8)!)]
            let changes: [Value.Change] = values.map { .insert($0) }
            let version = try! store.addVersion(basedOnPredecessor: versions!.last?.identifier, storing: changes)
            versions.append(version)
        }
        
        func addEmptyVersion() {
            let version = try! store.addVersion(basedOnPredecessor: versions!.last?.identifier, storing: [])
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
        XCTAssertNil(try store.value(valueIdentifier, prevailingAt: versions[0].identifier))
    }
    
    func testSavedVersionMatchesPrevailingVersion() {
        let value = try! store.value(valueIdentifier, prevailingAt: versions[1].identifier)
        XCTAssertEqual(value!.data, "1".data(using: .utf8)!)
    }
    
    func testSavedVersionPrecedesPrevailingVersion() {
        let value = try! store.value(valueIdentifier, prevailingAt: versions[5].identifier)
        XCTAssertEqual(value!.data, "3".data(using: .utf8)!)
    }

    static var allTests = [
        ("testNoSavedVersionAtPrevailingVersion", testNoSavedVersionAtPrevailingVersion),
        ("testSavedVersionMatchesPrevailingVersion", testSavedVersionMatchesPrevailingVersion),
        ("testSavedVersionPrecedesPrevailingVersion", testSavedVersionPrecedesPrevailingVersion),
    ]

}
