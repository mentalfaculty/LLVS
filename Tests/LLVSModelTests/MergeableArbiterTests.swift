//
//  MergeableArbiterTests.swift
//  LLVSModelTests
//
//  Created by Drew McCormack on 01/03/2026.
//

import Testing
import Foundation
@testable import LLVS
@testable import LLVSModel

// MARK: - Test Model Types

@MergeableModel
struct Contact: ModelValue, Equatable {
    static let modelTypeIdentifier = "Contact"
    var name: String = ""
    var notes: String = ""
    var age: Int = 0
}

@MergeableModel
struct Tag: ModelValue, Equatable {
    static let modelTypeIdentifier = "Tag"
    var label: String = ""
}

// MARK: - Tests

@Suite class MergeableArbiterTests {

    let store: Store
    let rootURL: URL

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store = try Store(rootDirectoryURL: rootURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    // MARK: - Helpers

    private func makeVersion(basedOn predecessor: Version.ID?, changes: [Value.Change]) -> Version {
        try! store.makeVersion(basedOnPredecessor: predecessor, storing: changes)
    }

    private func encode<T: Codable>(_ value: T) -> Data {
        try! JSONEncoder().encode(value)
    }

    // MARK: - Property-wise 3-way Merge

    @Test func threeWayMergeResolvesPropertyWise() throws {
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

        #expect(contact.name == "Bob")
        #expect(contact.age == 31)
        #expect(contact.notes == "Hello")
    }

    // MARK: - Twice Inserted (salvaging)

    @Test func twiceInsertedUsesSalvaging() throws {
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
        #expect(contact.name == "Alice")
    }

    // MARK: - Removed and Updated

    @Test func removedAndUpdatedFavorsUpdate() throws {
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
        #expect(result != nil, "Value should be preserved (update wins over remove)")

        let contact = try JSONDecoder().decode(Contact.self, from: result!.data)
        #expect(contact.name == "Bob")
    }

    // MARK: - Fallback Arbiter

    @Test func unregisteredTypeFallsBackToDefaultArbiter() throws {
        let arbiter = MergeableArbiter()
        // Intentionally do NOT register any types

        let valueId = Value.ID("untyped/thing")

        let v0 = makeVersion(basedOn: nil, changes: [.insert(Value(id: valueId, data: "old".data(using: .utf8)!))])

        let v1 = makeVersion(basedOn: v0.id, changes: [.update(Value(id: valueId, data: "branch1".data(using: .utf8)!))])
        let v2 = makeVersion(basedOn: v0.id, changes: [.update(Value(id: valueId, data: "branch2".data(using: .utf8)!))])

        // Should not throw — fallback arbiter resolves it
        let merged = try store.mergeRelated(version: v1.id, with: v2.id, resolvingWith: arbiter)
        let result = try store.value(id: valueId, at: merged.id)
        #expect(result != nil)
    }

    // MARK: - StoreCoordinator Typed Save/Fetch

    @Test func storeCoordinatorSaveAndFetchRoundTrip() throws {
        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let coordinator = try StoreCoordinator(withStoreDirectoryAt: rootURL, cacheDirectoryAt: cacheURL)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let contact = Contact(name: "Alice", notes: "Met at WWDC", age: 30)
        try coordinator.save(contact, instanceIdentifier: "abc")

        let fetched: Contact? = try coordinator.fetchModel(Contact.self, instanceIdentifier: "abc")
        #expect(fetched?.name == "Alice")
        #expect(fetched?.notes == "Met at WWDC")
        #expect(fetched?.age == 30)
    }

    // MARK: - fetchAllModels

    @Test func fetchAllModelsReturnsCorrectTypeSubset() throws {
        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let coordinator = try StoreCoordinator(withStoreDirectoryAt: rootURL, cacheDirectoryAt: cacheURL)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        try coordinator.save(Contact(name: "Alice", notes: "", age: 30), instanceIdentifier: "a")
        try coordinator.save(Contact(name: "Bob", notes: "", age: 25), instanceIdentifier: "b")
        try coordinator.save(Tag(label: "VIP"), instanceIdentifier: "t1")

        let contacts: [Contact] = try coordinator.fetchAllModels(Contact.self)
        #expect(contacts.count == 2)

        let tags: [Tag] = try coordinator.fetchAllModels(Tag.self)
        #expect(tags.count == 1)
        #expect(tags.first?.label == "VIP")
    }

    // MARK: - Value.ID Helpers

    @Test func modelValueIDHelpers() {
        let valueId = modelValueID(typeIdentifier: "Contact", instanceIdentifier: "abc-123")
        #expect(valueId.rawValue == "Contact/abc-123")
        #expect(modelTypeIdentifier(from: valueId) == "Contact")
        #expect(instanceIdentifier(from: valueId) == "abc-123")
    }

    @Test func helperReturnsNilForNoSlash() {
        let valueId = Value.ID("noslash")
        #expect(modelTypeIdentifier(from: valueId) == nil)
        #expect(instanceIdentifier(from: valueId) == nil)
    }
}
