//
//  OAuthTokenStore.swift
//  LLVS
//
//  Created by Drew McCormack on 18/09/2026.
//

import Foundation

/// What an OAuth credential has to offer for the store to keep it.
public protocol OAuthCredential: Codable, Sendable {
    /// The token used to get a new access token once the current one expires.
    var refreshToken: String { get }
    /// The token sent with each request.
    var accessToken: String { get }
}

/// Where a credential is kept between launches.
///
/// The Keychain is the real one. Tests use their own, because a build machine often has no unlocked
/// login keychain, and a test that silently fails to save would look like a broken store.
public protocol OAuthCredentialStorage: Sendable {
    func load() -> Data?
    func save(_ data: Data)
    func delete()
}

/// Keeps an OAuth credential in the Keychain, and makes sure only one refresh runs at a time.
///
/// Several uploads running at once all see the token expire together. Without single-flight they
/// would each ask for a refresh, and a provider that rotates refresh tokens — Google and Microsoft
/// both may — can invalidate the earlier ones as it issues new ones. The last reply to arrive would
/// then overwrite a good credential with one whose refresh token the server has already retired.
public actor OAuthTokenStore<Credential: OAuthCredential> {

    private let storage: any OAuthCredentialStorage
    private var stored: Credential?
    private var loadedFromStorage = false

    /// The refresh currently running, if any. Later callers await this instead of starting their own.
    private var refreshInFlight: Task<String, any Error>?

    /// Counts refreshes, so a task that finishes late can tell whether the slot is still its own.
    private var refreshGeneration: UInt64 = 0

    public init(keychainService: String, keychainAccount: String = "credential") {
        self.storage = KeychainCredentialStorage(service: keychainService, account: keychainAccount)
    }

    /// - Parameter storage: Where to keep the credential. Mainly for tests.
    public init(storage: any OAuthCredentialStorage) {
        self.storage = storage
    }

    /// The stored credential, read from storage the first time it is asked for.
    public var credential: Credential? {
        if !loadedFromStorage {
            stored = storage.load().flatMap { try? JSONDecoder().decode(Credential.self, from: $0) }
            loadedFromStorage = true
        }
        return stored
    }

    public func store(_ credential: Credential) {
        stored = credential
        loadedFromStorage = true
        if let data = try? JSONEncoder().encode(credential) { storage.save(data) }
    }

    /// Forgets the credential, here and in storage.
    public func clear() {
        stored = nil
        loadedFromStorage = true
        refreshInFlight?.cancel()
        refreshInFlight = nil
        // Move past the cancelled task's generation, so its clean-up cannot claim a later slot
        refreshGeneration &+= 1
        storage.delete()
    }

    /// Gets a new access token by running `exchange`, unless a refresh is already in flight, in
    /// which case this waits for that one and takes its answer.
    ///
    /// - Parameter exchange: Trades the refresh token for a new credential. It is handed the current
    ///   refresh token, and its result is stored before the access token is returned.
    /// - Parameter staleAccessToken: The token the caller just had refused, if it was refused. A
    ///   refresh already in flight might be producing that very token, and handing it back would
    ///   send the caller off to fail again with it. When that happens, this waits for the running
    ///   refresh and then starts one of its own.
    public func refresh(
        replacing staleAccessToken: String? = nil,
        _ exchange: @escaping @Sendable (String) async throws -> Credential
    ) async throws -> String {
        // A loop, not an `if`: awaiting suspends, and by the time this resumes a different refresh
        // may hold the slot. Joining that one is still better than racing it
        while let refreshInFlight {
            let token = try await refreshInFlight.value
            // Usually the right answer, and the whole point of collapsing the refreshes
            guard let staleAccessToken, token == staleAccessToken else { return token }
            // It is the dead token. If someone else has since started a refresh, join that one;
            // otherwise fall out of the loop and start one
            if self.refreshInFlight == nil { break }
        }

        guard let refreshToken = credential?.refreshToken else {
            throw CloudFileSystemError.authenticationFailed
        }

        // The task stores the result and clears the slot itself. Doing either in this function
        // would be wrong: the first caller to return would clear the slot while others still await
        // the task, and the next arrival would start a second refresh alongside the running one.
        let generation = refreshGeneration &+ 1
        refreshGeneration = generation

        let task = Task<String, any Error> { [self] in
            // Only give up the slot if it is still ours. A `clear()` takes it away and a later
            // refresh puts its own task there, and that one must not be cancelled out by this
            // one unwinding afterwards
            defer { if refreshGeneration == generation { refreshInFlight = nil } }
            let credential = try await exchange(refreshToken)
            store(credential)
            return credential.accessToken
        }
        refreshInFlight = task

        return try await task.value
    }

}

// MARK: - Keychain

/// Keeps the credential in the system Keychain, as a generic password.
struct KeychainCredentialStorage: OAuthCredentialStorage {

    let service: String
    let account: String

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func save(_ data: Data) {
        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)

        // A failed save is silent otherwise, and the user is quietly signed out at the next launch.
        // There is nothing to do about it here, so say so rather than throwing into a refresh
        if status != errSecSuccess {
            log.error("Could not save the OAuth credential to the Keychain: OSStatus \(status). Sync will work until the token expires, then ask to sign in again.")
        }
    }

    func load() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
