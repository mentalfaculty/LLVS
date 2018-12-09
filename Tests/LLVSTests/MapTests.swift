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
        zone = Zone(rootDirectory: rootURL, fileExtension: ".txt")
        map = Map(zone: zone)
    }
    
    override func tearDown() {
        try? fm.removeItem(at: rootURL)
        super.tearDown()
    }
    
    func testFetchingNonExistentVersionThrows() {
        
    }
    
    func testFirstCommit() {
        let valueKey = "ABCD"
        let versionId = Version.Identifier("1234")
        var delta: Map.Delta = .init(key: .init(valueKey))
        delta.addedValueIdentifiers = [.init(valueKey)]
        XCTAssertNoThrow(try map.addVersion(versionId, basedOn: nil, applying: [delta]))
        let valueRefs = try! map.valueReferences(matching: .init(valueKey), at: versionId)
        XCTAssertEqual(valueRefs.count, 1)
        XCTAssertEqual(valueRefs.first!, Value.Reference(identifier: .init(valueKey), version: versionId))
    }
    
    func testFetchingValueFromEarlierCommit() {
        let valueKey = "ABCD"
        var delta: Map.Delta = .init(key: .init(valueKey))
        delta.addedValueIdentifiers = [.init(valueKey)]
        try! map.addVersion(.init("1234"), basedOn: nil, applying: [delta])
        try! map.addVersion(.init("2345"), basedOn: .init("1234"), applying: [])
        let valueRefs = try! map.valueReferences(matching: .init(valueKey), at: .init("2345"))
        XCTAssertEqual(valueRefs.count, 1)
        XCTAssertEqual(valueRefs.first!, Value.Reference(identifier: .init(valueKey), version: .init("1234")))
    }
    
    func testRemovingValue() {
        let valueKey1 = "ABCD"
        var delta1: Map.Delta = .init(key: .init(valueKey1))
        delta1.addedValueIdentifiers = [.init(valueKey1)]
        try! map.addVersion(.init("1234"), basedOn: nil, applying: [delta1])
        
        let valueKey2 = "BCDE"
        var delta21: Map.Delta = .init(key: .init(valueKey1))
        delta21.removedValueIdentifiers = [.init(valueKey1)]
        var delta22: Map.Delta = .init(key: .init(valueKey2))
        delta22.addedValueIdentifiers = [.init(valueKey2)]
        try! map.addVersion(.init("2345"), basedOn: .init("1234"), applying: [delta21, delta22])
        
        var valueRefs = try! map.valueReferences(matching: .init(valueKey1), at: .init("2345"))
        XCTAssertEqual(valueRefs.count, 0)
        
        valueRefs = try! map.valueReferences(matching: .init(valueKey2), at: .init("2345"))
        XCTAssertEqual(valueRefs.count, 1)
        XCTAssertEqual(valueRefs.first!, Value.Reference(identifier: .init(valueKey2), version: .init("2345")))
    }
    
    func testOneToManyMap() {
        var delta1: Map.Delta = .init(key: .init("Amsterdam"))
        delta1.addedValueIdentifiers = [.init("ABCD")]
        try! map.addVersion(.init("1234"), basedOn: nil, applying: [delta1])
        
        var delta2: Map.Delta = .init(key: .init("Amsterdam"))
        delta2.addedValueIdentifiers = [.init("CDEF")]
        try! map.addVersion(.init("2345"), basedOn: .init("1234"), applying: [delta2])
        
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
    
    static var allTests = [
        ("testFetchingNonExistentVersionThrows", testFetchingNonExistentVersionThrows),
        ("testFirstCommit", testFirstCommit),
        ("testFetchingValueFromEarlierCommit", testFetchingValueFromEarlierCommit),
        ("testRemovingValue", testRemovingValue),
    ]
}
