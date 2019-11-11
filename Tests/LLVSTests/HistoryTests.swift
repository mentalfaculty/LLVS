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
        
        let versions: (Version.ID, Version.ID) = (.init("ABCD"), .init("CDEF"))
        XCTAssertThrowsError(try history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions))
    }
    
    func testSingleVersion() {
        let version = Version(id: .init("ABCD"), predecessors: nil)
        try! history.add(version, updatingPredecessorVersions: true)
        XCTAssertEqual(history.headIdentifiers.count, 1)
        XCTAssertEqual(history.headIdentifiers.first?.rawValue, "ABCD")
        XCTAssertEqual(history.mostRecentHead?.id.rawValue, "ABCD")

        let versions: (Version.ID, Version.ID) = (.init("ABCD"), .init("CDEF"))
        XCTAssertThrowsError(try history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions))
    }
    
    func testAddingVersionTwice() {
        let version = Version(id: .init("ABCD"), predecessors: nil)
        try! history.add(version, updatingPredecessorVersions: true)
        XCTAssertThrowsError(try history.add(version, updatingPredecessorVersions: true))
    }
    
    func testUnrelatedVersions() {
        let version1 = Version(id: .init("ABCD"), predecessors: nil)
        try! history.add(version1, updatingPredecessorVersions: true)
        
        let version2 = Version(id: .init("CDEF"), predecessors: nil)
        try! history.add(version2, updatingPredecessorVersions: true)
        
        let sortedHeads = history.headIdentifiers.sorted { $0.rawValue < $1.rawValue }
        XCTAssertEqual(sortedHeads.count, 2)
        XCTAssertEqual(sortedHeads.first?.rawValue, "ABCD")
        XCTAssertEqual(sortedHeads.last?.rawValue, "CDEF")
        XCTAssertEqual(history.mostRecentHead?.id.rawValue, "CDEF")
        
        let versions: (Version.ID, Version.ID) = (.init("ABCD"), .init("CDEF"))
        XCTAssertNil(try history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions))
    }
    
    func testSimpleSerialHistory() {
        let version1 = Version(id: .init("ABCD"), predecessors: nil)
        try! history.add(version1, updatingPredecessorVersions: true)
        
        let predecessors = Version.Predecessors(idOfFirst: version1.id, idOfSecond: nil)
        let version2 = Version(id: .init("CDEF"), predecessors: predecessors)
        try! history.add(version2, updatingPredecessorVersions: true)
        
        let sortedHeads = history.headIdentifiers.sorted { $0.rawValue < $1.rawValue }
        XCTAssertEqual(sortedHeads.count, 1)
        XCTAssertEqual(sortedHeads.first?.rawValue, "CDEF")
        XCTAssertEqual(history.mostRecentHead?.id.rawValue, "CDEF")
        
        let versions: (Version.ID, Version.ID) = (.init("ABCD"), .init("CDEF"))
        let common = try! history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions)
        XCTAssertEqual(common, version1.id)
    }
    
    func testSerialHistory() {
        let version1 = Version(id: .init("ABCD"), predecessors: nil)
        try! history.add(version1, updatingPredecessorVersions: true)
        
        let predecessors2 = Version.Predecessors(idOfFirst: version1.id, idOfSecond: nil)
        let version2 = Version(id: .init("CDEF"), predecessors: predecessors2)
        try! history.add(version2, updatingPredecessorVersions: true)
        
        let predecessors3 = Version.Predecessors(idOfFirst: version2.id, idOfSecond: nil)
        let version3 = Version(id: .init("GHIJ"), predecessors: predecessors3)
        try! history.add(version3, updatingPredecessorVersions: true)
        
        let sortedHeads = history.headIdentifiers.sorted { $0.rawValue < $1.rawValue }
        XCTAssertEqual(sortedHeads.count, 1)
        XCTAssertEqual(sortedHeads.first?.rawValue, "GHIJ")
        XCTAssertEqual(history.mostRecentHead?.id.rawValue, "GHIJ")
        
        let versions: (Version.ID, Version.ID) = (.init("ABCD"), .init("GHIJ"))
        let common = try! history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions)
        XCTAssertEqual(common, version1.id)
    }
    
    func testBranch() {
        let version1 = Version(id: .init("ABCD"), predecessors: nil)
        try! history.add(version1, updatingPredecessorVersions: true)
        
        let predecessors2 = Version.Predecessors(idOfFirst: version1.id, idOfSecond: nil)
        let version2 = Version(id: .init("CDEF"), predecessors: predecessors2)
        try! history.add(version2, updatingPredecessorVersions: true)
        
        let predecessors3 = Version.Predecessors(idOfFirst: version1.id, idOfSecond: nil)
        let version3 = Version(id: .init("GHIJ"), predecessors: predecessors3)
        try! history.add(version3, updatingPredecessorVersions: true)
        
        let sortedHeads = history.headIdentifiers.sorted { $0.rawValue < $1.rawValue }
        XCTAssertEqual(sortedHeads.count, 2)
        XCTAssertEqual(sortedHeads.first?.rawValue, "CDEF")
        XCTAssertEqual(history.mostRecentHead?.id.rawValue, "GHIJ")
        
        let versions: (Version.ID, Version.ID) = (.init("CDEF"), .init("GHIJ"))
        let common = try! history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions)
        XCTAssertEqual(common, version1.id)
    }
    
    func testBranchAndMerge() {
        let version1 = Version(id: .init("ABCD"), predecessors: nil)
        try! history.add(version1, updatingPredecessorVersions: true)
        
        let predecessors2 = Version.Predecessors(idOfFirst: version1.id, idOfSecond: nil)
        let version2 = Version(id: .init("CDEF"), predecessors: predecessors2)
        try! history.add(version2, updatingPredecessorVersions: true)
        
        let predecessors3 = Version.Predecessors(idOfFirst: version1.id, idOfSecond: nil)
        let version3 = Version(id: .init("GHIJ"), predecessors: predecessors3)
        try! history.add(version3, updatingPredecessorVersions: true)
        
        let predecessors4 = Version.Predecessors(idOfFirst: version2.id, idOfSecond: version3.id)
        let version4 = Version(id: .init("KLMN"), predecessors: predecessors4)
        try! history.add(version4, updatingPredecessorVersions: true)
        
        let sortedHeads = history.headIdentifiers.sorted { $0.rawValue < $1.rawValue }
        XCTAssertEqual(sortedHeads.count, 1)
        XCTAssertEqual(sortedHeads.first?.rawValue, "KLMN")
        XCTAssertEqual(history.mostRecentHead?.id.rawValue, "KLMN")
        
        let versions: (Version.ID, Version.ID) = (.init("KLMN"), .init("GHIJ"))
        let common = try! history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions)
        XCTAssertEqual(common, version3.id)
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
