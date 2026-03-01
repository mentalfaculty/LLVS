//
//  MultipeerExchange.swift
//  LLVS
//
//  Created by Drew McCormack on 01/03/2026.
//

import Foundation

/// Protocol abstracting peer-to-peer data transport (e.g., wraps MCSession).
/// Apps implement this to bridge their MultipeerConnectivity session.
public protocol PeerTransport: AnyObject {
    func send(_ data: Data, toPeer peerID: String) throws
}

/// An Exchange that syncs between two peers via a direct data channel.
///
/// The app must call `receiveData(_:)` from its MCSessionDelegate (or equivalent)
/// whenever data arrives from the peer. MultipeerExchange handles the request-response
/// protocol internally.
///
/// Each peer runs its own MultipeerExchange instance. One peer's `send()`/`retrieve()`
/// sends requests to the other peer, which responds automatically via `handleRequest`.
public class MultipeerExchange: Exchange {

    public enum Error: Swift.Error {
        case transportUnavailable
        case timeout
        case invalidMessage
        case requestFailed(String)
    }

    // MARK: - PeerMessage

    struct PeerMessage: Codable {
        let id: String
        let type: MessageType
        var requestId: String?
        var payload: Data?

        enum MessageType: String, Codable {
            // Requests (client → server)
            case requestVersionIds
            case requestVersions
            case requestValueChanges

            // Responses (server → client)
            case responseVersionIds
            case responseVersions
            case responseValueChanges

            // Push (no response expected)
            case pushVersionChanges

            // Error
            case errorResponse
        }
    }

    // MARK: - Properties

    nonisolated public let store: Store
    public let peerID: String
    public weak var transport: PeerTransport?

    public let newVersionsAvailable: AsyncStream<Void>
    private let newVersionsContinuation: AsyncStream<Void>.Continuation

    public var restorationState: Data? {
        get { return nil }
        set {}
    }

    /// Actor that serializes internal state access
    private let state = State()

    private actor State {
        var pendingRequests: [String: CheckedContinuation<Data, Swift.Error>] = [:]

        func addRequest(id: String, continuation: CheckedContinuation<Data, Swift.Error>) {
            pendingRequests[id] = continuation
        }

        func removeRequest(id: String) -> CheckedContinuation<Data, Swift.Error>? {
            pendingRequests.removeValue(forKey: id)
        }
    }

    private let requestTimeout: UInt64 = 30_000_000_000 // 30 seconds in nanoseconds

    // MARK: - Init

    public init(store: Store, peerID: String, transport: PeerTransport?) {
        self.store = store
        self.peerID = peerID
        self.transport = transport
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.newVersionsAvailable = stream
        self.newVersionsContinuation = continuation
    }

    // MARK: - Incoming Data (call from MCSessionDelegate)

    /// Call this method from your MCSessionDelegate's `session(_:didReceive:fromPeer:)`.
    public func receiveData(_ data: Data) {
        guard let message = try? JSONDecoder().decode(PeerMessage.self, from: data) else {
            return
        }

        Task {
            switch message.type {
            case .requestVersionIds, .requestVersions, .requestValueChanges:
                await handleRequest(message)
            case .responseVersionIds, .responseVersions, .responseValueChanges:
                await handleResponse(message)
            case .pushVersionChanges:
                await handlePush(message)
            case .errorResponse:
                await handleResponse(message)
            }
        }
    }

    // MARK: - Exchange Protocol

    public func prepareToRetrieve() async throws {}
    public func prepareToSend() async throws {}

    public func retrieveAllVersionIdentifiers() async throws -> [Version.ID] {
        let responseData = try await sendRequest(type: .requestVersionIds, payload: nil)
        return try JSONDecoder().decode([Version.ID].self, from: responseData)
    }

    public func retrieveVersions(identifiedBy versionIds: [Version.ID]) async throws -> [Version] {
        guard !versionIds.isEmpty else { return [] }
        let payload = try JSONEncoder().encode(versionIds)
        let responseData = try await sendRequest(type: .requestVersions, payload: payload)
        return try JSONDecoder().decode([Version].self, from: responseData)
    }

    public func retrieveValueChanges(forVersionsIdentifiedBy versionIds: [Version.ID]) async throws -> [Version.ID: [Value.Change]] {
        guard !versionIds.isEmpty else { return [:] }
        let payload = try JSONEncoder().encode(versionIds)
        let responseData = try await sendRequest(type: .requestValueChanges, payload: payload)
        return try JSONDecoder().decode([Version.ID: [Value.Change]].self, from: responseData)
    }

