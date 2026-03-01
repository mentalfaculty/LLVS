//
//  BoxExchange.swift
//  LLVS
//
//  Created by Drew McCormack on 28/02/2026.
//

import Foundation
import LLVS
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
public class BoxExchange: FolderBasedExchange {

    public typealias FileID = String
    public typealias FolderID = String

    public enum Error: Swift.Error {
        case downloadFailed
        case folderNotFound
    }

    public let store: Store

    /// The Box client used for API calls.
    public let client: BoxClient

    /// The Box folder ID that serves as the root for LLVS data.
    public let rootFolderID: String

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
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.newVersionsAvailable = stream
        self.newVersionsContinuation = continuation
    }

    // MARK: - Prepare

    public func prepareToRetrieve() async throws {
        try await ensureFoldersExist()
    }

    public func prepareToSend() async throws {
        try await ensureFoldersExist()
    }

    // MARK: - FolderBasedExchange

    public var versionsFolderID: String? { restoration.versionsFolderID }
    public var changesFolderID: String? { restoration.changesFolderID }

    public func notifyNewVersionsAvailable() {
        newVersionsContinuation.yield(())
    }

    public func listFiles(inFolder folderID: String) async throws -> [String: String] {
        let items = try await listAllItems(inFolder: folderID)
        var fileMap: [String: String] = [:]
        for item in items where !item.isFolder {
            fileMap[item.name] = item.id
        }
        return fileMap
    }

    public func downloadData(forFile fileID: String) async throws -> Data {
        let tempURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let savedURL = try await client.downloads.downloadFile(fileId: fileID, downloadDestinationUrl: tempURL) else {
            throw Error.downloadFailed
        }
        return try Data(contentsOf: savedURL)
    }

    public func uploadData(_ data: Data, named name: String, toFolder folderID: String) async throws {
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

    // MARK: - Restoration

    fileprivate struct RestorationInfo: Codable {
        var versionsFolderID: String?
        var changesFolderID: String?
    }
}
