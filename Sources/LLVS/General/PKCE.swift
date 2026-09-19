//
//  PKCE.swift
//  LLVS
//
//  Created by Drew McCormack on 18/09/2026.
//

import Foundation
import CryptoKit

/// A PKCE verifier and its challenge, as described by RFC 7636.
///
/// The app invents a secret, sends only a hash of it when it opens the browser, and sends the secret
/// itself when it trades the code for tokens. An attacker who intercepts the redirect gets a code
/// they cannot spend, because they do not have the secret that goes with it.
///
/// Public OAuth clients — apps with no client secret, which is what a shipped app must be — need
/// this. Without it, any app that registers the same redirect scheme can claim the code.
public struct PKCEChallenge: Sendable {

    /// The secret. Sent only to the token endpoint, never to the browser.
    public let verifier: String

    /// The SHA-256 of the verifier, base64url encoded. This is what goes in the authorization URL.
    public let challenge: String

    /// The method name the server expects alongside the challenge.
    public static let method = "S256"

    /// Makes a fresh verifier and its challenge.
    public init() {
        self.verifier = Self.makeVerifier()
        self.challenge = Self.challenge(for: verifier)
    }

    /// Makes a challenge for a verifier you already have. Mainly for tests.
    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
    }

    /// A 43-character verifier, the shortest RFC 7636 allows, from 32 random bytes.
    static func makeVerifier() -> String {
        base64URLEncoded(randomBytes(count: 32))
    }

    static func challenge(for verifier: String) -> String {
        base64URLEncoded(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Base64 without the characters that need escaping in a URL, and without padding.
    static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            // The system random source failing is not something an app can carry on through: a
            // predictable verifier would defeat the point of PKCE
            preconditionFailure("Could not read random bytes for PKCE: OSStatus \(status)")
        }
        return Data(bytes)
    }
}

/// The `state` parameter, which ties a callback back to the request that started it.
///
/// It is not a secret. It is there so a callback arriving from somewhere else — a stale redirect, or
/// one an attacker triggered — can be told apart from the one this app asked for.
public enum OAuthState {

    /// A fresh, unguessable value to send with an authorization request.
    public static func make() -> String {
        PKCEChallenge.base64URLEncoded(PKCEChallenge.randomBytes(count: 32))
    }

    /// Compares two state values in constant time, so a wrong guess learns nothing from how long
    /// the comparison took.
    public static func matches(_ returned: String, _ expected: String) -> Bool {
        let returnedBytes = Array(returned.utf8)
        let expectedBytes = Array(expected.utf8)
        guard returnedBytes.count == expectedBytes.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(returnedBytes, expectedBytes) { difference |= a ^ b }
        return difference == 0
    }
}

public extension CharacterSet {
    /// Characters safe to leave unescaped in an `application/x-www-form-urlencoded` value.
    ///
    /// `.urlQueryAllowed` is too generous: it permits `+`, `&` and `=`, each of which changes what a
    /// form body means. A token containing one would arrive at the server corrupted.
    static let oauthFormAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
}
