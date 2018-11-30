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
    let valueIdentifier = Value.Identifier(identifierString: "ABCDEF")
    
    var store: Store!
    var rootURL: URL!
    var valuesURL: URL!
    var versions: [Version]!

    override func setUp() {
        func addVersion(withName name: String) {
            var values = [Value(identifier: valueIdentifier, version: nil, properties: ["name":name])]
            let predecessors = versions!.last.flatMap { Version.Predecessors(identifierOfFirst: $0.identifier, identifierOfSecond: nil) }
            let version = try! store.addVersion(basedOn: predecessors, storing: &values)
            versions.append(version)
        }
        
        func addEmptyVersion() {
            let predecessors = versions!.last.flatMap { Version.Predecessors(identifierOfFirst: $0.identifier, identifierOfSecond: nil) }
            var values: [Value] = []
            let version = try! store.addVersion(basedOn: predecessors, storing: &values)
            versions.append(version)
        }
        
        func addBranchVersion() {
            var values: [Value] = []
            let predecessors =  Version.Predecessors(identifierOfFirst: versions[0].identifier, identifierOfSecond: versions.last!.identifier)
            let version = try! store.addVersion(basedOn: predecessors, storing: &values)
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
        addBranchVersion()
        addVersion(withName: "4")
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
        XCTAssertEqual(value!.properties["name"]!, "1")
    }
    
    func testSavedVersionPrecedesPrevailingVersion() {
        let value = try! store.value(valueIdentifier, prevailingAt: versions[5].identifier)
        XCTAssertEqual(value!.properties["name"]!, "3")
    }
    
    func testSavedVersionPrecedesMerge() {
        let value = try! store.value(valueIdentifier, prevailingAt: versions[6].identifier)
        XCTAssertEqual(value!.properties["name"]!, "3")
    }
    
    func testSavedVersionFollowsMerge() {
        let value = try! store.value(valueIdentifier, prevailingAt: versions[8].identifier)
        XCTAssertEqual(value!.properties["name"]!, "4")
    }

    static var allTests = [
        ("testNoSavedVersionAtPrevailingVersion", testNoSavedVersionAtPrevailingVersion),
        ("testSavedVersionMatchesPrevailingVersion", testSavedVersionMatchesPrevailingVersion),
        ("testSavedVersionPrecedesPrevailingVersion", testSavedVersionPrecedesPrevailingVersion),
        ("testSavedVersionPrecedesMerge", testSavedVersionPrecedesMerge),
        ("testSavedVersionFollowsMerge", testSavedVersionFollowsMerge),
    ]

}
