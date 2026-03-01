//
//  PCloudExchange.swift
//  LLVS
//
//  Created by Claude on 28/02/2026.
//

import Foundation
import LLVS
import Combine
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
    }

    // MARK: - Retrieve

    public func prepareToRetrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        ensureFoldersExist(completionHandler: completionHandler)
    }

    public func retrieveAllVersionIdentifiers(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID]>) {
        guard let folderID = restoration.versionsFolderID else {
            completionHandler(.success([]))
            return
        }
        listFileNames(inFolder: folderID) { result in
            switch result {
            case .success(let fileMap):
                completionHandler(.success(fileMap.map { Version.ID($0.key) }))
            case .failure(let error):
                completionHandler(.failure(error))
            }
        }
    }

    public func retrieveVersions(identifiedBy versionIds: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version]>) {
        guard !versionIds.isEmpty else {
            completionHandler(.success([]))
            return
        }
        guard let folderID = restoration.versionsFolderID else {
            completionHandler(.success([]))
            return
        }

        listFileNames(inFolder: folderID) { result in
            switch result {
            case .failure(let error):
                completionHandler(.failure(error))
            case .success(let fileMap):
                var versions: [Version] = []
                let tasks = versionIds.map { versionId in
                    AsynchronousTask { finish in
                        guard let fileID = fileMap[versionId.rawValue] else {
                            finish(.failure(Error.fileNotFound(versionId.rawValue)))
                            return
                        }
                        self.downloadFileData(fileID: fileID) { downloadResult in
                            switch downloadResult {
                            case .success(let data):
                                do {
                                    if let version = try JSONDecoder().decode([String: Version].self, from: data)["version"] {
                                        versions.append(version)
                                        finish(.success(()))
                                    } else {
                                        finish(.failure(Error.versionFileInvalid))
                                    }
                                } catch {
                                    finish(.failure(error))
                                }
                            case .failure(let error):
                                finish(.failure(error))
                            }
                        }
                    }
                }
                tasks.executeInOrder { tasksResult in
                    switch tasksResult {
                    case .success:
                        completionHandler(.success(versions))
                    case .failure(let error):
                        completionHandler(.failure(error))
                    }
                }
            }
        }
    }

    public func retrieveValueChanges(forVersionsIdentifiedBy versionIds: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID: [Value.Change]]>) {
        guard !versionIds.isEmpty else {
            completionHandler(.success([:]))
            return
        }
        guard let folderID = restoration.changesFolderID else {
            completionHandler(.success([:]))
            return
        }

        listFileNames(inFolder: folderID) { result in
            switch result {
            case .failure(let error):
                completionHandler(.failure(error))
            case .success(let fileMap):
                var changesByVersion: [Version.ID: [Value.Change]] = [:]
                let tasks = versionIds.map { versionId in
                    AsynchronousTask { finish in
                        guard let fileID = fileMap[versionId.rawValue] else {
                            finish(.failure(Error.fileNotFound(versionId.rawValue)))
                            return
                        }
                        self.downloadFileData(fileID: fileID) { downloadResult in
                            switch downloadResult {
                            case .success(let data):
                                do {
                                    let changes = try JSONDecoder().decode([Value.Change].self, from: data)
                                    changesByVersion[versionId] = changes
                                    finish(.success(()))
                                } catch {
                                    finish(.failure(error))
                                }
                            case .failure(let error):
                                finish(.failure(error))
                            }
                        }
                    }
                }
                tasks.executeInOrder { tasksResult in
                    switch tasksResult {
                    case .success:
                        completionHandler(.success(changesByVersion))
                    case .failure(let error):
                        completionHandler(.failure(error))
                    }
                }
            }
        }
    }

    // MARK: - Send

    public func prepareToSend(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        ensureFoldersExist(completionHandler: completionHandler)
    }

    public func send(versionChanges: [VersionChanges], executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        guard !versionChanges.isEmpty else {
            completionHandler(.success(()))
            return
        }
        guard let versionsFolderID = restoration.versionsFolderID,
              let changesFolderID = restoration.changesFolderID else {
            completionHandler(.failure(Error.foldersNotInitialized))
            return
        }

        let tasks = versionChanges.map { (version, valueChanges) in
            AsynchronousTask { finish in
                do {
                    let changesData = try JSONEncoder().encode(valueChanges)
                    let versionData = try JSONEncoder().encode(["version": version])

                    let uploadChanges = AsynchronousTask { innerFinish in
                        self.client.upload(changesData, toFolder: changesFolderID, asFileNamed: version.id.rawValue)
                            .addCompletionBlock { result in
                                switch result {
                                case .success:
                                    innerFinish(.success(()))
                                case .failure(let error):
                                    innerFinish(.failure(error))
                                }
                            }
                            .start()
                    }

                    let uploadVersion = AsynchronousTask { innerFinish in
                        self.client.upload(versionData, toFolder: versionsFolderID, asFileNamed: version.id.rawValue)
                            .addCompletionBlock { result in
                                switch result {
                                case .success:
                                    innerFinish(.success(()))
                                case .failure(let error):
                                    innerFinish(.failure(error))
                                }
                            }
                            .start()
                    }

                    [uploadChanges, uploadVersion].executeInOrder { result in
                        finish(result)
                    }
                } catch {
                    finish(.failure(error))
                }
            }
        }
        tasks.executeInOrder { result in
            switch result {
            case .success:
                self.newVersionsSubject.send(())
                completionHandler(.success(()))
            case .failure(let error):
                completionHandler(.failure(error))
            }
        }
    }

    // MARK: - pCloud SDK Helpers

    private func ensureFoldersExist(completionHandler: @escaping CompletionHandler<Void>) {
        if restoration.versionsFolderID != nil && restoration.changesFolderID != nil {
            completionHandler(.success(()))
            return
        }

        let createRoot = AsynchronousTask { finish in
            self.client.createFolderIfDoesNotExist(named: self.folderName, inFolder: self.parentFolderID)
                .addCompletionBlock { result in
                    switch result {
                    case .success(let response):
                        self.restoration.rootFolderID = response.folder.id
                        finish(.success(()))
                    case .failure(let error):
                        finish(.failure(error))
                    }
                }
                .start()
        }

        let createVersions = AsynchronousTask { finish in
            guard let rootID = self.restoration.rootFolderID else {
                finish(.failure(Error.foldersNotInitialized))
                return
            }
            self.client.createFolderIfDoesNotExist(named: "versions", inFolder: rootID)
                .addCompletionBlock { result in
                    switch result {
                    case .success(let response):
                        self.restoration.versionsFolderID = response.folder.id
                        finish(.success(()))
                    case .failure(let error):
                        finish(.failure(error))
                    }
                }
                .start()
        }

        let createChanges = AsynchronousTask { finish in
            guard let rootID = self.restoration.rootFolderID else {
                finish(.failure(Error.foldersNotInitialized))
                return
            }
            self.client.createFolderIfDoesNotExist(named: "changes", inFolder: rootID)
                .addCompletionBlock { result in
                    switch result {
                    case .success(let response):
                        self.restoration.changesFolderID = response.folder.id
                        finish(.success(()))
                    case .failure(let error):
                        finish(.failure(error))
                    }
                }
                .start()
        }

        [createRoot, createVersions, createChanges].executeInOrder(completingWith: completionHandler)
    }

    /// Lists file contents of a folder, returning a name-to-fileID mapping.
    private func listFileNames(inFolder folderID: UInt64, completionHandler: @escaping CompletionHandler<[String: UInt64]>) {
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
                    completionHandler(.success(fileMap))
                case .failure(let error):
                    completionHandler(.failure(error))
                }
            }
            .start()
    }

    /// Downloads file data by first getting a CDN link via the SDK, then fetching via URLSession.
    private func downloadFileData(fileID: UInt64, completionHandler: @escaping CompletionHandler<Data>) {
        client.getFileLink(forFile: fileID)
            .addCompletionBlock { result in
                switch result {
                case .success(let links):
                    guard let link = links.first else {
                        completionHandler(.failure(Error.missingDownloadLink))
                        return
                    }
                    let task = self.urlSession.dataTask(with: link.address) { data, _, error in
                        if let error = error {
                            completionHandler(.failure(error))
                        } else if let data = data {
                            completionHandler(.success(data))
                        } else {
                            completionHandler(.failure(Error.invalidResponse))
                        }
                    }
                    task.resume()
                case .failure(let error):
                    completionHandler(.failure(error))
                }
            }
            .start()
    }

    // MARK: - Restoration

    fileprivate struct RestorationInfo: Codable {
        var rootFolderID: UInt64?
        var versionsFolderID: UInt64?
        var changesFolderID: UInt64?
    }
}
