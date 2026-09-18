import Testing
import Foundation
@testable import LLVS

/// An exchange whose remote returns version metadata, but the wrong value changes.
private final class FaultyChangesExchange: Exchange {
    let store: Store
    let remoteVersions: [Version]
    var restorationState: Data?
    let newVersionsAvailable: AsyncStream<Void> = AsyncStream { $0.finish() }

    let changes: [Version.ID: [Value.Change]]

    init(store: Store, remoteVersions: [Version], changes: [Version.ID: [Value.Change]]) {
        self.store = store
        self.remoteVersions = remoteVersions
        self.changes = changes
    }

    func prepareToRetrieve() async throws {}
    func retrieveAllVersionIdentifiers() async throws -> [Version.ID] { remoteVersions.map { $0.id } }
    func retrieveVersions(identifiedBy versionIds: [Version.ID]) async throws -> [Version] { remoteVersions }
    func retrieveValueChanges(forVersionsIdentifiedBy versionIds: [Version.ID]) async throws -> [Version.ID: [Value.Change]] { changes }
    func prepareToSend() async throws {}
    func send(versionChanges: [VersionChanges]) async throws {}
}

@Suite class ExchangeRobustnessTests {

    let remoteStore: Store
    let localStore: Store
    let remoteURL: URL
    let localURL: URL

    init() throws {
        remoteURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        localURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        remoteStore = try Store(rootDirectoryURL: remoteURL)
        localStore = try Store(rootDirectoryURL: localURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: remoteURL)
        try? FileManager.default.removeItem(at: localURL)
    }

    @Test func retrieveThrowsWhenRemoteOmitsValueChanges() async throws {
        let value = Value(id: .init("ABCDEF"), data: "data".data(using: .utf8)!)
        let version = try remoteStore.makeVersion(basedOnPredecessor: nil, storing: [.insert(value)])
        let exchange = FaultyChangesExchange(store: localStore, remoteVersions: [version], changes: [:])

        await #expect {
            _ = try await exchange.retrieve()
        } throws: { error in
            guard case ExchangeError.missingValueChanges(let id) = error else { return false }
            return id == version.id
        }
        #expect(try localStore.version(identifiedBy: version.id) == nil)
    }

    @Test func retrieveIgnoresValueChangesForUnrequestedVersions() async throws {
        let value = Value(id: .init("ABCDEF"), data: "data".data(using: .utf8)!)
        let version = try remoteStore.makeVersion(basedOnPredecessor: nil, storing: [.insert(value)])
        let changes: [Version.ID: [Value.Change]] = [version.id: [.insert(value)], Version.ID("unrequested"): []]
        let exchange = FaultyChangesExchange(store: localStore, remoteVersions: [version], changes: changes)

        _ = try await exchange.retrieve()

        #expect(try localStore.version(identifiedBy: version.id) != nil)
    }
}
