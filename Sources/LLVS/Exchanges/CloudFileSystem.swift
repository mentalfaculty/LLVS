//
//  CloudFileSystem.swift
//  LLVS
//
//  Created by Drew McCormack on 03/03/2026.
//

import Foundation

/// Errors that can occur when interacting with a cloud file system.
public enum CloudFileSystemError: Error {
    case fileNotFound
    case uploadFailed
    case downloadFailed
    case directoryListingFailed
    case authenticationFailed
    case serverError(statusCode: Int)
}

/// A protocol for file-level operations on a cloud storage service.
///
/// Paths are relative strings (e.g. `"versions/ABC-123"`).
/// Implementations map these to service-specific addressing.
/// `upload` creates intermediate directories as needed.
public protocol CloudFileSystem: AnyObject, Sendable {

    /// Returns `true` if a file exists at the given path.
    func fileExists(at path: String) async throws -> Bool

    /// Returns the file names (not full paths) of items in the directory at the given path.
    func contentsOfDirectory(at path: String) async throws -> [String]

    /// Uploads data to the given path, creating intermediate directories as needed.
    func upload(data: Data, to path: String) async throws

    /// Downloads data from the given path.
    func download(from path: String) async throws -> Data

    /// Removes the file at the given path. Does not throw if the file doesn't exist.
    func remove(at path: String) async throws

    /// Removes the directory at the given path and all its contents. Does not throw if the directory doesn't exist.
    func removeDirectory(at path: String) async throws
}
