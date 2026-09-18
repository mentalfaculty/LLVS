import Testing
import Foundation
@testable import LLVS

/// Resolves nothing, so any merge with a conflict fails. Merges without conflicts succeed.
private final class ConflictRefusingArbiter: MergeArbiter {
    func changes(toResolve merge: Merge, in store: Store) throws -> [Value.Change] { [] }
}

@Suite class StoreCoordinatorTests {

    let rootURL: URL
    let coordinator: StoreCoordinator

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        coordinator = try StoreCoordinator(withStoreDirectoryAt: rootURL.appendingPathComponent("store"), cacheDirectoryAt: rootURL.appendingPathComponent("cache"))
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func value(_ id: String, _ string: String) -> Value {
        Value(id: .init(id), data: string.data(using: .utf8)!)
    }

    private func string(_ id: String) throws -> String? {
        try coordinator.value(id: .init(id)).flatMap { String(data: $0.data, encoding: .utf8) }
    }

    @Test func mergeKeepsHeadsThatMergedWhenAnotherHeadFails() throws {
        try coordinator.save(inserting: [value("GOOD", "old"), value("BAD", "old")])
        let base = coordinator.currentVersion

        // Two other heads, as if retrieved from other devices. Only the second conflicts with the local edit.
        _ = try coordinator.store.makeVersion(basedOnPredecessor: base, updating: [value("GOOD", "remote")])
        _ = try coordinator.store.makeVersion(basedOnPredecessor: base, updating: [value("BAD", "remote")])
        try coordinator.save(updating: [value("BAD", "local")])

        coordinator.mergeArbiter = ConflictRefusingArbiter()
        #expect(throws: (any Error).self) { try coordinator.merge() }

        #expect(try string("GOOD") == "remote")
        #expect(try string("BAD") == "local")
    }

    @Test func branchMetadataThatIsNotAStringIsTreatedAsNoBranch() throws {
        // Metadata can come from another device, so a value of the wrong type must not trap.
        try coordinator.save(inserting: [value("A", "a")])
        let version = try coordinator.store.makeVersion(basedOnPredecessor: coordinator.currentVersion, updating: [value("A", "b")], metadata: [.branch: .init(42)])

        #expect(coordinator.store.heads(withBranch: Branch(rawValue: "42")).isEmpty)
        #expect(coordinator.store.headsToMerge(into: coordinator.currentVersion) == [version.id])
    }
}
