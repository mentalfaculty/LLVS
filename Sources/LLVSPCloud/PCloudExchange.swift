//
//  PCloudExchange.swift
//  LLVS
//
//  Created by Claude on 28/02/2026.
//

import Foundation
import LLVS
import Combine

/// An Exchange that syncs versions via pCloud's REST API.
///
/// Data is stored in a configurable folder on pCloud, organized as:
/// - `versions/` — JSON-encoded version metadata, one file per version
/// - `changes/` — JSON-encoded value changes, one file per version
///
/// Requires an OAuth2 access token for authentication.
public class PCloudExchange: Exchange {

    public enum Error: Swift.Error {
        case invalidResponse
        case apiError(Int, String)
        case versionFileInvalid
        case changesFileInvalid
        case missingDownloadLink
        case folderCreationFailed
    }

    public let store: Store

    private let newVersionsSubject = PassthroughSubject<Void, Never>()

    public var newVersionsAvailable: AnyPublisher<Void, Never> {
        newVersionsSubject.eraseToAnyPublisher()
    }

    public var restorationState: Data? {
        get { return nil }
        set {}
    }

    /// The pCloud API base URL. Use `https://eapi.pcloud.com` for EU data center.
    public let apiBaseURL: URL

    /// OAuth2 access token for pCloud API authentication.
    public let accessToken: String

    /// The remote folder path where LLVS data is stored (e.g. "/LLVS").
    public let remoteFolderPath: String

    private var versionsPath: String { return remoteFolderPath + "/versions" }
    private var changesPath: String { return remoteFolderPath + "/changes" }

    private let session: URLSession
    private let queue = DispatchQueue(label: "llvs.pcloudexchange")

    /// - Parameters:
    ///   - store: The LLVS store to sync.
    ///   - accessToken: pCloud OAuth2 access token.
    ///   - remoteFolderPath: Path on pCloud for storing LLVS data (e.g. "/LLVS").
    ///   - apiBaseURL: The pCloud API base URL. Defaults to the US endpoint.
    ///   - urlSession: URLSession to use for requests. Defaults to `.shared`.
    public init(store: Store, accessToken: String, remoteFolderPath: String = "/LLVS", apiBaseURL: URL = URL(string: "https://api.pcloud.com")!, urlSession: URLSession = .shared) {
        self.store = store
        self.accessToken = accessToken
        self.remoteFolderPath = remoteFolderPath
        self.apiBaseURL = apiBaseURL
        self.session = urlSession
    }

    // MARK: - Retrieve

    public func prepareToRetrieve(executingUponCompletion completionHandler: @escaping CompletionHandler<Void>) {
        ensureFoldersExist(completionHandler: completionHandler)
    }

