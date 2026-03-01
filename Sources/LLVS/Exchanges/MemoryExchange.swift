//
//  MemoryExchange.swift
//  LLVS
//
//  Created by Drew McCormack on 28/02/2026.
//

import Foundation

public actor MemoryExchange: Exchange {

    nonisolated public let store: Store

    nonisolated public let newVersionsAvailable: AsyncStream<Void>
    private let newVersionsContinuation: AsyncStream<Void>.Continuation

    nonisolated public var restorationState: Data? {
        get { return nil }
        set {}
    }

    private var versionsByIdentifier: [Version.ID: Version] = [:]
    private var valueChangesByVersionIdentifier: [Version.ID: [Value.Change]] = [:]

    public init(store: Store) {
        self.store = store
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.newVersionsAvailable = stream
        self.newVersionsContinuation = continuation
    }

    public func prepareToRetrieve() async throws {
    }

    public func retrieveAllVersionIdentifiers() async throws -> [Version.ID] {
        return Array(versionsByIdentifier.keys)
    }

    public func retrieveVersions(identifiedBy versionIds: [Version.ID]) async throws -> [Version] {
        var versions: [Version] = []
        for id in versionIds {
            if let version = versionsByIdentifier[id] {
                versions.append(version)
            }
        }
        return versions
    }

    public func retrieveValueChanges(forVersionsIdentifiedBy versionIds: [Version.ID]) async throws -> [Version.ID: [Value.Change]] {
        var result: [Version.ID: [Value.Change]] = [:]
        for id in versionIds {
            if let changes = valueChangesByVersionIdentifier[id] {
                result[id] = changes
            }
        }
        return result
    }

    public func prepareToSend() async throws {
    }

    public func send(versionChanges: [VersionChanges]) async throws {
        for (version, valueChanges) in versionChanges {
            versionsByIdentifier[version.id] = version
            valueChangesByVersionIdentifier[version.id] = valueChanges
        }
        newVersionsContinuation.yield(())
    }
}
