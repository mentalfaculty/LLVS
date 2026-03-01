//
//  MultipeerExchangeTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 01/03/2026.
//

import Testing
import Foundation
@testable import LLVS

/// A mock transport that routes data between two MultipeerExchange instances.
class MockPeerTransport: PeerTransport {
    var peers: [String: MultipeerExchange] = [:]

    func send(_ data: Data, toPeer peerID: String) throws {
        guard let exchange = peers[peerID] else {
            throw MultipeerExchange.Error.transportUnavailable
        }
        // Deliver asynchronously to simulate real network
        Task {
            exchange.receiveData(data)
        }
    }
}

@Suite class MultipeerExchangeTests {

    let fm = FileManager.default

    let store1: Store
    let store2: Store
    let rootURL1: URL
    let rootURL2: URL
    let exchange1: MultipeerExchange
    let exchange2: MultipeerExchange
    let transport: MockPeerTransport

    init() throws {
        rootURL1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store1 = try Store(rootDirectoryURL: rootURL1)
        store2 = try Store(rootDirectoryURL: rootURL2)

        transport = MockPeerTransport()

        // exchange1 sends to "peer2", exchange2 sends to "peer1"
        exchange1 = MultipeerExchange(store: store1, peerID: "peer2", transport: transport)
        exchange2 = MultipeerExchange(store: store2, peerID: "peer1", transport: transport)

        // Register exchanges so transport can deliver messages
        transport.peers["peer1"] = exchange1
        transport.peers["peer2"] = exchange2
    }

    deinit {
        try? fm.removeItem(at: rootURL1)
        try? fm.removeItem(at: rootURL2)
    }

    private func value(_ identifier: String, stringData: String) -> Value {
        return Value(id: .init(identifier), data: stringData.data(using: .utf8)!)
    }

    // MARK: - Tests

    @Test func retrieveVersionIdentifiers() async throws {
        let val = value("AABBCC", stringData: "Hello")
        _ = try store2.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        let ids = try await exchange1.retrieveAllVersionIdentifiers()
        #expect(ids.count == 1)
    }

    @Test func retrieveVersions() async throws {
        let val = value("AABBCC", stringData: "Hello")
        let ver = try store2.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        let versions = try await exchange1.retrieveVersions(identifiedBy: [ver.id])
        #expect(versions.count == 1)
        #expect(versions.first?.id == ver.id)
    }

    @Test func retrieveValueChanges() async throws {
        let val = value("AABBCC", stringData: "Hello")
        let ver = try store2.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        let changesByVersion = try await exchange1.retrieveValueChanges(forVersionsIdentifiedBy: [ver.id])
        #expect(changesByVersion.count == 1)
        #expect(changesByVersion[ver.id]?.count == 1)
    }

    @Test func fullSendThenRetrieveCycle() async throws {
        let val = value("AABBCC", stringData: "Hello")
        let ver = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        // Send from store1 to store2's exchange
        let sentIds = try await exchange1.send()
        #expect(sentIds.contains(ver.id))

        // Retrieve into store2 from store1's exchange
        let retrievedIds = try await exchange2.retrieve()
        #expect(retrievedIds.contains(ver.id))

        // Verify store2 now has the version
        let storedVersion = try store2.version(identifiedBy: ver.id)
        #expect(storedVersion != nil)

        // Verify value is accessible
        let storedVal = try store2.value(id: val.id, at: ver.id)
        #expect(storedVal != nil)
        #expect(storedVal?.data == val.data)
    }

    @Test func bidirectionalSync() async throws {
        // Store1 creates a version
        let val1 = value("AAA", stringData: "From store1")
        let ver1 = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val1)])

        // Store2 creates a version
        let val2 = value("BBB", stringData: "From store2")
        let ver2 = try store2.makeVersion(basedOnPredecessor: nil, storing: [.insert(val2)])

        // Send from store1 -> store2's exchange
        _ = try await exchange1.send()

        // Retrieve into store2 from store1's exchange
        _ = try await exchange2.retrieve()

        // Send from store2 -> store1's exchange
        _ = try await exchange2.send()

        // Retrieve into store1 from store2's exchange
        _ = try await exchange1.retrieve()

        // Both stores should have both versions
        #expect(try store1.version(identifiedBy: ver2.id) != nil)
        #expect(try store2.version(identifiedBy: ver1.id) != nil)
    }

    @Test func pushToRecipient() async throws {
        let val = value("PUSHVAL", stringData: "Pushed data")
        let ver = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        // Prepare the version changes to push
        let changes = try store1.valueChanges(madeInVersionIdentifiedBy: ver.id)
        let versionChanges: [VersionChanges] = [(ver, changes)]

        try await exchange1.send(versionChanges: versionChanges)

        // Poll for async delivery (push is fire-and-forget with two async hops)
        var storedVersion: Version? = nil
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            storedVersion = try store2.version(identifiedBy: ver.id)
            if storedVersion != nil { break }
        }

        #expect(storedVersion != nil)
    }

    @Test func timeoutOnDisconnectedPeer() async throws {
        // Create an exchange with no transport
        let disconnectedExchange = MultipeerExchange(store: store1, peerID: "nonexistent", transport: nil)

        do {
            _ = try await disconnectedExchange.retrieveAllVersionIdentifiers()
            Issue.record("Should have thrown transportUnavailable")
        } catch MultipeerExchange.Error.transportUnavailable {
            // Expected
        }
    }

    @Test func emptyStoreReturnsNoVersions() async throws {
        let ids = try await exchange1.retrieveAllVersionIdentifiers()
        #expect(ids.count == 0)
    }

    @Test func newVersionsAvailableOnPush() async throws {
        let val = value("NOTIFY", stringData: "Notification test")
        let ver = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        // Listen for new versions on exchange2
        let notified = Task<Bool, Never> {
            for await _ in exchange2.newVersionsAvailable {
                return true
            }
            return false
        }

        // Give the listener time to start
        try await Task.sleep(nanoseconds: 50_000_000)

        // Push from store1 to store2
        let changes = try store1.valueChanges(madeInVersionIdentifiedBy: ver.id)
        try await exchange1.send(versionChanges: [(ver, changes)])

        // Wait for notification
        let result = await Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            notified.cancel()
            return await notified.value
        }.value

        #expect(result)
    }
}
