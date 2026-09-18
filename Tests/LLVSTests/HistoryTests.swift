//
//  HistoryTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 12/11/2018.
//

import Testing
import Foundation
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

    @Test mutating func greatestCommonAncestorIsNotAnAncestorOfAnotherCommonAncestor() throws {
        // A - C - F            F is the first version
        // |    \
        // |     Q - B
        // |          \
        // P ---------- S       S merges P and B, and is the second version
        //
        // A and C are both common ancestors of F and S. C descends from A, so C is the greatest.
        // The shortest path from S to A (via P) is shorter than the path from S to C (via B and Q).
        func add(_ id: String, _ first: String? = nil, _ second: String? = nil) throws {
            let predecessors = first.map { Version.Predecessors(idOfFirst: .init($0), idOfSecond: second.map { .init($0) }) }
            try history.add(Version(id: .init(id), predecessors: predecessors, valueDataSize: 0), updatingPredecessorVersions: true)
        }
        try add("A")
        try add("C", "A")
        try add("P", "A")
        try add("F", "C")
        try add("Q", "C")
        try add("B", "Q")
        try add("S", "P", "B")

        #expect(try history.greatestCommonAncestor(ofVersionsIdentifiedBy: (.init("F"), .init("S")))?.rawValue == "C")
        #expect(try history.greatestCommonAncestor(ofVersionsIdentifiedBy: (.init("S"), .init("F")))?.rawValue == "C")
    }

    @Test mutating func greatestCommonAncestorDoesNotDependOnArgumentOrder() throws {
        // X and Y are equally valid common ancestors of F and S, but X is nearer to F, and Y is nearer to S.
        // R - X ----------- F          F merges X and Yc
        // |    \          /
        // |     Xb - Xc -/-- S         S merges Y and Xc
        // |             /   /
        // Y - Yb - Yc -    /
        //  \ -------------
        // The more recent of the two (Y) is chosen, whatever the argument order.
        func add(_ id: String, _ first: String? = nil, _ second: String? = nil, timestamp: TimeInterval) throws {
            let predecessors = first.map { Version.Predecessors(idOfFirst: .init($0), idOfSecond: second.map { .init($0) }) }
            var version = Version(id: .init(id), predecessors: predecessors, valueDataSize: 0)
            version.timestamp = timestamp
            try history.add(version, updatingPredecessorVersions: true)
        }
        try add("R", timestamp: 0)
        try add("X", "R", timestamp: 1)
        try add("Y", "R", timestamp: 2)
        try add("Xb", "X", timestamp: 3)
        try add("Xc", "Xb", timestamp: 4)
        try add("Yb", "Y", timestamp: 5)
        try add("Yc", "Yb", timestamp: 6)
        try add("F", "X", "Yc", timestamp: 7)
        try add("S", "Y", "Xc", timestamp: 8)

        #expect(try history.greatestCommonAncestor(ofVersionsIdentifiedBy: (.init("F"), .init("S")))?.rawValue == "Y")
        #expect(try history.greatestCommonAncestor(ofVersionsIdentifiedBy: (.init("S"), .init("F")))?.rawValue == "Y")
    }

    @Test mutating func greatestCommonAncestorIsFastForLongHistory() throws {
        // Guards against a quadratic walk. A linear walk of this history takes a small fraction of a second.
        var previous: Version.ID? = nil
        for i in 0..<20000 {
            let id = Version.ID("V\(i)")
            let predecessors = previous.map { Version.Predecessors(idOfFirst: $0, idOfSecond: nil) }
            try history.add(Version(id: id, predecessors: predecessors, valueDataSize: 0), updatingPredecessorVersions: true)
            previous = id
        }
        let tip = previous!
        for head in ["H1", "H2"] {
            let predecessors = Version.Predecessors(idOfFirst: tip, idOfSecond: nil)
            try history.add(Version(id: .init(head), predecessors: predecessors, valueDataSize: 0), updatingPredecessorVersions: true)
        }

        var common: Version.ID?
        let duration = try ContinuousClock().measure {
            common = try history.greatestCommonAncestor(ofVersionsIdentifiedBy: (.init("H1"), .init("H2")))
        }

        #expect(common == tip)
        #expect(duration < .seconds(2))
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
