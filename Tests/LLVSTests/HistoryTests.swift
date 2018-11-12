//
//  HistoryTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 12/11/2018.
//

import XCTest
@testable import LLVS

class HistoryTests: XCTestCase {
    
    var history: History!
    
    override func setUp() {
        super.setUp()
        history = History()
    }

    func testEmptyHistory() {
        XCTAssert(history.headIdentifiers.isEmpty)
        XCTAssertNil(history.mostRecentHead)
        
        let versions: (Version.Identifier, Version.Identifier) = (.init("ABCD"), .init("CDEF"))
        XCTAssertThrowsError(try history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions))
    }
    
    func testSingleVersion() {
        let version = Version(identifier: .init("ABCD"), predecessors: nil)
        try! history.add(version)
        XCTAssertEqual(history.headIdentifiers.count, 1)
        XCTAssertEqual(history.headIdentifiers.first?.identifierString, "ABCD")
        XCTAssertEqual(history.mostRecentHead?.identifier.identifierString, "ABCD")

        let versions: (Version.Identifier, Version.Identifier) = (.init("ABCD"), .init("CDEF"))
        XCTAssertThrowsError(try history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions))
    }
    
    func testAddingVersionTwice() {
        let version = Version(identifier: .init("ABCD"), predecessors: nil)
        try! history.add(version)
        XCTAssertThrowsError(try history.add(version))
    }
    
    func testUnrelatedVersions() {
        let version1 = Version(identifier: .init("ABCD"), predecessors: nil)
        try! history.add(version1)
        
        let version2 = Version(identifier: .init("CDEF"), predecessors: nil)
        try! history.add(version2)
        
        let sortedHeads = history.headIdentifiers.sorted { $0.identifierString < $1.identifierString }
        XCTAssertEqual(sortedHeads.count, 2)
        XCTAssertEqual(sortedHeads.first?.identifierString, "ABCD")
        XCTAssertEqual(sortedHeads.last?.identifierString, "CDEF")
        XCTAssertEqual(history.mostRecentHead?.identifier.identifierString, "CDEF")
        
        let versions: (Version.Identifier, Version.Identifier) = (.init("ABCD"), .init("CDEF"))
        XCTAssertNil(try history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions))
    }
    
    func testSimpleSerialHistory() {
        let version1 = Version(identifier: .init("ABCD"), predecessors: nil)
        try! history.add(version1)
        
        let predecessors = Version.Predecessors(identifierOfFirst: version1.identifier, identifierOfSecond: nil)
        let version2 = Version(identifier: .init("CDEF"), predecessors: predecessors)
        try! history.add(version2)
        
        let sortedHeads = history.headIdentifiers.sorted { $0.identifierString < $1.identifierString }
        XCTAssertEqual(sortedHeads.count, 1)
        XCTAssertEqual(sortedHeads.first?.identifierString, "CDEF")
        XCTAssertEqual(history.mostRecentHead?.identifier.identifierString, "CDEF")
        
        let versions: (Version.Identifier, Version.Identifier) = (.init("ABCD"), .init("CDEF"))
        let common = try! history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions)
        XCTAssertEqual(common, version1.identifier)
    }
    
    func testSerialHistory() {
        let version1 = Version(identifier: .init("ABCD"), predecessors: nil)
        try! history.add(version1)
        
        let predecessors2 = Version.Predecessors(identifierOfFirst: version1.identifier, identifierOfSecond: nil)
        let version2 = Version(identifier: .init("CDEF"), predecessors: predecessors2)
        try! history.add(version2)
        
        let predecessors3 = Version.Predecessors(identifierOfFirst: version2.identifier, identifierOfSecond: nil)
        let version3 = Version(identifier: .init("GHIJ"), predecessors: predecessors3)
        try! history.add(version3)
        
        let sortedHeads = history.headIdentifiers.sorted { $0.identifierString < $1.identifierString }
        XCTAssertEqual(sortedHeads.count, 1)
        XCTAssertEqual(sortedHeads.first?.identifierString, "GHIJ")
        XCTAssertEqual(history.mostRecentHead?.identifier.identifierString, "GHIJ")
        
        let versions: (Version.Identifier, Version.Identifier) = (.init("ABCD"), .init("GHIJ"))
        let common = try! history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions)
        XCTAssertEqual(common, version1.identifier)
    }
    
    func testBranch() {
        let version1 = Version(identifier: .init("ABCD"), predecessors: nil)
        try! history.add(version1)
        
        let predecessors2 = Version.Predecessors(identifierOfFirst: version1.identifier, identifierOfSecond: nil)
        let version2 = Version(identifier: .init("CDEF"), predecessors: predecessors2)
        try! history.add(version2)
        
        let predecessors3 = Version.Predecessors(identifierOfFirst: version1.identifier, identifierOfSecond: nil)
        let version3 = Version(identifier: .init("GHIJ"), predecessors: predecessors3)
        try! history.add(version3)
        
        let sortedHeads = history.headIdentifiers.sorted { $0.identifierString < $1.identifierString }
        XCTAssertEqual(sortedHeads.count, 2)
        XCTAssertEqual(sortedHeads.first?.identifierString, "CDEF")
        XCTAssertEqual(history.mostRecentHead?.identifier.identifierString, "GHIJ")
        
        let versions: (Version.Identifier, Version.Identifier) = (.init("CDEF"), .init("GHIJ"))
        let common = try! history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions)
        XCTAssertEqual(common, version1.identifier)
    }
    
    func testBranchAndMerge() {
        let version1 = Version(identifier: .init("ABCD"), predecessors: nil)
        try! history.add(version1)
        
        let predecessors2 = Version.Predecessors(identifierOfFirst: version1.identifier, identifierOfSecond: nil)
        let version2 = Version(identifier: .init("CDEF"), predecessors: predecessors2)
        try! history.add(version2)
        
        let predecessors3 = Version.Predecessors(identifierOfFirst: version1.identifier, identifierOfSecond: nil)
        let version3 = Version(identifier: .init("GHIJ"), predecessors: predecessors3)
        try! history.add(version3)
        
        let predecessors4 = Version.Predecessors(identifierOfFirst: version2.identifier, identifierOfSecond: version3.identifier)
        let version4 = Version(identifier: .init("KLMN"), predecessors: predecessors4)
        try! history.add(version4)
        
        let sortedHeads = history.headIdentifiers.sorted { $0.identifierString < $1.identifierString }
        XCTAssertEqual(sortedHeads.count, 1)
        XCTAssertEqual(sortedHeads.first?.identifierString, "KLMN")
        XCTAssertEqual(history.mostRecentHead?.identifier.identifierString, "KLMN")
        
        let versions: (Version.Identifier, Version.Identifier) = (.init("KLMN"), .init("GHIJ"))
        let common = try! history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions)
        XCTAssertEqual(common, version3.identifier)
    }
    
    static var allTests = [
        ("testEmptyHistory", testEmptyHistory),
        ("testSingleVersion", testSingleVersion),
        ("testUnrelatedVersions", testUnrelatedVersions),
        ("testSimpleSerialHistory", testSimpleSerialHistory),
        ("testSerialHistory", testSerialHistory),
        ("testBranch", testBranch),
        ("testBranchAndMerge", testBranchAndMerge),
        ]
}
