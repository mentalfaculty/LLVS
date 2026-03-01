//
//  MemoryExchangeTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 01/03/2026.
//

import Testing
import Foundation
@testable import LLVS

@Suite class MemoryExchangeTests {

    let fm = FileManager.default

    let store1: Store
    let store2: Store
    let rootURL1: URL
    let rootURL2: URL
    let exchange1: MemoryExchange
    let exchange2: MemoryExchange

    init() throws {
        rootURL1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store1 = try Store(rootDirectoryURL: rootURL1)
        store2 = try Store(rootDirectoryURL: rootURL2)

        exchange1 = MemoryExchange(store: store1)
        exchange2 = MemoryExchange(store: store2)
    }

    deinit {
        try? fm.removeItem(at: rootURL1)
        try? fm.removeItem(at: rootURL2)
    }

    private func value(_ identifier: String, stringData: String) -> Value {
        return Value(id: .init(identifier), data: stringData.data(using: .utf8)!)
    }

    // MARK: - Tests

    @Test func sendPopulatesExchange() async throws {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        let versionIds = try await exchange1.send()
        #expect(versionIds.contains(ver.id))
    }

    @Test func retrieveFromSharedExchange() async throws {
        let shared = MemoryExchange(store: store1)
        let exchange2WithShared = MemoryExchange(store: store2)

        let val = value("CDEFGH", stringData: "Origin")
        let ver = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        // Send store1's versions into the shared exchange
        _ = try await shared.send()

        // Get version data from shared and populate exchange2WithShared
        let ids = try await shared.retrieveAllVersionIdentifiers()
        let versions = try await shared.retrieveVersions(identifiedBy: ids)
        let changesByVersion = try await shared.retrieveValueChanges(forVersionsIdentifiedBy: ids)

        let versionChanges: [VersionChanges] = versions.map { v in
            (v, changesByVersion[v.id] ?? [])
        }

        try await exchange2WithShared.send(versionChanges: versionChanges)
        let retrievedIds = try await exchange2WithShared.retrieve()

        #expect(retrievedIds.contains(ver.id))
        let retrievedVersion = try store2.version(identifiedBy: ver.id)
        #expect(ver == retrievedVersion)
        #expect(try store2.value(id: val.id, at: ver.id) != nil)
    }

    @Test func sendAndRetrieveMultipleVersions() async throws {
        let val1 = value("AAA", stringData: "First")
        let ver1 = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val1)])
        let val2 = value("BBB", stringData: "Second")
        let ver2 = try store1.makeVersion(basedOnPredecessor: ver1.id, storing: [.insert(val2)])

        let versionIds = try await exchange1.send()
        #expect(versionIds.count == 2)
        #expect(versionIds.contains(ver1.id))
        #expect(versionIds.contains(ver2.id))

        // Verify data is in exchange
        let ids = try await exchange1.retrieveAllVersionIdentifiers()
        #expect(ids.count == 2)
    }

    @Test func retrieveVersionsById() async throws {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        _ = try await exchange1.send()

        let versions = try await exchange1.retrieveVersions(identifiedBy: [ver.id])
        #expect(versions.count == 1)
        #expect(versions.first?.id == ver.id)
    }

    @Test func retrieveValueChanges() async throws {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        _ = try await exchange1.send()

        let changesByVersion = try await exchange1.retrieveValueChanges(forVersionsIdentifiedBy: [ver.id])
        #expect(changesByVersion.count == 1)
        #expect(changesByVersion[ver.id]?.count == 1)
    }

    @Test func retrieveMissingVersionsReturnsEmpty() async throws {
        let fakeId = Version.ID(UUID().uuidString)
        let versions = try await exchange1.retrieveVersions(identifiedBy: [fakeId])
        #expect(versions.count == 0)
    }

    @Test func restorationStateIsNil() {
        #expect(exchange1.restorationState == nil)
        exchange1.restorationState = Data([1, 2, 3])
        #expect(exchange1.restorationState == nil)
    }

    @Test func newVersionsAvailableStream() async throws {
        _ = try store1.makeVersion(basedOnPredecessor: nil, storing: [])

        // Start a task to listen for the notification
        let notified = Task<Bool, Never> {
            for await _ in exchange1.newVersionsAvailable {
                return true
            }
            return false
        }

        // Give the listener a moment to start
        try await Task.sleep(nanoseconds: 50_000_000)

        _ = try await exchange1.send()

        // Wait briefly for the notification
        let result = await Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            notified.cancel()
            return await notified.value
        }.value

        #expect(result)
    }

    @Test func sendEmptyIsNoOp() async throws {
        let ids = try await exchange1.send()
        #expect(ids.count == 0)
    }

    @Test func sendIdempotent() async throws {
        let val = value("CDEFGH", stringData: "Origin")
        _ = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        let ids1 = try await exchange1.send()
        #expect(ids1.count == 1)

        // Second send should have nothing new to send
        let ids2 = try await exchange1.send()
        #expect(ids2.count == 0)
    }
}
