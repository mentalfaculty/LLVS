//
//  PCloudExchange.swift
//  LLVS
//
//  Created by Drew McCormack on 28/02/2026.
//

import Foundation
import LLVS
import PCloudSDKSwift

/// An Exchange that syncs versions via the pCloud Swift SDK.
///
/// Data is stored in a named folder on pCloud, organized as:
/// - `versions/` — JSON-encoded version metadata, one file per version
/// - `changes/` — JSON-encoded value changes, one file per version
///
/// Uses `PCloudClient` from the official pCloud SDK for all API operations.
/// Folder IDs are cached via `restorationState` to avoid repeated lookups.
public class PCloudExchange: Exchange {

    public enum Error: Swift.Error {
        case versionFileInvalid
        case fileNotFound(String)
        case missingDownloadLink
        case invalidResponse
        case foldersNotInitialized
    }

    public let store: Store

    /// The pCloud client used for API calls. Create via `PCloud.createClient(with:hostProvider:)`.
    public let client: PCloudClient

    /// Parent folder ID on pCloud where the LLVS folder will be created. 0 = root.
    public let parentFolderID: UInt64

    /// Name of the folder on pCloud that holds LLVS data.
    public let folderName: String

    /// URL session used for downloading file data from pCloud CDN links.
    private let urlSession: URLSession

    @Atomic private var restoration = RestorationInfo()

    public let newVersionsAvailable: AsyncStream<Void>
    private let newVersionsContinuation: AsyncStream<Void>.Continuation

    public var restorationState: Data? {
        get { try? JSONEncoder().encode(restoration) }
        set {
            if let data = newValue, let info = try? JSONDecoder().decode(RestorationInfo.self, from: data) {
                restoration = info
            }
        }
    }

    /// - Parameters:
    ///   - store: The LLVS store to sync.
    ///   - client: A `PCloudClient` instance, created via `PCloud.createClient(with:hostProvider:)`.
    ///   - parentFolderID: pCloud folder ID in which to create the LLVS folder. Defaults to 0 (root).
    ///   - folderName: Name of the folder to create for LLVS data. Defaults to "LLVS".
    ///   - urlSession: URLSession for downloading file content from CDN links. Defaults to `.shared`.
    public init(store: Store, client: PCloudClient, parentFolderID: UInt64 = 0, folderName: String = "LLVS", urlSession: URLSession = .shared) {
        self.store = store
        self.client = client
        self.parentFolderID = parentFolderID
        self.folderName = folderName
        self.urlSession = urlSession
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.newVersionsAvailable = stream
        self.newVersionsContinuation = continuation
    }

    // MARK: - Retrieve

    public func prepareToRetrieve() async throws {
        try await ensureFoldersExist()
    }

    public func retrieveAllVersionIdentifiers() async throws -> [Version.ID] {
        guard let folderID = restoration.versionsFolderID else {
            return []
        }
        let fileMap = try await listFileNames(inFolder: folderID)
        return fileMap.map { Version.ID($0.key) }
    }

    public func retrieveVersions(identifiedBy versionIds: [Version.ID]) async throws -> [Version] {
        guard !versionIds.isEmpty else { return [] }
        guard let folderID = restoration.versionsFolderID else { return [] }

        let fileMap = try await listFileNames(inFolder: folderID)
        var versions: [Version] = []
        for versionId in versionIds {
            guard let fileID = fileMap[versionId.rawValue] else {
                throw Error.fileNotFound(versionId.rawValue)
            }
            let data = try await downloadFileData(fileID: fileID)
            if let version = try JSONDecoder().decode([String: Version].self, from: data)["version"] {
                versions.append(version)
            } else {
                throw Error.versionFileInvalid
            }
        }
        return versions
    }

