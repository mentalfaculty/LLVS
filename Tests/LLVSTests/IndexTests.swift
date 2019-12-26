//
//  IndexTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 09/12/2018.
//

import XCTest
import Foundation
@testable import LLVS

class IndexTests: XCTestCase {

    let fm = FileManager.default
    
    var zone: Zone!
    var rootURL: URL!
    var index: Index!
    
    override func setUp() {
        super.setUp()
        
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        zone = FileZone(rootDirectory: rootURL, fileExtension: ".txt")
        index = Index(zone: zone)
    }
    
    override func tearDown() {
        try? fm.removeItem(at: rootURL)
        super.tearDown()
    }
    
    func testFirstCommit() {
        let valueKey = "ABCD"
        let versionId = Version.ID("1234")
        let valueRef = Value.Reference(valueId: .init(valueKey), storedVersionId: versionId)
        var delta: Index.Delta = .init(key: .init(valueKey))
        delta.addedValueReferences = [valueRef]
        XCTAssertNoThrow(try index.addVersion(versionId, basedOn: nil, applying: [delta]))
        let valueRefs = try! index.valueReferences(matching: .init(valueKey), at: versionId)
        XCTAssertEqual(valueRefs.count, 1)
        XCTAssertEqual(valueRefs.first!, Value.Reference(valueId: .init(valueKey), storedVersionId: versionId))
    }
    
    func testFetchingValueFromEarlierCommit() {
        let valueKey = "ABCD"
        var delta: Index.Delta = .init(key: .init(valueKey))
        let versionId = Version.ID("1234")
        let valueRef = Value.Reference(valueId: .init(valueKey), storedVersionId: versionId)
        delta.addedValueReferences = [valueRef]
        try! index.addVersion(.init("1234"), basedOn: nil, applying: [delta])
        try! index.addVersion(.init("2345"), basedOn: .init("1234"), applying: [])
        let valueRefs = try! index.valueReferences(matching: .init(valueKey), at: .init("2345"))
        XCTAssertEqual(valueRefs.count, 1)
        XCTAssertEqual(valueRefs.first!, Value.Reference(valueId: .init(valueKey), storedVersionId: .init("1234")))
    }
    
    func testRemovingValue() {
        let valueKey1 = "ABCD"
        var delta1: Index.Delta = .init(key: .init(valueKey1))
        let versionId1 = Version.ID("1234")
        let valueRef1 = Value.Reference(valueId: .init(valueKey1), storedVersionId: versionId1)
        delta1.addedValueReferences = [valueRef1]
        try! index.addVersion(versionId1, basedOn: nil, applying: [delta1])
        
        let valueKey2 = "BCDE"
        let versionId2 = Version.ID("2345")
        var delta21: Index.Delta = .init(key: .init(valueKey1))
        delta21.removedValueIdentifiers = [.init(valueKey1)]
        var delta22: Index.Delta = .init(key: .init(valueKey2))
        let valueRef2 = Value.Reference(valueId: .init(valueKey2), storedVersionId: versionId2)
        delta22.addedValueReferences = [valueRef2]
        try! index.addVersion(.init("2345"), basedOn: .init("1234"), applying: [delta21, delta22])
        
        var valueRefs = try! index.valueReferences(matching: .init(valueKey1), at: .init("2345"))
        XCTAssertEqual(valueRefs.count, 0)
        
        valueRefs = try! index.valueReferences(matching: .init(valueKey2), at: .init("2345"))
        XCTAssertEqual(valueRefs.count, 1)
        XCTAssertEqual(valueRefs.first!, Value.Reference(valueId: .init(valueKey2), storedVersionId: .init("2345")))
    }
    
    func testOneToManyIndex() {
        var delta1: Index.Delta = .init(key: .init("Amsterdam"))
        let valueRef1 = Value.Reference(valueId: .init("ABCD"), storedVersionId: .init("1234"))
        delta1.addedValueReferences = [valueRef1]
        try! index.addVersion(valueRef1.storedVersionId, basedOn: nil, applying: [delta1])
        
        var delta2: Index.Delta = .init(key: .init("Amsterdam"))
        let valueRef2 = Value.Reference(valueId: .init("CDEF"), storedVersionId: .init("2345"))
        delta2.addedValueReferences = [valueRef2]
        try! index.addVersion(valueRef2.storedVersionId, basedOn: .init("1234"), applying: [delta2])
        
        var valueRefs = try! index.valueReferences(matching: .init("Amsterdam"), at: .init("2345"))
        XCTAssertEqual(valueRefs.count, 2)
        XCTAssert(valueRefs.contains(.init(valueId: .init("ABCD"), storedVersionId: .init("1234"))))
        XCTAssert(valueRefs.contains(.init(valueId: .init("CDEF"), storedVersionId: .init("2345"))))
        
        var delta3: Index.Delta = .init(key: .init("Amsterdam"))
        delta3.removedValueIdentifiers = [.init("ABCD")]
        try! index.addVersion(.init("3456"), basedOn: .init("2345"), applying: [delta3])
        
        valueRefs = try! index.valueReferences(matching: .init("Amsterdam"), at: .init("3456"))
        XCTAssertEqual(valueRefs.count, 1)
        XCTAssert(valueRefs.contains(.init(valueId: .init("CDEF"), storedVersionId: .init("2345"))))
    }
    
    func testSimilarKeys() {
        var delta1: Index.Delta = .init(key: .init("Amsterdam"))
        let valueRef1 = Value.Reference(valueId: .init("ABCD"), storedVersionId: .init("1234"))
        delta1.addedValueReferences = [valueRef1]
        try! index.addVersion(valueRef1.storedVersionId, basedOn: nil, applying: [delta1])
        
        var delta2: Index.Delta = .init(key: .init("Amsterdam1"))
        let valueRef2 = Value.Reference(valueId: .init("CDEF"), storedVersionId: .init("2345"))
        delta2.addedValueReferences = [valueRef2]
        try! index.addVersion(valueRef2.storedVersionId, basedOn: .init("1234"), applying: [delta2])
        
        do {
            let valueRefs = try! index.valueReferences(matching: .init("Amsterdam"), at: .init("2345"))
            XCTAssertEqual(valueRefs.count, 1)
            XCTAssert(valueRefs.contains(.init(valueId: .init("ABCD"), storedVersionId: .init("1234"))))
        }
        
        do {
            let valueRefs = try! index.valueReferences(matching: .init("Amsterdam1"), at: .init("2345"))
            XCTAssertEqual(valueRefs.count, 1)
            XCTAssert(valueRefs.contains(.init(valueId: .init("CDEF"), storedVersionId: .init("2345"))))
        }
    }
    
    static var allTests = [
        ("testFirstCommit", testFirstCommit),
        ("testFetchingValueFromEarlierCommit", testFetchingValueFromEarlierCommit),
        ("testRemovingValue", testRemovingValue),
        ("testOneToManyIndex", testOneToManyIndex),
    ]
}
