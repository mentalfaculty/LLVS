//
//  BoxExchange.swift
//  LLVS
//
//  Created by Claude on 28/02/2026.
//

import Foundation
import LLVS
import Combine

/// An Exchange that syncs versions via the Box REST API.
///
/// Data is stored inside a configurable Box folder, organized as:
/// - `versions/` — JSON-encoded version metadata, one file per version
/// - `changes/` — JSON-encoded value changes, one file per version
///
/// Requires an OAuth2 access token for authentication. The caller is responsible
/// for token refresh.
public class BoxExchange: Exchange {

    public enum Error: Swift.Error {
        case invalidResponse
        case httpError(Int)
        case versionFileInvalid
        case changesFileInvalid
        case folderNotFound
        case fileNotFound(String)
    }

    public let store: Store

    private let newVersionsSubject = PassthroughSubject<Void, Never>()

    public var newVersionsAvailable: AnyPublisher<Void, Never> {
        newVersionsSubject.eraseToAnyPublisher()
    }

    public var restorationState: Data? {
        get {
            try? JSONEncoder().encode(cachedFolderIDs)
        }
        set {
            if let data = newValue, let ids = try? JSONDecoder().decode([String: String].self, from: data) {
                cachedFolderIDs = ids
            }
        }
    }

    /// OAuth2 access token for Box API authentication.
    public var accessToken: String

    /// The Box folder ID that serves as the root for LLVS data.
    public let rootFolderID: String

    private let apiBaseURL = URL(string: "https://api.box.com/2.0")!
    private let uploadBaseURL = URL(string: "https://upload.box.com/api/2.0")!

    private let session: URLSession

    /// Cache of folder name -> Box folder ID mappings.
    private var cachedFolderIDs: [String: String] = [:]

    /// - Parameters:
    ///   - store: The LLVS store to sync.
    ///   - accessToken: Box OAuth2 access token.
    ///   - rootFolderID: The Box folder ID to use as root for LLVS data.
    ///   - urlSession: URLSession to use for requests. Defaults to `.shared`.
    public init(store: Store, accessToken: String, rootFolderID: String, urlSession: URLSession = .shared) {
        self.store = store
        self.accessToken = accessToken
        self.rootFolderID = rootFolderID
        self.session = urlSession
    }

    // MARK: - Retrieve

