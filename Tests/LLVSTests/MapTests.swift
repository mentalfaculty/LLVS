//
//  MapTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 09/12/2018.
//

import XCTest
import Foundation
@testable import LLVS

class MapTests: XCTestCase {

    let fm = FileManager.default
    
    var zone: Zone!
    var rootURL: URL!
    var map: Map!
    
    override func setUp() {
        super.setUp()
        
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        zone = FileZone(rootDirectory: rootURL, fileExtension: ".txt")
        map = Map(zone: zone)
    }
    
    override func tearDown() {
        try? fm.removeItem(at: rootURL)
        super.tearDown()
    }
    
    func testFirstCommit() {
        let valueKey = "ABCD"
        let versionId = Version.Identifier("1234")
        let valueRef = Value.Reference(identifier: .init(valueKey), version: versionId)
        var delta: Map.Delta = .init(key: .init(valueKey))
        delta.addedValueReferences = [valueRef]
        XCTAssertNoThrow(try map.addVersion(versionId, basedOn: nil, applying: [delta]))
        let valueRefs = try! map.valueReferences(matching: .init(valueKey), at: versionId)
        XCTAssertEqual(valueRefs.count, 1)
        XCTAssertEqual(valueRefs.first!, Value.Reference(identifier: .init(valueKey), version: versionId))
    }
    
    func testFetchingValueFromEarlierCommit() {
        let valueKey = "ABCD"
        var delta: Map.Delta = .init(key: .init(valueKey))
        let versionId = Version.Identifier("1234")
        let valueRef = Value.Reference(identifier: .init(valueKey), version: versionId)
        delta.addedValueReferences = [valueRef]
        try! map.addVersion(.init("1234"), basedOn: nil, applying: [delta])
        try! map.addVersion(.init("2345"), basedOn: .init("1234"), applying: [])
        let valueRefs = try! map.valueReferences(matching: .init(valueKey), at: .init("2345"))
        XCTAssertEqual(valueRefs.count, 1)
        XCTAssertEqual(valueRefs.first!, Value.Reference(identifier: .init(valueKey), version: .init("1234")))
    }
    
    func testRemovingValue() {
        let valueKey1 = "ABCD"
        var delta1: Map.Delta = .init(key: .init(valueKey1))
        let versionId1 = Version.Identifier("1234")
        let valueRef1 = Value.Reference(identifier: .init(valueKey1), version: versionId1)
        delta1.addedValueReferences = [valueRef1]
        try! map.addVersion(versionId1, basedOn: nil, applying: [delta1])
        
        let valueKey2 = "BCDE"
        let versionId2 = Version.Identifier("2345")
        var delta21: Map.Delta = .init(key: .init(valueKey1))
        delta21.removedValueIdentifiers = [.init(valueKey1)]
        var delta22: Map.Delta = .init(key: .init(valueKey2))
        let valueRef2 = Value.Reference(identifier: .init(valueKey2), version: versionId2)
        delta22.addedValueReferences = [valueRef2]
        try! map.addVersion(.init("2345"), basedOn: .init("1234"), applying: [delta21, delta22])
        
        var valueRefs = try! map.valueReferences(matching: .init(valueKey1), at: .init("2345"))
        XCTAssertEqual(valueRefs.count, 0)
        
        valueRefs = try! map.valueReferences(matching: .init(valueKey2), at: .init("2345"))
        XCTAssertEqual(valueRefs.count, 1)
        XCTAssertEqual(valueRefs.first!, Value.Reference(identifier: .init(valueKey2), version: .init("2345")))
    }
    
    func testOneToManyMap() {
        var delta1: Map.Delta = .init(key: .init("Amsterdam"))
        let valueRef1 = Value.Reference(identifier: .init("ABCD"), version: .init("1234"))
        delta1.addedValueReferences = [valueRef1]
        try! map.addVersion(valueRef1.version, basedOn: nil, applying: [delta1])
        
        var delta2: Map.Delta = .init(key: .init("Amsterdam"))
        let valueRef2 = Value.Reference(identifier: .init("CDEF"), version: .init("2345"))
        delta2.addedValueReferences = [valueRef2]
        try! map.addVersion(valueRef2.version, basedOn: .init("1234"), applying: [delta2])
        
        var valueRefs = try! map.valueReferences(matching: .init("Amsterdam"), at: .init("2345"))
        XCTAssertEqual(valueRefs.count, 2)
        XCTAssert(valueRefs.contains(.init(identifier: .init("ABCD"), version: .init("1234"))))
        XCTAssert(valueRefs.contains(.init(identifier: .init("CDEF"), version: .init("2345"))))
        
        var delta3: Map.Delta = .init(key: .init("Amsterdam"))
        delta3.removedValueIdentifiers = [.init("ABCD")]
        try! map.addVersion(.init("3456"), basedOn: .init("2345"), applying: [delta3])
        
        valueRefs = try! map.valueReferences(matching: .init("Amsterdam"), at: .init("3456"))
        XCTAssertEqual(valueRefs.count, 1)
        XCTAssert(valueRefs.contains(.init(identifier: .init("CDEF"), version: .init("2345"))))
    }
    
    func testSimilarKeys() {
        var delta1: Map.Delta = .init(key: .init("Amsterdam"))
        let valueRef1 = Value.Reference(identifier: .init("ABCD"), version: .init("1234"))
        delta1.addedValueReferences = [valueRef1]
        try! map.addVersion(valueRef1.version, basedOn: nil, applying: [delta1])
        
        var delta2: Map.Delta = .init(key: .init("Amsterdam1"))
        let valueRef2 = Value.Reference(identifier: .init("CDEF"), version: .init("2345"))
        delta2.addedValueReferences = [valueRef2]
        try! map.addVersion(valueRef2.version, basedOn: .init("1234"), applying: [delta2])
        
        do {
            let valueRefs = try! map.valueReferences(matching: .init("Amsterdam"), at: .init("2345"))
            XCTAssertEqual(valueRefs.count, 1)
            XCTAssert(valueRefs.contains(.init(identifier: .init("ABCD"), version: .init("1234"))))
        }
        
        do {
            let valueRefs = try! map.valueReferences(matching: .init("Amsterdam1"), at: .init("2345"))
            XCTAssertEqual(valueRefs.count, 1)
            XCTAssert(valueRefs.contains(.init(identifier: .init("CDEF"), version: .init("2345"))))
        }
    }
    
    static var allTests = [
        ("testFirstCommit", testFirstCommit),
        ("testFetchingValueFromEarlierCommit", testFetchingValueFromEarlierCommit),
        ("testRemovingValue", testRemovingValue),
        ("testOneToManyMap", testOneToManyMap),
    ]
}
