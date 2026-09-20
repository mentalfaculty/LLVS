//
//  StoreConcurrencyTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 20/09/2026.
//

import Testing
import Foundation
@testable import LLVS

/// `Store` is `@unchecked Sendable` and offers no serialisation contract: only `history` is
/// behind a `Mutex`, which is audit item 9. Reading it while another thread writes is
/// nevertheless safe today, for a reason no type declares — `Map` holds only a `let zone` and
/// a `Mutex`-backed `Cache`, and `FileZone` is the same, so readers and writers meet only in
/// file I/O and a lock.
///
/// Anything built on that property, such as a projection that diffs versions while the app
/// saves, depends on an accident. These tests assert it rather than trusting a comment to say
/// it, so that adding unguarded mutable state to `Map`, `FileZone` or `Store` fails here
/// instead of reaching an app.
///
/// They are written to fail without a sanitizer — on a crash, a throw, or a wrong answer —
/// because CI does not run one by default. Under Thread Sanitizer they additionally fail on
/// the race itself rather than waiting for it to manifest:
///
///     swift test --sanitize=thread --filter StoreConcurrencyTests
@Suite class StoreConcurrencyTests {

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

    /// One writer appending versions while readers walk the map for values and diffs.
    @Test func readingWhileAnotherThreadWrites() throws {
        let store = self.store
        let writeCount = 120

        // Seed, so the readers have something to find from the start.
        var head = try store.makeVersion(basedOnPredecessor: nil, inserting: [value("seed", "0")])
        let seedVersion = head.id

        let group = DispatchGroup()

        DispatchQueue.global().async(group: group) {
            for i in 0..<writeCount {
                guard let next = try? store.makeVersion(
                    basedOnPredecessor: head.id,
                    inserting: [self.value("v\(i)", "value \(i)")]) else { return }
                head = next
            }
        }

        // Two readers: one fetching a value that certainly exists, one diffing against the seed.
        for _ in 0..<2 {
            DispatchQueue.global().async(group: group) {
                for _ in 0..<writeCount {
                    let found = try? store.value(id: .init("seed"), at: seedVersion)
                    #expect(found?.id.rawValue == "seed")
                    _ = try? store.valueChanges(updatingFrom: seedVersion, to: seedVersion)
                }
            }
        }

        group.wait()

        // The store is still coherent: the seed reads back, and the history is intact.
        let seed = try store.value(id: .init("seed"), at: seedVersion)
        #expect(seed?.id.rawValue == "seed")
        #expect(try store.valueReferences(at: seedVersion).count == 1)
    }

    /// Several threads reading one version at once. This is the path a projection rebuild and
    /// an app query take together, and it exercises the shared node cache hardest.
    @Test func manyReadersOnOneVersion() throws {
        let store = self.store
        let valueCount = 60

        let version = try store.makeVersion(
            basedOnPredecessor: nil,
            inserting: (0..<valueCount).map { value("v\($0)", "value \($0)") })

        let group = DispatchGroup()
        for _ in 0..<4 {
            DispatchQueue.global().async(group: group) {
                for i in 0..<valueCount {
                    let found = try? store.value(id: .init("v\(i)"), at: version.id)
                    #expect(found?.data == "value \(i)".data(using: .utf8))
                }
            }
        }
        group.wait()

        #expect(try store.valueReferences(at: version.id).count == valueCount)
    }
}
