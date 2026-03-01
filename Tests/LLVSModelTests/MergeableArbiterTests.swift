//
//  MergeableArbiterTests.swift
//  LLVSModelTests
//
//  Created by Drew McCormack on 01/03/2026.
//

import XCTest
import Foundation
@testable import LLVS
@testable import LLVSModel
import Forked
import ForkedMerge
import ForkedModel

// MARK: - Test Model Types

@ForkedModel
struct Contact: ModelValue, Equatable {
    static let modelTypeIdentifier = "Contact"
    var name: String = ""
    @Merged(using: .textMerge) var notes: String = ""
    var age: Int = 0
}

@ForkedModel
struct Tag: ModelValue, Equatable {
    static let modelTypeIdentifier = "Tag"
    var label: String = ""
}

// Disambiguate LLVS.Version from Forked.Version
typealias LLVSVersion = LLVS.Version

// MARK: - Tests

class MergeableArbiterTests: XCTestCase {

    var store: Store!
    var rootURL: URL!

    override func setUp() {
        super.setUp()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try! Store(rootDirectoryURL: rootURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeVersion(basedOn predecessor: LLVSVersion.ID?, changes: [Value.Change]) -> LLVSVersion {
        try! store.makeVersion(basedOnPredecessor: predecessor, storing: changes)
    }

    private func encode<T: Codable>(_ value: T) -> Data {
        try! JSONEncoder().encode(value)
    }

    // MARK: - Property-wise 3-way Merge

    func testThreeWayMergeResolvesPropertyWise() throws {
        let arbiter = MergeableArbiter()
        arbiter.register(Contact.self)

        let valueId = modelValueID(typeIdentifier: "Contact", instanceIdentifier: "abc")

        // Ancestor: name="Alice", notes="Hello", age=30
        let ancestor = Contact(name: "Alice", notes: "Hello", age: 30)
        let v0 = makeVersion(basedOn: nil, changes: [.insert(Value(id: valueId, data: encode(ancestor)))])

        // Branch 1: change name to "Bob"
        var branch1Contact = ancestor
        branch1Contact.name = "Bob"
        let v1 = makeVersion(basedOn: v0.id, changes: [.update(Value(id: valueId, data: encode(branch1Contact)))])

        // Branch 2: change age to 31
        var branch2Contact = ancestor
        branch2Contact.age = 31
        let v2 = makeVersion(basedOn: v0.id, changes: [.update(Value(id: valueId, data: encode(branch2Contact)))])

        // Merge
        let merged = try store.mergeRelated(version: v1.id, with: v2.id, resolvingWith: arbiter)
        let result = try store.value(id: valueId, at: merged.id)!
        let contact = try JSONDecoder().decode(Contact.self, from: result.data)

        XCTAssertEqual(contact.name, "Bob")
        XCTAssertEqual(contact.age, 31)
        XCTAssertEqual(contact.notes, "Hello")
    }

    // MARK: - Text Merge

    func testTextMergeOnNotesProperty() throws {
        let arbiter = MergeableArbiter()
        arbiter.register(Contact.self)

        let valueId = modelValueID(typeIdentifier: "Contact", instanceIdentifier: "text")

        // Ancestor
        let ancestor = Contact(name: "Alice", notes: "Line1\nLine2\nLine3", age: 30)
        let v0 = makeVersion(basedOn: nil, changes: [.insert(Value(id: valueId, data: encode(ancestor)))])

        // Branch 1: change first line
        var b1 = ancestor
        b1.notes = "Changed1\nLine2\nLine3"
        let v1 = makeVersion(basedOn: v0.id, changes: [.update(Value(id: valueId, data: encode(b1)))])

        // Branch 2: change last line
        var b2 = ancestor
        b2.notes = "Line1\nLine2\nChanged3"
        let v2 = makeVersion(basedOn: v0.id, changes: [.update(Value(id: valueId, data: encode(b2)))])

        let merged = try store.mergeRelated(version: v1.id, with: v2.id, resolvingWith: arbiter)
        let result = try store.value(id: valueId, at: merged.id)!
        let contact = try JSONDecoder().decode(Contact.self, from: result.data)

        XCTAssertEqual(contact.notes, "Changed1\nLine2\nChanged3")
    }

    // MARK: - Twice Inserted (salvaging)

    func testTwiceInsertedUsesSalvaging() throws {
        let arbiter = MergeableArbiter()
        arbiter.register(Contact.self)

        let valueId = modelValueID(typeIdentifier: "Contact", instanceIdentifier: "new")

        // Two branches independently insert the same key (no common ancestor with that value)
        let v0 = makeVersion(basedOn: nil, changes: [])

        let c1 = Contact(name: "Alice", notes: "", age: 25)
        let v1 = makeVersion(basedOn: v0.id, changes: [.insert(Value(id: valueId, data: encode(c1)))])

        let c2 = Contact(name: "Bob", notes: "", age: 30)
        let v2 = makeVersion(basedOn: v0.id, changes: [.insert(Value(id: valueId, data: encode(c2)))])

        let merged = try store.mergeRelated(version: v1.id, with: v2.id, resolvingWith: arbiter)
        let result = try store.value(id: valueId, at: merged.id)!
        let contact = try JSONDecoder().decode(Contact.self, from: result.data)

        // Default salvaging returns self (dominant/first), so first branch wins
        XCTAssertEqual(contact.name, "Alice")
    }

    // MARK: - Removed and Updated

    func testRemovedAndUpdatedFavorsUpdate() throws {
        let arbiter = MergeableArbiter()
        arbiter.register(Contact.self)

        let valueId = modelValueID(typeIdentifier: "Contact", instanceIdentifier: "ru")

        let ancestor = Contact(name: "Alice", notes: "", age: 30)
        let v0 = makeVersion(basedOn: nil, changes: [.insert(Value(id: valueId, data: encode(ancestor)))])

        // Branch 1: remove
        let v1 = makeVersion(basedOn: v0.id, changes: [.remove(valueId)])

        // Branch 2: update
        var updated = ancestor
        updated.name = "Bob"
        let v2 = makeVersion(basedOn: v0.id, changes: [.update(Value(id: valueId, data: encode(updated)))])

        let merged = try store.mergeRelated(version: v1.id, with: v2.id, resolvingWith: arbiter)
        let result = try store.value(id: valueId, at: merged.id)
        XCTAssertNotNil(result, "Value should be preserved (update wins over remove)")

        let contact = try JSONDecoder().decode(Contact.self, from: result!.data)
        XCTAssertEqual(contact.name, "Bob")
    }

    // MARK: - Fallback Arbiter

    func testUnregisteredTypeFallsBackToDefaultArbiter() throws {
        let arbiter = MergeableArbiter()
        // Intentionally do NOT register any types

        let valueId = Value.ID("untyped/thing")

        let v0 = makeVersion(basedOn: nil, changes: [.insert(Value(id: valueId, data: "old".data(using: .utf8)!))])

        let v1 = makeVersion(basedOn: v0.id, changes: [.update(Value(id: valueId, data: "branch1".data(using: .utf8)!))])
        let v2 = makeVersion(basedOn: v0.id, changes: [.update(Value(id: valueId, data: "branch2".data(using: .utf8)!))])

        // Should not throw — fallback arbiter resolves it
        let merged = try store.mergeRelated(version: v1.id, with: v2.id, resolvingWith: arbiter)
        let result = try store.value(id: valueId, at: merged.id)
        XCTAssertNotNil(result)
    }

    // MARK: - StoreCoordinator Typed Save/Fetch

    func testStoreCoordinatorSaveAndFetchRoundTrip() throws {
        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let coordinator = try StoreCoordinator(withStoreDirectoryAt: rootURL, cacheDirectoryAt: cacheURL)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let contact = Contact(name: "Alice", notes: "Met at WWDC", age: 30)
        try coordinator.save(contact, instanceIdentifier: "abc")

        let fetched: Contact? = try coordinator.fetchModel(Contact.self, instanceIdentifier: "abc")
        XCTAssertEqual(fetched?.name, "Alice")
        XCTAssertEqual(fetched?.notes, "Met at WWDC")
        XCTAssertEqual(fetched?.age, 30)
    }

    // MARK: - fetchAllModels

    func testFetchAllModelsReturnsCorrectTypeSubset() throws {
        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let coordinator = try StoreCoordinator(withStoreDirectoryAt: rootURL, cacheDirectoryAt: cacheURL)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        try coordinator.save(Contact(name: "Alice", notes: "", age: 30), instanceIdentifier: "a")
        try coordinator.save(Contact(name: "Bob", notes: "", age: 25), instanceIdentifier: "b")
        try coordinator.save(Tag(label: "VIP"), instanceIdentifier: "t1")

        let contacts: [Contact] = try coordinator.fetchAllModels(Contact.self)
        XCTAssertEqual(contacts.count, 2)

        let tags: [Tag] = try coordinator.fetchAllModels(Tag.self)
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags.first?.label, "VIP")
    }

    // MARK: - Value.ID Helpers

    func testModelValueIDHelpers() {
        let valueId = modelValueID(typeIdentifier: "Contact", instanceIdentifier: "abc-123")
        XCTAssertEqual(valueId.rawValue, "Contact/abc-123")
        XCTAssertEqual(modelTypeIdentifier(from: valueId), "Contact")
        XCTAssertEqual(instanceIdentifier(from: valueId), "abc-123")
    }

    func testHelperReturnsNilForNoSlash() {
        let valueId = Value.ID("noslash")
        XCTAssertNil(modelTypeIdentifier(from: valueId))
        XCTAssertNil(instanceIdentifier(from: valueId))
    }
}
