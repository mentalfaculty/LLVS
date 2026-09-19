#if Box
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
public final class BoxExchange: FolderBasedExchange, @unchecked Sendable {

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

    @Guarded private var restoration = RestorationInfo()

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

    /// Not lazy: a lazy var is not thread-safe, and this is touched from callback queues.
    fileprivate let temporaryDirectory: URL = {
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

    /// Writes the data to a file of this name in this folder, overwriting its contents.
    ///
    /// An existing file gains a new revision rather than being deleted and remade, so its id and
    /// history survive and the name is never briefly absent.
    ///
    /// Box refuses a create whose name is already taken, and the sync writes the changes file
    /// before the version file. If the version upload failed after the changes upload succeeded,
    /// every later attempt used to hit that name conflict and the version could never land —
    /// the store stayed stuck on that version for good. Uploading a new revision of the existing
    /// file instead makes the retry succeed, and `uploadData` idempotent as its callers assume.
    public func uploadData(_ data: Data, named name: String, toFolder folderID: String) async throws {
        let attributes = UploadFileRequestBodyAttributesField(
            name: name,
            parent: UploadFileRequestBodyAttributesParentField(id: folderID)
        )
        let body = UploadFileRequestBody(
            attributes: attributes,
            file: Utils.generateByteStreamFromBuffer(buffer: data)
        )

        do {
            _ = try await client.uploads.uploadFile(requestBody: body)
        } catch {
            // Try the create and handle the conflict, rather than looking first. Looking first
            // would not be safe: the check and the create are not atomic, so a second device can
            // slip between them — the same race that item 15 fixes on Google Drive. Box enforces
            // name uniqueness where Drive does not, so letting its own constraint arbitrate is
            // the only answer that holds under concurrency. It is also much cheaper: a look costs
            // a full paged listing of a folder holding one file per version, so checking first
            // would make sending N versions do 2N listings of a folder that grows with each one.
            guard Self.isConflict(error) else { throw error }

            // The 409 names the file holding the name, which costs no extra request. Without one,
            // a listing is worth it only when the error actually says the name is taken: Box also
            // returns 409 for transient things like `operation_blocked_temporary`, which is
            // retried, and listing an ever-growing folder on every one of those is the cost this
            // whole approach exists to avoid. Anything unresolved is rethrown, so a 409 that means
            // something else still surfaces
            let conflictingFileID: String
            if let idFromError = Self.conflictingFileID(from: error) {
                conflictingFileID = idFromError
            } else if Self.isNameInUse(error), let idFromListing = try await listFiles(inFolder: folderID)[name] {
                conflictingFileID = idFromListing
            } else {
                throw error
            }

            // A fresh stream, not the one the failed attempt used: these are `InputStream`s, which
            // read once and cannot be rewound, so reusing it would upload an empty file
            let versionBody = UploadFileVersionRequestBody(
                attributes: UploadFileVersionRequestBodyAttributesField(name: name),
                file: Utils.generateByteStreamFromBuffer(buffer: data)
            )
            _ = try await client.uploads.uploadFileVersion(fileId: conflictingFileID, requestBody: versionBody)
        }
    }

    /// Whether Box answered with a conflict of any kind.
    ///
    /// Deliberately broad. A name conflict that arrives without the code below still has to reach
    /// the resolution step, because failing it there is what wedges a store permanently — the bug
    /// this all exists to fix. Anything that cannot be resolved is rethrown regardless.
    static func isConflict(_ error: any Swift.Error) -> Bool {
        (error as? BoxAPIError)?.responseInfo.statusCode == 409
    }

    /// Whether Box said in so many words that the name is already taken.
    ///
    /// Used only to decide whether a folder listing is worth paying for. Box returns 409 for
    /// transient conditions too, such as `operation_blocked_temporary` for a lock or a move on a
    /// parent folder, and those are retried — so listing on every 409 would spend a full paged
    /// listing of an ever-growing folder each time one recurs.
    static func isNameInUse(_ error: any Swift.Error) -> Bool {
        (error as? BoxAPIError)?.responseInfo.code == "item_name_in_use"
    }

    /// The id Box names in a name conflict, or nil when the error does not carry one.
    ///
    /// A 409 names the file already holding the name, so the retry needs no extra request to find
    /// it. The shape is `context_info.conflicts`, a list — see `ConflictErrorContextInfoField` in
    /// the SDK, whose `conflicts` is `[FileConflict]?`. An upload conflicts with one file, so the
    /// first entry is the one wanted.
    static func conflictingFileID(from error: any Swift.Error) -> String? {
        guard let boxError = error as? BoxAPIError,
              boxError.responseInfo.statusCode == 409,
              let contextInfo = boxError.responseInfo.contextInfo,
              let conflicts = contextInfo["conflicts"] as? [[String: Any]] else { return nil }

        return conflicts.first?["id"] as? String
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

#endif
