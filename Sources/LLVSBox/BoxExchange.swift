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

/// An Exchange that syncs versions via the Box Swift SDK.
///
/// Data is stored inside a configurable Box folder, organized as:
/// - `versions/` — JSON-encoded version metadata, one file per version
/// - `changes/` — JSON-encoded value changes, one file per version
///
/// Uses `BoxClient` from the official Box SDK for all API operations.
/// The caller provides an authenticated `BoxClient` (e.g. via `BoxDeveloperTokenAuth`
/// or `BoxCCGAuth`).
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
        Task {
            do {
                try await ensureFoldersExist()
                completionHandler(.success(()))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }

    public func retrieveAllVersionIdentifiers(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID]>) {
        Task {
            do {
                guard let folderID = restoration.versionsFolderID else {
                    completionHandler(.success([]))
                    return
                }
                let items = try await listAllFileItems(inFolder: folderID)
                completionHandler(.success(items.map { Version.ID($0.name) }))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }

    public func retrieveVersions(identifiedBy versionIds: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version]>) {
        guard !versionIds.isEmpty else {
            completionHandler(.success([]))
            return
        }
        Task {
            do {
                guard let folderID = restoration.versionsFolderID else {
                    completionHandler(.success([]))
                    return
                }
                let items = try await listAllFileItems(inFolder: folderID)
                let itemsByName = Dictionary(items.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })

                var versions: [Version] = []
                for versionId in versionIds {
                    guard let fileID = itemsByName[versionId.rawValue] else {
                        throw Error.fileNotFound(versionId.rawValue)
                    }
                    let data = try await downloadFileData(fileID: fileID)
                    if let version = try JSONDecoder().decode([String: Version].self, from: data)["version"] {
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

    public func retrieveValueChanges(forVersionsIdentifiedBy versionIds: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID: [Value.Change]]>) {
        guard !versionIds.isEmpty else {
            completionHandler(.success([:]))
            return
        }
        Task {
            do {
                guard let folderID = restoration.changesFolderID else {
                    completionHandler(.success([:]))
                    return
                }
                let items = try await listAllFileItems(inFolder: folderID)
                let itemsByName = Dictionary(items.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })

                var changesByVersion: [Version.ID: [Value.Change]] = [:]
                for versionId in versionIds {
                    guard let fileID = itemsByName[versionId.rawValue] else {
                        throw Error.fileNotFound(versionId.rawValue)
                    }
                    let data = try await downloadFileData(fileID: fileID)
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
        Task {
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
        Task {
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

    private struct FileItem {
        let id: String
        let name: String
    }

    private func ensureFoldersExist() async throws {
        if restoration.versionsFolderID != nil && restoration.changesFolderID != nil { return }

        let versionsFolderID = try await createSubfolderIfNeeded(named: "versions", inFolder: rootFolderID)
        let changesFolderID = try await createSubfolderIfNeeded(named: "changes", inFolder: rootFolderID)

        restoration.versionsFolderID = versionsFolderID
        restoration.changesFolderID = changesFolderID
    }

    private func createSubfolderIfNeeded(named name: String, inFolder parentID: String) async throws -> String {
        // Check if it already exists by listing the parent
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

    private func listAllFileItems(inFolder folderID: String) async throws -> [FileItem] {
        let items = try await listAllItems(inFolder: folderID)
        return items.filter { !$0.isFolder }.map { FileItem(id: $0.id, name: $0.name) }
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
