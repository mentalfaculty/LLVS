//
//  FileSystemExchangeTests.swift
//  LLVSTests
//
//  Created by Drew McCormack on 08/03/2019.
//

import Testing
import Foundation
@testable import LLVS

@Suite class FileSystemExchangeTests {

    let fm = FileManager.default

    let store1: Store
    let store2: Store
    let rootURL1: URL
    let rootURL2: URL
    let exchangeURL: URL
    var exchange1: FileSystemExchange
    var exchange2: FileSystemExchange

    let recentChangeArbiter: MostRecentChangeFavoringArbiter

    init() throws {
        rootURL1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        rootURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        store1 = try Store(rootDirectoryURL: rootURL1)
        store2 = try Store(rootDirectoryURL: rootURL2)
        recentChangeArbiter = MostRecentChangeFavoringArbiter()
        exchangeURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        exchange1 = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store1, usesFileCoordination: false)
        exchange2 = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store2, usesFileCoordination: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL1)
        try? FileManager.default.removeItem(at: rootURL2)
        try? FileManager.default.removeItem(at: exchangeURL)
    }

    private func value(_ identifier: String, stringData: String) -> Value {
        return Value(id: .init(identifier), data: stringData.data(using: .utf8)!)
    }

    private var changeFiles: [URL] {
        return try! fm.contentsOfDirectory(at: exchangeURL.appendingPathComponent("changes"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    }

    private var versionFiles: [URL] {
        return try! fm.contentsOfDirectory(at: exchangeURL.appendingPathComponent("versions"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    }

    @Test func sendFiles() async throws {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])
        #expect(changeFiles.count == 0)
        #expect(versionFiles.count == 0)

        let versionIds = try await exchange1.send()
        #expect(versionIds.contains(ver.id))
        #expect(changeFiles.count == 1)
        #expect(versionFiles.count == 1)
    }

    @Test func receiveFiles() async throws {
        let val = value("CDEFGH", stringData: "Origin")
        let ver = try store1.makeVersion(basedOnPredecessor: nil, storing: [.insert(val)])

        _ = try await exchange1.send()
        let versionIds = try await exchange2.retrieve()

        #expect(versionIds.contains(ver.id))
        let retrievedVersion = try store2.version(identifiedBy: ver.id)
        #expect(ver == retrievedVersion)
        #expect(try store2.value(id: val.id, at: ver.id) != nil)
    }

    @Test func concurrentChanges() async throws {
        let origin = try store1.makeVersion(basedOnPredecessor: nil, storing: [])
        _ = try await exchange1.send()
        _ = try await exchange2.retrieve()

        func add(numberOfVersions: Int, store: Store) -> ([Version], [Value]) {
            var versions: [Version] = []
            var values: [Value] = []
            for _ in 0..<numberOfVersions {
                let id = UUID().uuidString
                let val = value(id, stringData: id)
                let ver = try! store.makeVersion(basedOnPredecessor: versions.last?.id ?? origin.id, storing: [.insert(val)])
                versions.append(ver)
                values.append(val)
            }
            return (versions, values)
        }

        let (versions1, values1) = add(numberOfVersions: 3, store: store1)
        let (versions2, values2) = add(numberOfVersions: 3, store: store2)

        _ = try await exchange1.send()
        _ = try await exchange2.retrieve()
        _ = try await exchange2.send()
        _ = try await exchange1.retrieve()

        versions1.forEach { #expect(try! self.store2.version(identifiedBy: $0.id) != nil) }
        versions2.forEach { #expect(try! self.store1.version(identifiedBy: $0.id) != nil) }
        for (ver, val) in zip(versions1, values1) {
            let val2 = try store2.value(id: val.id, storedAt: ver.id)!
            #expect(val.data == val2.data)
        }
        for (ver, val) in zip(versions2, values2) {
            let val1 = try store1.value(id: val.id, storedAt: ver.id)!
            #expect(val.data == val1.data)
        }

        let merge = try store1.mergeRelated(version: versions1.last!.id, with: versions2.last!.id, resolvingWith: MostRecentBranchFavoringArbiter())
        _ = try await exchange1.send()
        _ = try await exchange2.retrieve()

        #expect(try store2.version(identifiedBy: merge.id) != nil)
        for val in values1 + values2 {
            let val2 = try store2.value(id: val.id, at: merge.id)!
            #expect(val.data == val2.data)
        }
    }

    @Test func newVersionAvailableNotification() async throws {
        exchange1 = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store1, usesFileCoordination: true)
        exchange2 = FileSystemExchange(rootDirectoryURL: exchangeURL, store: store2, usesFileCoordination: true)

        _ = try store1.makeVersion(basedOnPredecessor: nil, storing: [])

        // Start listening before sending
        let notified = Task<Bool, Never> {
            for await _ in exchange2.newVersionsAvailable {
                return true
            }
            return false
        }

        // Give the listener a moment to start
        try await Task.sleep(nanoseconds: 50_000_000)

        _ = try await exchange1.send()

        // Wait briefly for the notification
        let result = await Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            notified.cancel()
            return await notified.value
        }.value

        #expect(result)
    }
}