    public func send(versionChanges: [VersionChanges]) async throws {
        guard !versionChanges.isEmpty else { return }
        let codable = versionChanges.map { CodableVersionChanges(version: $0.version, valueChanges: $0.valueChanges) }
        let payload = try JSONEncoder().encode(codable)
        let message = PeerMessage(id: UUID().uuidString, type: .pushVersionChanges, payload: payload)
        try sendMessage(message)
    }

    // MARK: - Request-Response

    private func sendRequest(type: PeerMessage.MessageType, payload: Data?) async throws -> Data {
        guard transport != nil else {
            throw Error.transportUnavailable
        }

        let requestId = UUID().uuidString
        let message = PeerMessage(id: requestId, type: type, payload: payload)

        return try await withCheckedThrowingContinuation { continuation in
            Task {
                await state.addRequest(id: requestId, continuation: continuation)

                do {
                    try sendMessage(message)
                } catch {
                    if let cont = await state.removeRequest(id: requestId) {
                        cont.resume(throwing: error)
                    }
                    return
                }

                // Timeout
                Task {
                    try? await Task.sleep(nanoseconds: requestTimeout)
                    if let cont = await state.removeRequest(id: requestId) {
                        cont.resume(throwing: Error.timeout)
                    }
                }
            }
        }
    }

    private func sendMessage(_ message: PeerMessage) throws {
        guard let transport = transport else {
            throw Error.transportUnavailable
        }
        let data = try JSONEncoder().encode(message)
        try transport.send(data, toPeer: peerID)
    }

    // MARK: - Handling Incoming Messages

    private func handleRequest(_ message: PeerMessage) async {
        do {
            let responsePayload: Data
            let responseType: PeerMessage.MessageType

            switch message.type {
            case .requestVersionIds:
                var allIds: [Version.ID] = []
                store.queryHistory { history in
                    allIds = history.allVersionIdentifiers
                }
                responsePayload = try JSONEncoder().encode(allIds)
                responseType = .responseVersionIds

            case .requestVersions:
                guard let payload = message.payload else { throw Error.invalidMessage }
                let versionIds = try JSONDecoder().decode([Version.ID].self, from: payload)
                let versions: [Version] = try versionIds.compactMap { try store.version(identifiedBy: $0) }
                responsePayload = try JSONEncoder().encode(versions)
                responseType = .responseVersions

            case .requestValueChanges:
                guard let payload = message.payload else { throw Error.invalidMessage }
                let versionIds = try JSONDecoder().decode([Version.ID].self, from: payload)
                var changesByVersion: [Version.ID: [Value.Change]] = [:]
                for id in versionIds {
                    changesByVersion[id] = try store.valueChanges(madeInVersionIdentifiedBy: id)
                }
                responsePayload = try JSONEncoder().encode(changesByVersion)
                responseType = .responseValueChanges

            default:
                return
            }

            let response = PeerMessage(id: UUID().uuidString, type: responseType, requestId: message.id, payload: responsePayload)
            try sendMessage(response)
        } catch {
            let errorResponse = PeerMessage(
                id: UUID().uuidString,
                type: .errorResponse,
                requestId: message.id,
                payload: error.localizedDescription.data(using: .utf8)
            )
            try? sendMessage(errorResponse)
        }
    }

    private func handleResponse(_ message: PeerMessage) async {
        guard let requestId = message.requestId else { return }

        if let continuation = await state.removeRequest(id: requestId) {
            if message.type == .errorResponse {
                let description = message.payload.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown error"
                continuation.resume(throwing: Error.requestFailed(description))
            } else {
                continuation.resume(returning: message.payload ?? Data())
            }
        }
    }

    private func handlePush(_ message: PeerMessage) async {
        guard let payload = message.payload else { return }

        do {
            let codable = try JSONDecoder().decode([CodableVersionChanges].self, from: payload)
            let versionChanges: [VersionChanges] = codable.map { ($0.version, $0.valueChanges) }

            for (version, valueChanges) in versionChanges {
                do {
                    try store.addVersion(version, storing: valueChanges)
                } catch Store.Error.attemptToAddExistingVersion {
                    // Ignore
                }
            }

            newVersionsContinuation.yield(())
        } catch {
            log.error("Failed to handle push: \(error)")
        }
    }
}

// MARK: - Codable Helper

private struct CodableVersionChanges: Codable {
    let version: Version
    let valueChanges: [Value.Change]
}