    public func retrieveAllVersionIdentifiers(executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID]>) {
        listFolder(path: versionsPath) { result in
            switch result {
            case .success(let names):
                completionHandler(.success(names.map { Version.ID($0) }))
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

        var versions: [Version] = []
        let tasks = versionIds.map { versionId in
            AsynchronousTask { finish in
                let path = self.versionsPath + "/" + versionId.rawValue
                self.downloadFile(path: path) { result in
                    switch result {
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
        tasks.executeInOrder { result in
            switch result {
            case .success:
                completionHandler(.success(versions))
            case .failure(let error):
                completionHandler(.failure(error))
            }
        }
    }

    public func retrieveValueChanges(forVersionsIdentifiedBy versionIds: [Version.ID], executingUponCompletion completionHandler: @escaping CompletionHandler<[Version.ID: [Value.Change]]>) {
        guard !versionIds.isEmpty else {
            completionHandler(.success([:]))
            return
        }

        var changesByVersion: [Version.ID: [Value.Change]] = [:]
        let tasks = versionIds.map { versionId in
            AsynchronousTask { finish in
                let path = self.changesPath + "/" + versionId.rawValue
                self.downloadFile(path: path) { result in
                    switch result {
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
        tasks.executeInOrder { result in
            switch result {
            case .success:
                completionHandler(.success(changesByVersion))
            case .failure(let error):
                completionHandler(.failure(error))
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

        let tasks = versionChanges.map { (version, valueChanges) in
            AsynchronousTask { finish in
                do {
                    let changesData = try JSONEncoder().encode(valueChanges)
                    let versionData = try JSONEncoder().encode(["version": version])

                    let uploadChanges = AsynchronousTask { innerFinish in
                        let path = self.changesPath + "/" + version.id.rawValue
                        self.uploadFile(data: changesData, path: path) { result in
                            innerFinish(result)
                        }
                    }

                    let uploadVersion = AsynchronousTask { innerFinish in
                        let path = self.versionsPath + "/" + version.id.rawValue
                        self.uploadFile(data: versionData, path: path) { result in
                            innerFinish(result)
                        }
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

    // MARK: - pCloud API Helpers

    private func ensureFoldersExist(completionHandler: @escaping CompletionHandler<Void>) {
        let createRoot = AsynchronousTask { finish in
            self.createFolderIfNeeded(path: self.remoteFolderPath) { result in
                finish(result)
            }
        }
        let createVersions = AsynchronousTask { finish in
            self.createFolderIfNeeded(path: self.versionsPath) { result in
                finish(result)
            }
        }
        let createChanges = AsynchronousTask { finish in
            self.createFolderIfNeeded(path: self.changesPath) { result in
                finish(result)
            }
        }
        [createRoot, createVersions, createChanges].executeInOrder(completingWith: completionHandler)
    }

    private func createFolderIfNeeded(path: String, completionHandler: @escaping CompletionHandler<Void>) {
        var components = URLComponents(url: apiBaseURL.appendingPathComponent("createfolderifnotexists"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "access_token", value: accessToken)
        ]

        let task = session.dataTask(with: URLRequest(url: components.url!)) { data, response, error in
            if let error = error {
                completionHandler(.failure(error))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? Int else {
                completionHandler(.failure(Error.invalidResponse))
                return
            }
            if result == 0 {
                completionHandler(.success(()))
            } else {
                let message = json["error"] as? String ?? "Unknown error"
                completionHandler(.failure(Error.apiError(result, message)))
            }
        }
        task.resume()
    }

    private func listFolder(path: String, completionHandler: @escaping CompletionHandler<[String]>) {
        var components = URLComponents(url: apiBaseURL.appendingPathComponent("listfolder"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "access_token", value: accessToken)
        ]

        let task = session.dataTask(with: URLRequest(url: components.url!)) { data, response, error in
            if let error = error {
                completionHandler(.failure(error))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? Int else {
                completionHandler(.failure(Error.invalidResponse))
                return
            }
            if result == 0,
               let metadata = json["metadata"] as? [String: Any],
               let contents = metadata["contents"] as? [[String: Any]] {
                let names = contents.compactMap { $0["name"] as? String }
                completionHandler(.success(names))
            } else if result == 2005 {
                // Folder doesn't exist yet — treat as empty
                completionHandler(.success([]))
            } else {
                let message = json["error"] as? String ?? "Unknown error"
                completionHandler(.failure(Error.apiError(result, message)))
            }
        }
        task.resume()
    }

    private func downloadFile(path: String, completionHandler: @escaping CompletionHandler<Data>) {
        // pCloud requires a two-step download: first get a link, then download from it
        var components = URLComponents(url: apiBaseURL.appendingPathComponent("getfilelink"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "access_token", value: accessToken)
        ]

        let task = session.dataTask(with: URLRequest(url: components.url!)) { data, response, error in
            if let error = error {
                completionHandler(.failure(error))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hosts = json["hosts"] as? [String],
                  let host = hosts.first,
                  let linkPath = json["path"] as? String else {
                completionHandler(.failure(Error.missingDownloadLink))
                return
            }

            let downloadURL = URL(string: "https://" + host + linkPath)!
            let downloadTask = self.session.dataTask(with: URLRequest(url: downloadURL)) { data, response, error in
                if let error = error {
                    completionHandler(.failure(error))
                } else if let data = data {
                    completionHandler(.success(data))
                } else {
                    completionHandler(.failure(Error.invalidResponse))
                }
            }
            downloadTask.resume()
        }
        task.resume()
    }

    private func uploadFile(data: Data, path: String, completionHandler: @escaping CompletionHandler<Void>) {
        let folderPath = (path as NSString).deletingLastPathComponent
        let filename = (path as NSString).lastPathComponent

        var components = URLComponents(url: apiBaseURL.appendingPathComponent("uploadfile"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "path", value: folderPath),
            URLQueryItem(name: "filename", value: filename),
            URLQueryItem(name: "nopartial", value: "1"),
            URLQueryItem(name: "renameifexists", value: "0"),
            URLQueryItem(name: "access_token", value: accessToken)
        ]

        let boundary = UUID().uuidString
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completionHandler(.failure(error))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? Int else {
                completionHandler(.failure(Error.invalidResponse))
                return
            }
            if result == 0 {
                completionHandler(.success(()))
            } else {
                let message = json["error"] as? String ?? "Unknown error"
                completionHandler(.failure(Error.apiError(result, message)))
            }
        }
        task.resume()
    }
}
