import Testing
import Foundation
@testable import LLVS

/// `OAuthTokenStore` keeps the credential and collapses concurrent refreshes into one. The
/// single-flight part is what matters: Google and Microsoft may retire a refresh token as they
/// issue its replacement, so two refreshes racing can leave a good credential broken.
@Suite struct OAuthTokenStoreTests {

    private struct TestCredential: OAuthCredential {
        var accessToken: String
        var refreshToken: String
    }

    /// Keeps the credential in memory. A build machine often has no unlocked login keychain, so a
    /// test that used the real one would fail for a reason that has nothing to do with the store.
    private final class MemoryStorage: OAuthCredentialStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?

        func load() -> Data? { lock.withLock { data } }
        func save(_ newData: Data) { lock.withLock { data = newData } }
        func delete() { lock.withLock { data = nil } }
    }

    private func makeStore() -> OAuthTokenStore<TestCredential> {
        OAuthTokenStore(storage: MemoryStorage())
    }

    /// Counts how many times the exchange actually ran, and holds it open until released.
    private actor ExchangeRecorder {
        private(set) var callCount = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func recordCall() { callCount += 1 }

        /// Waits until `release` is called, so several refreshes can pile up together.
        func waitForRelease() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    @Test func aStoredCredentialComesBackOut() async {
        let store = makeStore()
        await store.store(TestCredential(accessToken: "access-1", refreshToken: "refresh-1"))

        let credential = await store.credential

        #expect(credential?.accessToken == "access-1")
        await store.clear()
    }

    @Test func clearingForgetsTheCredential() async {
        let store = makeStore()
        await store.store(TestCredential(accessToken: "access-1", refreshToken: "refresh-1"))

        await store.clear()

        let credential = await store.credential
        #expect(credential == nil)
    }

    @Test func refreshingWithNoCredentialFails() async {
        let store = makeStore()

        await #expect(throws: CloudFileSystemError.self) {
            try await store.refresh { _ in TestCredential(accessToken: "new", refreshToken: "new") }
        }
    }

    @Test func aRefreshStoresTheNewCredential() async throws {
        let store = makeStore()
        await store.store(TestCredential(accessToken: "old-access", refreshToken: "old-refresh"))

        let token = try await store.refresh { refreshToken in
            #expect(refreshToken == "old-refresh")
            return TestCredential(accessToken: "new-access", refreshToken: "new-refresh")
        }

        #expect(token == "new-access")
        let stored = await store.credential
        #expect(stored?.accessToken == "new-access")
        // The rotated refresh token must be kept, or the next refresh uses a retired one
        #expect(stored?.refreshToken == "new-refresh")
        await store.clear()
    }

    @Test func manyCallersAtOnceCauseOnlyOneRefresh() async throws {
        let store = makeStore()
        await store.store(TestCredential(accessToken: "old-access", refreshToken: "old-refresh"))
        let recorder = ExchangeRecorder()

        // Ten callers all find the token expired at the same moment
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await store.refresh { _ in
                        await recorder.recordCall()
                        // Hold every refresh open so they genuinely overlap
                        await recorder.waitForRelease()
                        return TestCredential(accessToken: "new-access", refreshToken: "new-refresh")
                    }
                }
            }

            // Let them all arrive and queue up behind the first before any completes
            try await Task.sleep(for: .milliseconds(50))
            await recorder.release()

            var collected: [String] = []
            for try await token in group { collected.append(token) }
            return collected
        }

        let callCount = await recorder.callCount
        #expect(callCount == 1, "only one refresh should reach the server")
        #expect(tokens.count == 10)
        #expect(tokens.allSatisfy { $0 == "new-access" }, "every caller gets the same new token")
        await store.clear()
    }

    @Test func aRefreshAfterAFailedOneCanStillSucceed() async throws {
        // A failed refresh must not leave the in-flight slot occupied
        struct RefreshFailure: Error {}
        let store = makeStore()
        await store.store(TestCredential(accessToken: "old-access", refreshToken: "old-refresh"))

        await #expect(throws: RefreshFailure.self) {
            try await store.refresh { _ in throw RefreshFailure() }
        }

        let token = try await store.refresh { _ in
            TestCredential(accessToken: "second-access", refreshToken: "second-refresh")
        }

        #expect(token == "second-access")
        await store.clear()
    }

    @Test func aFailedRefreshReachesEveryCallerWaitingOnIt() async throws {
        struct RefreshFailure: Error {}
        let store = makeStore()
        await store.store(TestCredential(accessToken: "old-access", refreshToken: "old-refresh"))
        let recorder = ExchangeRecorder()

        let failures = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        _ = try await store.refresh { _ in
                            await recorder.recordCall()
                            await recorder.waitForRelease()
                            throw RefreshFailure()
                        }
                        return false
                    } catch {
                        return true
                    }
                }
            }

            try? await Task.sleep(for: .milliseconds(50))
            await recorder.release()

            var count = 0
            for await didFail in group where didFail { count += 1 }
            return count
        }

        #expect(failures == 5, "the one failure is reported to everyone who waited for it")
        let callCount = await recorder.callCount
        #expect(callCount == 1)
        await store.clear()
    }

    @Test func aRefreshFinishingAfterADeauthorizeDoesNotDisturbALaterOne() async throws {
        // Deauthorizing cancels the running refresh, but that task still has to unwind, and its
        // clean-up must not clear a slot that by then belongs to a refresh started afterwards.
        // Otherwise the next caller starts a second refresh next to a running one.
        let store = makeStore()
        await store.store(TestCredential(accessToken: "old-access", refreshToken: "old-refresh"))
        let firstRefresh = ExchangeRecorder()

        let abandoned = Task {
            try await store.refresh { _ in
                await firstRefresh.recordCall()
                await firstRefresh.waitForRelease()
                return TestCredential(accessToken: "abandoned", refreshToken: "abandoned")
            }
        }
        // Let it take the slot before it is cancelled
        try await Task.sleep(for: .milliseconds(20))

        await store.clear()
        await store.store(TestCredential(accessToken: "new-access", refreshToken: "new-refresh"))

        let secondRefresh = ExchangeRecorder()
        let second = Task {
            try await store.refresh { _ in
                await secondRefresh.recordCall()
                await secondRefresh.waitForRelease()
                return TestCredential(accessToken: "second", refreshToken: "second")
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        // The abandoned refresh now unwinds, while the second is still in flight
        await firstRefresh.release()
        _ = try? await abandoned.value
        try await Task.sleep(for: .milliseconds(20))

        // A third caller must join the second refresh, not start a third one
        let third = Task { try await store.refresh { _ in
            await secondRefresh.recordCall()
            return TestCredential(accessToken: "third", refreshToken: "third")
        } }
        try await Task.sleep(for: .milliseconds(20))
        await secondRefresh.release()

        _ = try? await second.value
        _ = try? await third.value

        let callCount = await secondRefresh.callCount
        #expect(callCount == 1, "the third caller should join the running refresh, not start another")
        await store.clear()
    }

    @Test func aCallerRefusedTheInFlightResultGetsAFurtherRefresh() async throws {
        // A request whose token was just refused must not be handed that same token back. That
        // happens when it joins a refresh that was already producing it: the joiner gets the token
        // it already knows is dead, and its retry fails for the same reason.
        let store = makeStore()
        await store.store(TestCredential(accessToken: "token-1", refreshToken: "refresh-1"))
        let firstExchange = ExchangeRecorder()

        // Caller A refreshes token-1, and its exchange is held open producing token-2
        let callerA = Task {
            try await store.refresh { _ in
                await firstExchange.recordCall()
                await firstExchange.waitForRelease()
                return TestCredential(accessToken: "token-2", refreshToken: "refresh-2")
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        // Caller B was already using token-2 and had it refused, so token-2 is no use to it
        let callerB = Task {
            try await store.refresh(replacing: "token-2") { _ in
                TestCredential(accessToken: "token-3", refreshToken: "refresh-3")
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        await firstExchange.release()

        let tokenForA = try await callerA.value
        let tokenForB = try await callerB.value

        #expect(tokenForA == "token-2")
        #expect(tokenForB == "token-3", "B must not be handed back the token it just had refused")
        await store.clear()
    }

    @Test func aCallerIsStillJoinedWhenTheInFlightResultIsNew() async throws {
        // The other side of it: if the refresh in flight produces a token the caller has NOT seen
        // refused, joining is right and a second refresh would be wasted
        let store = makeStore()
        await store.store(TestCredential(accessToken: "token-1", refreshToken: "refresh-1"))
        let exchange = ExchangeRecorder()

        let callerA = Task {
            try await store.refresh { _ in
                await exchange.recordCall()
                await exchange.waitForRelease()
                return TestCredential(accessToken: "token-2", refreshToken: "refresh-2")
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        // B was using the older token-1, so the token-2 being produced is genuinely new to it
        let callerB = Task {
            try await store.refresh(replacing: "token-1") { _ in
                await exchange.recordCall()
                return TestCredential(accessToken: "token-3", refreshToken: "refresh-3")
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        await exchange.release()

        let tokenForA = try await callerA.value
        let tokenForB = try await callerB.value

        #expect(tokenForA == "token-2")
        #expect(tokenForB == "token-2", "B joins the refresh already running")
        let callCount = await exchange.callCount
        #expect(callCount == 1, "no second refresh is needed")
        await store.clear()
    }

    @Test func aLaterRefreshRunsAgainRatherThanReusingTheOldResult() async throws {
        // Once a refresh finishes, the next one is a new request — the slot must have been cleared
        let store = makeStore()
        await store.store(TestCredential(accessToken: "old-access", refreshToken: "old-refresh"))

        let first = try await store.refresh { _ in
            TestCredential(accessToken: "access-1", refreshToken: "refresh-1")
        }
        let second = try await store.refresh { refreshToken in
            // The second refresh must use the token the first one stored
            #expect(refreshToken == "refresh-1")
            return TestCredential(accessToken: "access-2", refreshToken: "refresh-2")
        }

        #expect(first == "access-1")
        #expect(second == "access-2")
        await store.clear()
    }
}