    public func prepareToRetrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        ensureFoldersExist(completionHandler: completionHandler)
    }

    public func retrieveAllVersionIdentifiers(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID]>) {
        folderID(forName: "versions") { result in
            switch result {
            case .success(let folderID):
                self.listFolderItems(folderID: folderID) { result in
                    switch result {
                    case .success(let items):
                        let ids = items.map { Version.ID($0.name) }
                        completionHandler(.success(ids))
                    case .failure(let error):
                        completionHandler(.failure(error))
                    }
                }
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

        folderID(forName: "versions") { result in
            switch result {
            case .failure(let error):
                completionHandler(.failure(error))
            case .success(let folderID):
                self.listFolderItems(folderID: folderID) { result in
                    switch result {
                    case .failure(let error):
                        completionHandler(.failure(error))
                    case .success(let items):
                        let itemsByName = Dictionary(items.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })

                        var versions: [Version] = []
                        let tasks = versionIds.map { versionId in
                            AsynchronousTask { finish in
                                guard let fileID = itemsByName[versionId.rawValue] else {
                                    finish(.failure(Error.fileNotFound(versionId.rawValue)))
                                    return
                                }
                                self.downloadFile(fileID: fileID) { downloadResult in
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
        }
    }

    public func retrieveValueChanges(forVersionsIdentifiedBy versionIds: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID: [Value.Change]]>) {
        guard !versionIds.isEmpty else {
            completionHandler(.success([:]))
            return
        }

        folderID(forName: "changes") { result in
            switch result {
            case .failure(let error):
                completionHandler(.failure(error))
            case .success(let folderID):
                self.listFolderItems(folderID: folderID) { result in
                    switch result {
                    case .failure(let error):
                        completionHandler(.failure(error))
                    case .success(let items):
                        let itemsByName = Dictionary(items.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })

                        var changesByVersion: [Version.ID: [Value.Change]] = [:]
                        let tasks = versionIds.map { versionId in
                            AsynchronousTask { finish in
                                guard let fileID = itemsByName[versionId.rawValue] else {
                                    finish(.failure(Error.fileNotFound(versionId.rawValue)))
                                    return
                                }
                                self.downloadFile(fileID: fileID) { downloadResult in
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

        let getVersionsFolderID = AsynchronousTask { finish in
            self.folderID(forName: "versions") { result in
                finish(result.voidResult)
            }
        }
        let getChangesFolderID = AsynchronousTask { finish in
            self.folderID(forName: "changes") { result in
                finish(result.voidResult)
            }
        }

        [getVersionsFolderID, getChangesFolderID].executeInOrder { result in
            switch result {
            case .failure(let error):
                completionHandler(.failure(error))
            case .success:
                guard let versionsFolderID = self.cachedFolderIDs["versions"],
                      let changesFolderID = self.cachedFolderIDs["changes"] else {
                    completionHandler(.failure(Error.folderNotFound))
                    return
                }

                let tasks = versionChanges.map { (version, valueChanges) in
                    AsynchronousTask { finish in
                        do {
                            let changesData = try JSONEncoder().encode(valueChanges)
                            let versionData = try JSONEncoder().encode(["version": version])

                            let uploadChanges = AsynchronousTask { innerFinish in
                                self.uploadFile(data: changesData, fileName: version.id.rawValue, parentFolderID: changesFolderID) { uploadResult in
                                    innerFinish(uploadResult)
                                }
                            }

                            let uploadVersion = AsynchronousTask { innerFinish in
                                self.uploadFile(data: versionData, fileName: version.id.rawValue, parentFolderID: versionsFolderID) { uploadResult in
                                    innerFinish(uploadResult)
                                }
                            }

                            [uploadChanges, uploadVersion].executeInOrder { uploadResult in
                                finish(uploadResult)
                            }
                        } catch {
                            finish(.failure(error))
                        }
                    }
                }
                tasks.executeInOrder { tasksResult in
                    switch tasksResult {
                    case .success:
                        self.newVersionsSubject.send(())
                        completionHandler(.success(()))
                    case .failure(let error):
                        completionHandler(.failure(error))
                    }
                }
            }
        }
    }

    // MARK: - Box API Helpers

    private struct BoxItem {
        let id: String
        let name: String
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func ensureFoldersExist(completionHandler: @escaping CompletionHandler<Void>) {
        let createVersions = AsynchronousTask { finish in
            self.createSubfolderIfNeeded(name: "versions") { result in
                finish(result.voidResult)
            }
        }
        let createChanges = AsynchronousTask { finish in
            self.createSubfolderIfNeeded(name: "changes") { result in
                finish(result.voidResult)
            }
        }
        [createVersions, createChanges].executeInOrder(completingWith: completionHandler)
    }

    private func folderID(forName name: String, completionHandler: @escaping CompletionHandler<String>) {
        if let cached = cachedFolderIDs[name] {
            completionHandler(.success(cached))
            return
        }
        createSubfolderIfNeeded(name: name) { result in
            completionHandler(result)
        }
    }

    private func createSubfolderIfNeeded(name: String, completionHandler: @escaping CompletionHandler<String>) {
        // First check if it already exists by listing root folder
        listFolderItems(folderID: rootFolderID) { result in
            switch result {
            case .success(let items):
                if let existing = items.first(where: { $0.name == name }) {
                    self.cachedFolderIDs[name] = existing.id
                    completionHandler(.success(existing.id))
                    return
                }
                // Create it
                self.createFolder(name: name, parentID: self.rootFolderID) { createResult in
                    switch createResult {
                    case .success(let folderID):
                        self.cachedFolderIDs[name] = folderID
                        completionHandler(.success(folderID))
                    case .failure(let error):
                        completionHandler(.failure(error))
                    }
                }
            case .failure(let error):
                completionHandler(.failure(error))
            }
        }
    }

    private func createFolder(name: String, parentID: String, completionHandler: @escaping CompletionHandler<String>) {
        let url = apiBaseURL.appendingPathComponent("folders")
        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "name": name,
            "parent": ["id": parentID]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completionHandler(.failure(error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completionHandler(.failure(Error.invalidResponse))
                return
            }
            // 409 means folder already exists — retrieve its ID
            if httpResponse.statusCode == 409 {
                self.listFolderItems(folderID: parentID) { listResult in
                    switch listResult {
                    case .success(let items):
                        if let item = items.first(where: { $0.name == name }) {
                            completionHandler(.success(item.id))
                        } else {
                            completionHandler(.failure(Error.folderNotFound))
                        }
                    case .failure(let error):
                        completionHandler(.failure(error))
                    }
                }
                return
            }
            guard (200..<300).contains(httpResponse.statusCode),
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let folderID = json["id"] as? String else {
                completionHandler(.failure(Error.httpError(httpResponse.statusCode)))
                return
            }
            completionHandler(.success(folderID))
        }
        task.resume()
    }

    private func listFolderItems(folderID: String, completionHandler: @escaping CompletionHandler<[BoxItem]>) {
        listFolderItems(folderID: folderID, offset: 0, accumulated: [], completionHandler: completionHandler)
    }

    private func listFolderItems(folderID: String, offset: Int, accumulated: [BoxItem], completionHandler: @escaping CompletionHandler<[BoxItem]>) {
        let limit = 1000
        var components = URLComponents(url: apiBaseURL.appendingPathComponent("folders/\(folderID)/items"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "fields", value: "id,name")
        ]

        let request = authorizedRequest(url: components.url!)
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completionHandler(.failure(error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completionHandler(.failure(Error.invalidResponse))
                return
            }
            guard (200..<300).contains(httpResponse.statusCode),
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = json["entries"] as? [[String: Any]],
                  let totalCount = json["total_count"] as? Int else {
                completionHandler(.failure(Error.httpError(httpResponse.statusCode)))
                return
            }

            let items = entries.compactMap { entry -> BoxItem? in
                guard let id = entry["id"] as? String, let name = entry["name"] as? String else { return nil }
                return BoxItem(id: id, name: name)
            }

            let allItems = accumulated + items
            if allItems.count < totalCount {
                self.listFolderItems(folderID: folderID, offset: allItems.count, accumulated: allItems, completionHandler: completionHandler)
            } else {
                completionHandler(.success(allItems))
            }
        }
        task.resume()
    }

    private func downloadFile(fileID: String, completionHandler: @escaping CompletionHandler<Data>) {
        let url = apiBaseURL.appendingPathComponent("files/\(fileID)/content")
        let request = authorizedRequest(url: url)

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completionHandler(.failure(error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<400).contains(httpResponse.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                completionHandler(.failure(Error.httpError(code)))
                return
            }
            if let data = data {
                completionHandler(.success(data))
            } else {
                completionHandler(.failure(Error.invalidResponse))
            }
        }
        task.resume()
    }

    private func uploadFile(data: Data, fileName: String, parentFolderID: String, completionHandler: @escaping CompletionHandler<Void>) {
        let url = uploadBaseURL.appendingPathComponent("files/content")
        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let attributes: [String: Any] = [
            "name": fileName,
            "parent": ["id": parentFolderID]
        ]
        let attributesData = try! JSONSerialization.data(withJSONObject: attributes)

        var body = Data()
        // Attributes part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"attributes\"\r\n\r\n".data(using: .utf8)!)
        body.append(attributesData)
        body.append("\r\n".data(using: .utf8)!)
        // File part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completionHandler(.failure(error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completionHandler(.failure(Error.invalidResponse))
                return
            }
            if (200..<300).contains(httpResponse.statusCode) {
                completionHandler(.success(()))
            } else {
                completionHandler(.failure(Error.httpError(httpResponse.statusCode)))
            }
        }
        task.resume()
    }
}
