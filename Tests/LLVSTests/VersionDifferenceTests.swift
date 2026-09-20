//
//  VersionDifferenceTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 20/09/2026.
//

import Testing
import Foundation
@testable import LLVS

@Suite class VersionDifferenceTests {

    let store: Store
    let rootURL: URL

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try Store(rootDirectoryURL: rootURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func value(_ id: String, _ text: String) -> Value {
        Value(id: .init(id), data: text.data(using: .utf8)!)
    }

    private func text(of value: Value) -> String {
        String(decoding: value.data, as: UTF8.self)
    }

    @Test func reportsAnInsertAlongALine() throws {
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [value("a", "one")])
        let v2 = try store.makeVersion(basedOnPredecessor: v1.id, inserting: [value("b", "two")])

        let changes = try store.valueChanges(updatingFrom: v1.id, to: v2.id)
        #expect(changes.count == 1)
        guard case let .insert(inserted) = changes.first else {
            Issue.record("expected an insert, got \(String(describing: changes.first))")
            return
        }
        #expect(inserted.id.rawValue == "b")
    }

    @Test func reportsAnUpdateAlongALine() throws {
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [value("a", "one")])
        let v2 = try store.makeVersion(basedOnPredecessor: v1.id, updating: [value("a", "two")])

        let changes = try store.valueChanges(updatingFrom: v1.id, to: v2.id)
        #expect(changes.count == 1)
        guard case let .update(updated) = changes.first else {
            Issue.record("expected an update, got \(String(describing: changes.first))")
            return
        }
        #expect(text(of: updated) == "two")
    }

    /// Moving the current version backwards must remove what the later version added.
    @Test func reportsARemovalWhenMovingBackwards() throws {
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [value("a", "one")])
        let v2 = try store.makeVersion(basedOnPredecessor: v1.id, inserting: [value("b", "two")])

        let changes = try store.valueChanges(updatingFrom: v2.id, to: v1.id)
        #expect(changes.count == 1)
        guard case let .remove(removedId) = changes.first else {
            Issue.record("expected a remove, got \(String(describing: changes.first))")
            return
        }
        #expect(removedId.rawValue == "b")
    }

    /// The case the older `valueChanges(madeBetween:and:)` traps on: two versions that are
    /// sideways from one another, so the fork is `.twiceUpdated` rather than single-branch.
    @Test func handlesTwoSidewaysVersionsWithoutTrapping() throws {
        let base = try store.makeVersion(basedOnPredecessor: nil, inserting: [value("a", "base")])
        let left = try store.makeVersion(basedOnPredecessor: base.id, updating: [value("a", "left")])
        let right = try store.makeVersion(basedOnPredecessor: base.id, updating: [value("a", "right")])

        let changes = try store.valueChanges(updatingFrom: left.id, to: right.id)
        #expect(changes.count == 1)
        guard case let .update(updated) = changes.first else {
            Issue.record("expected an update, got \(String(describing: changes.first))")
            return
        }
        #expect(text(of: updated) == "right")
    }

    /// Each branch inserted a different value. Moving between them must insert one and
    /// remove the other, even though neither existed at their common ancestor.
    @Test func handlesSidewaysInsertsInBothDirections() throws {
        let base = try store.makeVersion(basedOnPredecessor: nil, inserting: [value("a", "base")])
        let left = try store.makeVersion(basedOnPredecessor: base.id, inserting: [value("l", "left")])
        let right = try store.makeVersion(basedOnPredecessor: base.id, inserting: [value("r", "right")])

        let changes = try store.valueChanges(updatingFrom: left.id, to: right.id)
        #expect(changes.count == 2)

        let inserted = changes.compactMap { change -> String? in
            if case let .insert(value) = change { return value.id.rawValue }
            return nil
        }
        let removed = changes.compactMap { change -> String? in
            if case let .remove(id) = change { return id.rawValue }
            return nil
        }
        #expect(inserted == ["r"])
        #expect(removed == ["l"])
    }

    /// A value both ends resolve to the same stored version for is unchanged between them,
    /// however the diff came to mention it. Reporting it would have a consumer rewrite bytes
    /// it already has.
    @Test func reportsNothingForAValueBothEndsShare() throws {
        let base = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            value("shared", "same"), value("a", "one"),
        ])
        // Each branch changes something else, so "shared" is untouched by both and the two
        // heads still point at the copy stored in base.
        let left = try store.makeVersion(basedOnPredecessor: base.id, updating: [value("a", "left")])
        let right = try store.makeVersion(basedOnPredecessor: base.id, updating: [value("a", "right")])

        let changes = try store.valueChanges(updatingFrom: left.id, to: right.id)

        #expect(!changes.contains { change in
            if case let .update(value) = change { return value.id.rawValue == "shared" }
            if case let .insert(value) = change { return value.id.rawValue == "shared" }
            return false
        })
    }

    /// The ancestry shortcut must not change any answer. A branch far enough back that the
    /// bounded search cannot reach it falls through to the full common-ancestor walk, and both
    /// paths must agree with what the contents actually are.
    @Test func aDistantForkStillDiffsCorrectly() throws {
        var head = try store.makeVersion(basedOnPredecessor: nil, inserting: [value("a", "base")])
        let forkPoint = head.id

        // Walk well past the bounded search limit, so the shortcut cannot find the fork point.
        for i in 0..<150 {
            head = try store.makeVersion(basedOnPredecessor: head.id, inserting: [value("line\(i)", "x")])
        }
        let longBranch = head.id
        let shortBranch = try store.makeVersion(basedOnPredecessor: forkPoint,
            updating: [value("a", "other")]).id

        let changes = try store.valueChanges(updatingFrom: longBranch, to: shortBranch)

        // Everything the long branch added must go, and "a" must take the short branch's value.
        let removed = Set(changes.compactMap { change -> String? in
            if case let .remove(id) = change { return id.rawValue }
            return nil
        })
        #expect(removed.count == 150)
        #expect(changes.contains { change in
            if case let .update(value) = change { return text(of: value) == "other" }
            return false
        })
    }

    @Test func reportsNothingBetweenAVersionAndItself() throws {
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [value("a", "one")])
        #expect(try store.valueChanges(updatingFrom: v1.id, to: v1.id).isEmpty)
    }

    @Test func throwsForAVersionThatIsNotInTheStore() throws {
        let v1 = try store.makeVersion(basedOnPredecessor: nil, inserting: [value("a", "one")])
        #expect(throws: (any Swift.Error).self) {
            try self.store.valueChanges(updatingFrom: v1.id, to: .init("no-such-version"))
        }
    }

    /// Applying the returned changes to the contents at one version must give exactly
    /// the contents at the other. This is the property the projection depends on.
    @Test func applyingTheChangesReproducesTheTargetContents() throws {
        let base = try store.makeVersion(basedOnPredecessor: nil, inserting: [
            value("keep", "same"), value("change", "before"), value("drop", "gone"),
        ])
        let left = try store.makeVersion(basedOnPredecessor: base.id, inserting: [value("onlyLeft", "l")])
        let right = try store.makeVersion(basedOnPredecessor: base.id,
            updating: [value("change", "after")],
            removing: [.init("drop")])

        var contents: [String: String] = [:]
        try store.enumerate(version: left.id) { reference in
            if let value = try self.store.value(storedAt: reference) {
                contents[value.id.rawValue] = self.text(of: value)
            }
        }

        for change in try store.valueChanges(updatingFrom: left.id, to: right.id) {
            switch change {
            case let .insert(value), let .update(value):
                contents[value.id.rawValue] = text(of: value)
            case let .remove(id):
                contents.removeValue(forKey: id.rawValue)
            case .preserve, .preserveRemoval:
                Issue.record("preserve changes should never be returned")
            }
        }

        var expected: [String: String] = [:]
        try store.enumerate(version: right.id) { reference in
            if let value = try self.store.value(storedAt: reference) {
                expected[value.id.rawValue] = self.text(of: value)
            }
        }

        #expect(contents == expected)
    }
}
