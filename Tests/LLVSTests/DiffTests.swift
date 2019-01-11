//
//  DiffTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 11/01/2019.
//

import XCTest
import Foundation
@testable import LLVS

class DiffTests: XCTestCase {

    let fm = FileManager.default
    
    var zone: Zone!
    var rootURL: URL!
    var map: Map!
    
    func add(values: [String], version: String, basedOn: String?) {
        let basedOnVersionId = basedOn.flatMap { Version.Identifier($0) }
        let versionId = Version.Identifier(version)
        var deltas: [Map.Delta] = []
        for valueKey in values {
            let valueRef = Value.Reference(identifier: .init(valueKey), version: versionId)
            var delta: Map.Delta = .init(key: .init(valueKey))
            delta.addedValueReferences = [valueRef]
            deltas.append(delta)
        }
        try! map.addVersion(versionId, basedOn: basedOnVersionId, applying: deltas)
    }
    
    override func setUp() {
        super.setUp()
        
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        zone = Zone(rootDirectory: rootURL, fileExtension: ".txt")
        map = Map(zone: zone)
    }
    
    override func tearDown() {
        try? fm.removeItem(at: rootURL)
        super.tearDown()
    }
    
    func testDisjoint() {
        add(values: ["AB0000"], version: "0000", basedOn: nil)
        add(values: ["AB1111", "BC1111", "CD1111"], version: "1111", basedOn: "0000")
        add(values: ["AB2222", "BC2222", "CD2222"], version: "2222", basedOn: "0000")
        let diffs = try! map.differences(between: .init("1111"), and: .init("2222"), withCommonAncestor: .init("0000"))
        XCTAssertEqual(diffs.count, 6)
        XCTAssertTrue(diffs.contains(where: { $0.valueIdentifier.identifierString == "AB1111" && $0.valueFork == Value.Fork.inserted(.first) }))
        XCTAssertTrue(diffs.contains(where: { $0.valueIdentifier.identifierString == "BC1111" && $0.valueFork == Value.Fork.inserted(.first) }))
        XCTAssertTrue(diffs.contains(where: { $0.valueIdentifier.identifierString == "CD1111" && $0.valueFork == Value.Fork.inserted(.first) }))
        XCTAssertTrue(diffs.contains(where: { $0.valueIdentifier.identifierString == "AB2222" && $0.valueFork == Value.Fork.inserted(.second) }))
        XCTAssertTrue(diffs.contains(where: { $0.valueIdentifier.identifierString == "BC2222" && $0.valueFork == Value.Fork.inserted(.second) }))
        XCTAssertTrue(diffs.contains(where: { $0.valueIdentifier.identifierString == "CD2222" && $0.valueFork == Value.Fork.inserted(.second) }))
        XCTAssertFalse(diffs.contains(where: { $0.valueIdentifier.identifierString == "CD2222" && $0.valueFork == Value.Fork.inserted(.first) }))
    }

    static var allTests = [
        ("testDisjoint", testDisjoint),
    ]
}
