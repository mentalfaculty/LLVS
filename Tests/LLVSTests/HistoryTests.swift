//
//  HistoryTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 12/11/2018.
//

import Testing
@testable import LLVS

@Suite struct HistoryTests {

    var history: History

    init() {
        history = History()
    }

    @Test func emptyHistory() {
        #expect(history.headIdentifiers.isEmpty)
        #expect(history.mostRecentHead == nil)

        let versions: (Version.ID, Version.ID) = (.init("ABCD"), .init("CDEF"))
        #expect(throws: (any Error).self) { try history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions) }
    }

    @Test mutating func singleVersion() throws {
        let version = Version(id: .init("ABCD"), predecessors: nil, valueDataSize: 0)
        try history.add(version, updatingPredecessorVersions: true)
        #expect(history.headIdentifiers.count == 1)
        #expect(history.headIdentifiers.first?.rawValue == "ABCD")
        #expect(history.mostRecentHead?.id.rawValue == "ABCD")

        let versions: (Version.ID, Version.ID) = (.init("ABCD"), .init("CDEF"))
        #expect(throws: (any Error).self) { try history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions) }
    }

    @Test mutating func addingVersionTwice() throws {
        let version = Version(id: .init("ABCD"), predecessors: nil, valueDataSize: 0)
        try history.add(version, updatingPredecessorVersions: true)
        #expect(throws: (any Error).self) { try history.add(version, updatingPredecessorVersions: true) }
    }

    @Test mutating func unrelatedVersions() throws {
        let version1 = Version(id: .init("ABCD"), predecessors: nil, valueDataSize: 0)
        try history.add(version1, updatingPredecessorVersions: true)

        let version2 = Version(id: .init("CDEF"), predecessors: nil, valueDataSize: 0)
        try history.add(version2, updatingPredecessorVersions: true)

        let sortedHeads = history.headIdentifiers.sorted { $0.rawValue < $1.rawValue }
        #expect(sortedHeads.count == 2)
        #expect(sortedHeads.first?.rawValue == "ABCD")
        #expect(sortedHeads.last?.rawValue == "CDEF")
        #expect(history.mostRecentHead?.id.rawValue == "CDEF")

        let versions: (Version.ID, Version.ID) = (.init("ABCD"), .init("CDEF"))
        #expect(try history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions) == nil)
    }

    @Test mutating func simpleSerialHistory() throws {
        let version1 = Version(id: .init("ABCD"), predecessors: nil, valueDataSize: 0)
        try history.add(version1, updatingPredecessorVersions: true)

        let predecessors = Version.Predecessors(idOfFirst: version1.id, idOfSecond: nil)
        let version2 = Version(id: .init("CDEF"), predecessors: predecessors, valueDataSize: 0)
        try history.add(version2, updatingPredecessorVersions: true)

        let sortedHeads = history.headIdentifiers.sorted { $0.rawValue < $1.rawValue }
        #expect(sortedHeads.count == 1)
        #expect(sortedHeads.first?.rawValue == "CDEF")
        #expect(history.mostRecentHead?.id.rawValue == "CDEF")

        let versions: (Version.ID, Version.ID) = (.init("ABCD"), .init("CDEF"))
        let common = try history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions)
        #expect(common == version1.id)
    }

    @Test mutating func serialHistory() throws {
        let version1 = Version(id: .init("ABCD"), predecessors: nil, valueDataSize: 0)
        try history.add(version1, updatingPredecessorVersions: true)

        let predecessors2 = Version.Predecessors(idOfFirst: version1.id, idOfSecond: nil)
        let version2 = Version(id: .init("CDEF"), predecessors: predecessors2, valueDataSize: 0)
        try history.add(version2, updatingPredecessorVersions: true)

        let predecessors3 = Version.Predecessors(idOfFirst: version2.id, idOfSecond: nil)
        let version3 = Version(id: .init("GHIJ"), predecessors: predecessors3, valueDataSize: 50000000)
        try history.add(version3, updatingPredecessorVersions: true)

        let sortedHeads = history.headIdentifiers.sorted { $0.rawValue < $1.rawValue }
        #expect(sortedHeads.count == 1)
        #expect(sortedHeads.first?.rawValue == "GHIJ")
        #expect(history.mostRecentHead?.id.rawValue == "GHIJ")

        let versions: (Version.ID, Version.ID) = (.init("ABCD"), .init("GHIJ"))
        let common = try history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions)
        #expect(common == version1.id)
    }

    @Test mutating func branch() throws {
        let version1 = Version(id: .init("ABCD"), predecessors: nil, valueDataSize: 0)
        try history.add(version1, updatingPredecessorVersions: true)

        let predecessors2 = Version.Predecessors(idOfFirst: version1.id, idOfSecond: nil)
        let version2 = Version(id: .init("CDEF"), predecessors: predecessors2, valueDataSize: 0)
        try history.add(version2, updatingPredecessorVersions: true)

        let predecessors3 = Version.Predecessors(idOfFirst: version1.id, idOfSecond: nil)
        let version3 = Version(id: .init("GHIJ"), predecessors: predecessors3, valueDataSize: 0)
        try history.add(version3, updatingPredecessorVersions: true)

        let sortedHeads = history.headIdentifiers.sorted { $0.rawValue < $1.rawValue }
        #expect(sortedHeads.count == 2)
        #expect(sortedHeads.first?.rawValue == "CDEF")
        #expect(history.mostRecentHead?.id.rawValue == "GHIJ")

        let versions: (Version.ID, Version.ID) = (.init("CDEF"), .init("GHIJ"))
        let common = try history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions)
        #expect(common == version1.id)
    }

    @Test mutating func branchAndMerge() throws {
        let version1 = Version(id: .init("ABCD"), predecessors: nil, valueDataSize: 0)
        try history.add(version1, updatingPredecessorVersions: true)

        let predecessors2 = Version.Predecessors(idOfFirst: version1.id, idOfSecond: nil)
        let version2 = Version(id: .init("CDEF"), predecessors: predecessors2, valueDataSize: 50000000)
        try history.add(version2, updatingPredecessorVersions: true)

        let predecessors3 = Version.Predecessors(idOfFirst: version1.id, idOfSecond: nil)
        let version3 = Version(id: .init("GHIJ"), predecessors: predecessors3, valueDataSize: 50000000)
        try history.add(version3, updatingPredecessorVersions: true)

        let predecessors4 = Version.Predecessors(idOfFirst: version2.id, idOfSecond: version3.id)
        let version4 = Version(id: .init("KLMN"), predecessors: predecessors4, valueDataSize: 50000000)
        try history.add(version4, updatingPredecessorVersions: true)

        let sortedHeads = history.headIdentifiers.sorted { $0.rawValue < $1.rawValue }
        #expect(sortedHeads.count == 1)
        #expect(sortedHeads.first?.rawValue == "KLMN")
        #expect(history.mostRecentHead?.id.rawValue == "KLMN")

        let versions: (Version.ID, Version.ID) = (.init("KLMN"), .init("GHIJ"))
        let common = try history.greatestCommonAncestor(ofVersionsIdentifiedBy: versions)
        #expect(common == version3.id)
    }
}
