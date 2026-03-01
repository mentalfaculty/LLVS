//
//  MemoryExchange.swift
//  LLVS
//
//  Created by Claude on 28/02/2026.
//

import Foundation
import Combine

public class MemoryExchange: Exchange {

    public let store: Store

    public let newVersionsSubject = PassthroughSubject<Void, Never>()

    public var newVersionsAvailable: AnyPublisher<Void, Never> {
        newVersionsSubject.eraseToAnyPublisher()
    }

    public var restorationState: Data? {
        get { return nil }
        set {}
    }

    private let queue = DispatchQueue(label: "llvs.memoryexchange")
    private var versionsByIdentifier: [Version.ID: Version] = [:]
    private var valueChangesByVersionIdentifier: [Version.ID: [Value.Change]] = [:]

    public init(store: Store) {
        self.store = store
    }

    public func prepareToRetrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        completionHandler(.success(()))
    }

    public func retrieveAllVersionIdentifiers(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID]>) {
        queue.async {
            let ids = Array(self.versionsByIdentifier.keys)
            completionHandler(.success(ids))
        }
    }

    public func retrieveVersions(identifiedBy versionIds: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version]>) {
        queue.async {
            var versions: [Version] = []
            for id in versionIds {
                if let version = self.versionsByIdentifier[id] {
                    versions.append(version)
                }
            }
            completionHandler(.success(versions))
        }
    }

    public func retrieveValueChanges(forVersionsIdentifiedBy versionIds: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID: [Value.Change]]>) {
        queue.async {
            var result: [Version.ID: [Value.Change]] = [:]
            for id in versionIds {
                if let changes = self.valueChangesByVersionIdentifier[id] {
                    result[id] = changes
                }
            }
            completionHandler(.success(result))
        }
    }

    public func prepareToSend(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        completionHandler(.success(()))
    }

    public func send(versionChanges: [VersionChanges], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        queue.async {
            for (version, valueChanges) in versionChanges {
                self.versionsByIdentifier[version.id] = version
                self.valueChangesByVersionIdentifier[version.id] = valueChanges
            }
            self.newVersionsSubject.send(())
            completionHandler(.success(()))
        }
    }
}
