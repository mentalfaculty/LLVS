//
//  FolderBasedExchange.swift
//  LLVS
//
//  Created by Drew McCormack on 01/03/2026.
//

import Foundation

public enum FolderBasedExchangeError: Error {
    case versionFileInvalid
    case fileNotFound(String)
    case foldersNotInitialized
}

public protocol FolderBasedExchange: Exchange {
    associatedtype FileID
    associatedtype FolderID

    var versionsFolderID: FolderID? { get }
    var changesFolderID: FolderID? { get }

    func notifyNewVersionsAvailable()
    func listFiles(inFolder folder: FolderID) async throws -> [String: FileID]
    func downloadData(forFile fileID: FileID) async throws -> Data
    func uploadData(_ data: Data, named name: String, toFolder folder: FolderID) async throws
}

public extension FolderBasedExchange {

    func retrieveAllVersionIdentifiers() async throws -> [Version.ID] {
        guard let folderID = versionsFolderID else { return [] }
        let fileMap = try await listFiles(inFolder: folderID)
        return fileMap.map { Version.ID($0.key) }
    }

    func retrieveVersions(identifiedBy versionIds: [Version.ID]) async throws -> [Version] {
        guard !versionIds.isEmpty else { return [] }
        guard let folderID = versionsFolderID else { return [] }

        let fileMap = try await listFiles(inFolder: folderID)
        var versions: [Version] = []
        for versionId in versionIds {
            guard let fileID = fileMap[versionId.rawValue] else {
                throw FolderBasedExchangeError.fileNotFound(versionId.rawValue)
            }
            let data = try await downloadData(forFile: fileID)
            if let version = try JSONDecoder().decode([String: Version].self, from: data)["version"] {
                versions.append(version)
            } else {
                throw FolderBasedExchangeError.versionFileInvalid
            }
        }
        return versions
    }

    func retrieveValueChanges(forVersionsIdentifiedBy versionIds: [Version.ID]) async throws -> [Version.ID: [Value.Change]] {
        guard !versionIds.isEmpty else { return [:] }
        guard let folderID = changesFolderID else { return [:] }

        let fileMap = try await listFiles(inFolder: folderID)
        var changesByVersion: [Version.ID: [Value.Change]] = [:]
        for versionId in versionIds {
            guard let fileID = fileMap[versionId.rawValue] else {
                throw FolderBasedExchangeError.fileNotFound(versionId.rawValue)
            }
            let data = try await downloadData(forFile: fileID)
            let changes = try JSONDecoder().decode([Value.Change].self, from: data)
            changesByVersion[versionId] = changes
        }
        return changesByVersion
    }

    func send(versionChanges: [VersionChanges]) async throws {
        guard !versionChanges.isEmpty else { return }
        guard let versionsFolderID = versionsFolderID,
              let changesFolderID = changesFolderID else {
            throw FolderBasedExchangeError.foldersNotInitialized
        }

        for (version, valueChanges) in versionChanges {
            let changesData = try JSONEncoder().encode(valueChanges)
            let versionData = try JSONEncoder().encode(["version": version])

            try await uploadData(changesData, named: version.id.rawValue, toFolder: changesFolderID)
            try await uploadData(versionData, named: version.id.rawValue, toFolder: versionsFolderID)
        }

        notifyNewVersionsAvailable()
    }
}
