//
//  BoxExchange.swift
//  LLVS
//
//  Created by Claude on 28/02/2026.
//

import Foundation
import LLVS
import Combine
import BoxSdkGen

private typealias AsyncTask = _Concurrency.Task

/// An Exchange that syncs versions via the Box Swift SDK.
///
/// Data is stored inside a configurable Box folder, organized as:
/// - `versions/` — JSON-encoded version metadata, one file per version
/// - `changes/` — JSON-encoded value changes, one file per version
///
/// Uses `BoxClient` from the official Box SDK for all API operations.
/// The caller provides an authenticated `BoxClient` (e.g. via `BoxDeveloperTokenAuth`
/// or `BoxCCGAuth`).
///
/// Folder listings are cached per retrieve/send cycle and downloads are parallelized
/// using structured concurrency.
public class BoxExchange: Exchange {

    public enum Error: Swift.Error {
        case versionFileInvalid
        case fileNotFound(String)
        case downloadFailed
        case folderNotFound
    }

    public let store: Store

    /// The Box client used for API calls.
    public let client: BoxClient

    /// The Box folder ID that serves as the root for LLVS data.
    public let rootFolderID: String

    @Atomic private var restoration = RestorationInfo()

    /// Cached folder listings, populated during prepareToRetrieve
    /// and consumed by subsequent calls in the same cycle.
    private var cachedVersionsFileMap: [String: String]?
    private var cachedChangesFileMap: [String: String]?

    private let newVersionsSubject = PassthroughSubject<Void, Never>()

    public var newVersionsAvailable: AnyPublisher<Void, Never> {
        newVersionsSubject.eraseToAnyPublisher()
    }

    public var restorationState: Data? {
        get { try? JSONEncoder().encode(restoration) }
        set {
            if let data = newValue, let info = try? JSONDecoder().decode(RestorationInfo.self, from: data) {
                restoration = info
            }
        }
    }