    public func retrieveValueChanges(forVersionsIdentifiedBy versionIds: [Version.ID]) async throws -> [Version.ID: [Value.Change]] {
        guard !versionIds.isEmpty else { return [:] }
        guard let folderID = restoration.changesFolderID else { return [:] }

        let fileMap = try await listFileNames(inFolder: folderID)
        var changesByVersion: [Version.ID: [Value.Change]] = [:]
        for versionId in versionIds {
            guard let fileID = fileMap[versionId.rawValue] else {
                throw Error.fileNotFound(versionId.rawValue)
            }
            let data = try await downloadFileData(fileID: fileID)
            let changes = try JSONDecoder().decode([Value.Change].self, from: data)
            changesByVersion[versionId] = changes
        }
        return changesByVersion
    }

    // MARK: - Send

    public func prepareToSend() async throws {
        try await ensureFoldersExist()
    }

    public func send(versionChanges: [VersionChanges]) async throws {
        guard !versionChanges.isEmpty else { return }
        guard let versionsFolderID = restoration.versionsFolderID,
              let changesFolderID = restoration.changesFolderID else {
            throw Error.foldersNotInitialized
        }

        for (version, valueChanges) in versionChanges {
            let changesData = try JSONEncoder().encode(valueChanges)
            let versionData = try JSONEncoder().encode(["version": version])

            try await uploadData(changesData, toFolder: changesFolderID, asFileNamed: version.id.rawValue)
            try await uploadData(versionData, toFolder: versionsFolderID, asFileNamed: version.id.rawValue)
        }

        newVersionsContinuation.yield(())
    }

    // MARK: - pCloud SDK Helpers

    private func ensureFoldersExist() async throws {
        if restoration.versionsFolderID != nil && restoration.changesFolderID != nil {
            return
        }

        let rootID = try await createFolderIfNeeded(named: folderName, inFolder: parentFolderID)
        restoration.rootFolderID = rootID

        let versionsID = try await createFolderIfNeeded(named: "versions", inFolder: rootID)
        restoration.versionsFolderID = versionsID

        let changesID = try await createFolderIfNeeded(named: "changes", inFolder: rootID)
        restoration.changesFolderID = changesID
    }

    private func createFolderIfNeeded(named name: String, inFolder parentID: UInt64) async throws -> UInt64 {
        try await withCheckedThrowingContinuation { continuation in
            client.createFolderIfDoesNotExist(named: name, inFolder: parentID)
                .addCompletionBlock { result in
                    switch result {
                    case .success(let response):
                        continuation.resume(returning: response.folder.id)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                .start()
        }
    }

    /// Lists file contents of a folder, returning a name-to-fileID mapping.
    private func listFileNames(inFolder folderID: UInt64) async throws -> [String: UInt64] {
        try await withCheckedThrowingContinuation { continuation in
            client.listFolder(folderID, recursively: false)
                .addCompletionBlock { result in
                    switch result {
                    case .success(let folder):
                        var fileMap: [String: UInt64] = [:]
                        for content in folder.contents {
                            if case .file(let file) = content {
                                fileMap[file.name] = file.id
                            }
                        }
                        continuation.resume(returning: fileMap)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                .start()
        }
    }

    /// Downloads file data by first getting a CDN link via the SDK, then fetching via URLSession.
    private func downloadFileData(fileID: UInt64) async throws -> Data {
        let link: URL = try await withCheckedThrowingContinuation { continuation in
            client.getFileLink(forFile: fileID)
                .addCompletionBlock { result in
                    switch result {
                    case .success(let links):
                        guard let link = links.first else {
                            continuation.resume(throwing: Error.missingDownloadLink)
                            return
                        }
                        continuation.resume(returning: link.address)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                .start()
        }

        return try await withCheckedThrowingContinuation { continuation in
            let task = urlSession.dataTask(with: link) { data, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: Error.invalidResponse)
                }
            }
            task.resume()
        }
    }

    private func uploadData(_ data: Data, toFolder folderID: UInt64, asFileNamed name: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            client.upload(data, toFolder: folderID, asFileNamed: name)
                .addCompletionBlock { result in
                    switch result {
                    case .success:
                        continuation.resume(returning: ())
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                .start()
        }
    }

    // MARK: - Restoration

    fileprivate struct RestorationInfo: Codable {
        var rootFolderID: UInt64?
        var versionsFolderID: UInt64?
        var changesFolderID: UInt64?
    }
}