    fileprivate lazy var temporaryDirectory: URL = {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: result, withIntermediateDirectories: true, attributes: nil)
        return result
    }()

    /// - Parameters:
    ///   - store: The LLVS store to sync.
    ///   - client: An authenticated `BoxClient` instance.
    ///   - rootFolderID: The Box folder ID to use as root for LLVS data.
    public init(store: Store, client: BoxClient, rootFolderID: String) {
        self.store = store
        self.client = client
        self.rootFolderID = rootFolderID
    }

    // MARK: - Retrieve

    public func prepareToRetrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        cachedVersionsFileMap = nil
        cachedChangesFileMap = nil
        AsyncTask {
            do {
                try await ensureFoldersExist()

                // Pre-cache both folder listings so retrieveAllVersionIdentifiers,
                // retrieveVersions, and retrieveValueChanges don't re-list.
                if let vFolderID = restoration.versionsFolderID {
                    cachedVersionsFileMap = try await listFileNameMap(inFolder: vFolderID)
                } else {
                    cachedVersionsFileMap = [:]
                }
                if let cFolderID = restoration.changesFolderID {
                    cachedChangesFileMap = try await listFileNameMap(inFolder: cFolderID)
                } else {
                    cachedChangesFileMap = [:]
                }

                completionHandler(.success(()))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }

    public func retrieveAllVersionIdentifiers(executingUponCompletion completionHandler: @escaping CompletionHandler<[LLVS.Version.ID]>) {
        if let fileMap = cachedVersionsFileMap {
            completionHandler(.success(fileMap.map { LLVS.Version.ID($0.key) }))
            return
        }
        AsyncTask {
            do {
                guard let folderID = restoration.versionsFolderID else {
                    completionHandler(.success([]))
                    return
                }
                let fileMap = try await listFileNameMap(inFolder: folderID)
                cachedVersionsFileMap = fileMap
                completionHandler(.success(fileMap.map { LLVS.Version.ID($0.key) }))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }

    public func retrieveVersions(identifiedBy versionIds: [LLVS.Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[LLVS.Version]>) {
        guard !versionIds.isEmpty else {
            completionHandler(.success([]))
            return
        }
        guard let fileMap = cachedVersionsFileMap ?? nil else {
            completionHandler(.success([]))
            return
        }

        AsyncTask {
            do {
                // Resolve all file IDs up front
                var fileIDsToFetch: [(versionId: LLVS.Version.ID, fileID: String)] = []
                for versionId in versionIds {
                    guard let fileID = fileMap[versionId.rawValue] else {
                        throw Error.fileNotFound(versionId.rawValue)
                    }
                    fileIDsToFetch.append((versionId, fileID))
                }

                // Download all in parallel
                let dataByFileID = try await downloadFilesInParallel(fileIDs: fileIDsToFetch.map { $0.fileID })

                var versions: [LLVS.Version] = []
                for (_, fileID) in fileIDsToFetch {
                    guard let data = dataByFileID[fileID] else {
                        throw Error.downloadFailed
                    }
                    if let version = try JSONDecoder().decode([String: LLVS.Version].self, from: data)["version"] {
                        versions.append(version)
                    } else {
                        throw Error.versionFileInvalid
                    }
                }
                completionHandler(.success(versions))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }

    public func retrieveValueChanges(forVersionsIdentifiedBy versionIds: [LLVS.Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[LLVS.Version.ID: [Value.Change]]>) {
        guard !versionIds.isEmpty else {
            completionHandler(.success([:]))
            return
        }
        guard let fileMap = cachedChangesFileMap ?? nil else {
            completionHandler(.success([:]))
            return
        }

        AsyncTask {
            do {
                var fileIDsToFetch: [(versionId: LLVS.Version.ID, fileID: String)] = []
                for versionId in versionIds {
                    guard let fileID = fileMap[versionId.rawValue] else {
                        throw Error.fileNotFound(versionId.rawValue)
                    }
                    fileIDsToFetch.append((versionId, fileID))
                }

                let dataByFileID = try await downloadFilesInParallel(fileIDs: fileIDsToFetch.map { $0.fileID })

                var changesByVersion: [LLVS.Version.ID: [Value.Change]] = [:]
                for (versionId, fileID) in fileIDsToFetch {
                    guard let data = dataByFileID[fileID] else {
                        throw Error.downloadFailed
                    }
                    let changes = try JSONDecoder().decode([Value.Change].self, from: data)
                    changesByVersion[versionId] = changes
                }
                completionHandler(.success(changesByVersion))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }

    // MARK: - Send

    public func prepareToSend(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        cachedVersionsFileMap = nil
        cachedChangesFileMap = nil
        AsyncTask {
            do {
                try await ensureFoldersExist()
                completionHandler(.success(()))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }

    public func send(versionChanges: [VersionChanges], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        guard !versionChanges.isEmpty else {
            completionHandler(.success(()))
            return
        }
        AsyncTask {
            do {
                guard let versionsFolderID = restoration.versionsFolderID,
                      let changesFolderID = restoration.changesFolderID else {
                    throw Error.folderNotFound
                }

                for (version, valueChanges) in versionChanges {
                    let changesData = try JSONEncoder().encode(valueChanges)
                    let versionData = try JSONEncoder().encode(["version": version])

                    try await uploadFileData(changesData, name: version.id.rawValue, toFolder: changesFolderID)
                    try await uploadFileData(versionData, name: version.id.rawValue, toFolder: versionsFolderID)
                }

                newVersionsSubject.send(())
                completionHandler(.success(()))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }

    // MARK: - Box SDK Helpers

    private func ensureFoldersExist() async throws {
        if restoration.versionsFolderID != nil && restoration.changesFolderID != nil { return }

        let versionsFolderID = try await createSubfolderIfNeeded(named: "versions", inFolder: rootFolderID)
        let changesFolderID = try await createSubfolderIfNeeded(named: "changes", inFolder: rootFolderID)

        restoration.versionsFolderID = versionsFolderID
        restoration.changesFolderID = changesFolderID
    }

    private func createSubfolderIfNeeded(named name: String, inFolder parentID: String) async throws -> String {
        let items = try await listAllItems(inFolder: parentID)
        if let existing = items.first(where: { $0.name == name && $0.isFolder }) {
            return existing.id
        }

        let body = CreateFolderRequestBody(
            name: name,
            parent: CreateFolderRequestBodyParentField(id: parentID)
        )
        let folder = try await client.folders.createFolder(requestBody: body)
        return folder.id
    }

    private struct ItemInfo {
        let id: String
        let name: String
        let isFolder: Bool
    }

    private func listAllItems(inFolder folderID: String) async throws -> [ItemInfo] {
        var allItems: [ItemInfo] = []
        var marker: String? = nil
        repeat {
            let queryParams = GetFolderItemsQueryParams(usemarker: true, marker: marker, limit: 1000)
            let items = try await client.folders.getFolderItems(folderId: folderID, queryParams: queryParams)
            if let entries = items.entries {
                for entry in entries {
                    switch entry {
                    case .fileFull(let file):
                        if let name = file.name {
                            allItems.append(ItemInfo(id: file.id, name: name, isFolder: false))
                        }
                    case .folderMini(let folder):
                        if let name = folder.name {
                            allItems.append(ItemInfo(id: folder.id, name: name, isFolder: true))
                        }
                    default:
                        break
                    }
                }
            }
            marker = items.nextMarker
        } while marker != nil
        return allItems
    }

    /// Returns a name-to-fileID mapping for all files in a folder.
    private func listFileNameMap(inFolder folderID: String) async throws -> [String: String] {
        let items = try await listAllItems(inFolder: folderID)
        return items
            .filter { !$0.isFolder }
            .reduce(into: [:]) { result, item in result[item.name] = item.id }
    }

    /// Downloads multiple files in parallel using structured concurrency.
    private func downloadFilesInParallel(fileIDs: [String]) async throws -> [String: Data] {
        try await withThrowingTaskGroup(of: (String, Data).self) { group in
            for fileID in fileIDs {
                group.addTask {
                    let data = try await self.downloadFileData(fileID: fileID)
                    return (fileID, data)
                }
            }
            var results: [String: Data] = [:]
            for try await (fileID, data) in group {
                results[fileID] = data
            }
            return results
        }
    }

    private func downloadFileData(fileID: String) async throws -> Data {
        let tempURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let savedURL = try await client.downloads.downloadFile(fileId: fileID, downloadDestinationUrl: tempURL) else {
            throw Error.downloadFailed
        }
        return try Data(contentsOf: savedURL)
    }

    private func uploadFileData(_ data: Data, name: String, toFolder folderID: String) async throws {
        let attributes = UploadFileRequestBodyAttributesField(
            name: name,
            parent: UploadFileRequestBodyAttributesParentField(id: folderID)
        )
        let body = UploadFileRequestBody(
            attributes: attributes,
            file: Utils.generateByteStreamFromBuffer(buffer: data)
        )
        _ = try await client.uploads.uploadFile(requestBody: body)
    }

    // MARK: - Restoration

    fileprivate struct RestorationInfo: Codable {
        var versionsFolderID: String?
        var changesFolderID: String?
    }
}
