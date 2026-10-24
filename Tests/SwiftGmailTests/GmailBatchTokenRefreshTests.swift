import Foundation
import os
import Testing
@testable import SwiftGmail

/// The Gmail batch path against a stale access token (2026-10-05 device logs).
///
/// A pass frozen overnight sent `/batch` with a token that had expired hours
/// earlier; every sub-response was 401 and the batch path DROPPED them — not
/// retried, not reported as leftovers — so the quick-sync cursor stepped over
/// mail it never fetched. Locked in here:
///   1. A 401 (per part or on the envelope) earns ONE forced refresh per batch
///      call and one re-issue, and the ids then arrive.
///   2. A 401 that outlives the refresh comes back as `leftover` +
///      `authRejected` — never dropped — and the public entry point turns it
///      into the credential-shaped `authenticationFailed` the codebase already
///      throws for a revoked refresh token.
///   3. The token is resolved per REQUEST, after the bucket's wait, so a call
///      that spans an expiry sends the new token on the later request.
///
/// All tokens are fake `tok-test-*` strings; the stub only claims requests
/// carrying one, so it never answers another suite's traffic. Nested inside
/// `GmailAPIClientBatchTests` for the same reason `GmailBatch403RateLimitTests`
/// is: every suite here registers a `URLProtocol` globally, and only a shared
/// `.serialized` ancestor keeps them from running at the same time.
extension GmailAPIClientBatchTests {

@Suite("Gmail batch — 401 refresh-and-retry, per-request token", .serialized)
struct GmailBatchTokenRefreshTests {

    // MARK: - Token source fake

    /// Hands out `stale` until refreshed, then `fresh`. Counts refreshes.
    /// Like a real token store, a rejection of a token
    /// that is no longer current hands back the current one without
    /// refreshing again.
    final class FakeTokens: Sendable {
        private struct State {
            var current: String
            var refreshes = 0
            var rejected: [String] = []
        }
        private let state: OSAllocatedUnfairLock<State>
        private let fresh: String

        init(stale: String = "tok-test-stale", fresh: String = "tok-test-fresh") {
            self.state = OSAllocatedUnfairLock(initialState: State(current: stale))
            self.fresh = fresh
        }

        var refreshes: Int { state.withLock { $0.refreshes } }
        var rejected: [String] { state.withLock { $0.rejected } }

        var source: GmailTokenSource {
            GmailTokenSource { [self] rejected in
                state.withLock { state in
                    if let rejected, rejected == state.current {
                        state.refreshes += 1
                        state.rejected.append(rejected)
                        state.current = fresh
                    }
                    return state.current
                }
            }
        }
    }

    // MARK: - Fixtures

    private static let boundary = "token_boundary"

    private static func messageJSON(_ id: String) -> String {
        #"{"id":"\#(id)","threadId":"t-\#(id)","snippet":"s","internalDate":"1700000000000"}"#
    }

    private static let unauthorizedJSON =
        #"{"error":{"code":401,"message":"Request had invalid authentication credentials.","status":"UNAUTHENTICATED"}}"#

    /// Sub-request paths in the outgoing envelope, in order — the reply is
    /// sized and labelled to match whatever the client actually sent.
    private static func requestedIds(in request: URLRequest) -> [String] {
        guard let body = request.httpBody, let text = String(data: body, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\r\n")
            .filter { $0.hasPrefix("GET /gmail/v1/users/me/") }
            .compactMap { line in
                line.split(separator: " ").dropFirst().first
                    .flatMap { $0.split(separator: "?").first }
                    .flatMap { $0.split(separator: "/").last }
                    .map(String.init)
            }
    }

    private static func reply(
        for request: URLRequest,
        status: (String) -> Int
    ) -> TokenStub.Reply {
        var text = ""
        for (index, id) in requestedIds(in: request).enumerated() {
            let code = status(id)
            text += "--\(boundary)\r\n"
            text += "Content-Type: application/http\r\n"
            text += "Content-ID: <response-op-\(index)>\r\n\r\n"
            text += "HTTP/1.1 \(code) X\r\n"
            text += "Content-Type: application/json\r\n\r\n"
            text += code == 200 ? messageJSON(id) : (code == 401 ? unauthorizedJSON : "{}")
            text += "\r\n"
        }
        text += "--\(boundary)--\r\n"
        return TokenStub.Reply(
            status: 200,
            contentType: "multipart/mixed; boundary=\(boundary)",
            body: Data(text.utf8)
        )
    }

    private static func bearer(_ request: URLRequest) -> String {
        String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst("Bearer ".count))
    }

    private static func unpacedClient() -> GmailAPIClient {
        GmailAPIClient(quotaBucket: GmailQuotaBucket(sleeper: { _ in }))
    }

    private static func outcome(
        ids: [String],
        tokens: GmailTokenSource,
        quotaKey: String,
        client: GmailAPIClient = GmailBatchTokenRefreshTests.unpacedClient()
    ) async throws -> BatchFetchOutcome<GmailMessage> {
        try await client.batchGet(
            tokenSource: tokens,
            resource: "messages",
            ids: ids,
            format: .metadata,
            unitCost: GmailQuotaProfile.current.messagesGetCost,
            quotaKey: quotaKey,
            retryDelay: 0,
            as: GmailMessage.self
        )
    }

    // MARK: - 1. Refresh once, retry, succeed

    @Test("Every part 401 → one forced refresh, one re-issue, every id fetched")
    func allPartsUnauthorizedRefreshesOnceAndSucceeds() async throws {
        let tokens = FakeTokens()
        TokenStub.install { request in
            let stale = Self.bearer(request) == "tok-test-stale"
            return Self.reply(for: request) { _ in stale ? 401 : 200 }
        }
        defer { TokenStub.uninstall() }

        let outcome = try await Self.outcome(ids: ["m0", "m1", "m2"], tokens: tokens.source, quotaKey: "401-retry")

        #expect(outcome.fetched.map(\.id) == ["m0", "m1", "m2"])
        #expect(outcome.leftover.isEmpty)
        #expect(!outcome.authRejected)
        #expect(tokens.refreshes == 1)
        #expect(tokens.rejected == ["tok-test-stale"], "the refresh names the token Gmail refused")
        #expect(TokenStub.bearers == ["tok-test-stale", "tok-test-fresh"])
    }

    @Test("An ENVELOPE-level 401 gets the same single refresh and re-issue")
    func envelopeUnauthorizedRefreshesOnceAndSucceeds() async throws {
        let tokens = FakeTokens()
        TokenStub.install { request in
            if Self.bearer(request) == "tok-test-stale" {
                return TokenStub.Reply(status: 401, contentType: "application/json", body: Data(Self.unauthorizedJSON.utf8))
            }
            return Self.reply(for: request) { _ in 200 }
        }
        defer { TokenStub.uninstall() }

        let outcome = try await Self.outcome(ids: ["m0", "m1"], tokens: tokens.source, quotaKey: "401-envelope")

        #expect(outcome.fetched.map(\.id) == ["m0", "m1"])
        #expect(outcome.leftover.isEmpty)
        #expect(tokens.refreshes == 1)
    }

    @Test("Concurrent chunks that all hit a stale token share ONE refresh")
    func concurrentChunksShareOneRefresh() async throws {
        let tokens = FakeTokens()
        TokenStub.install { request in
            let stale = Self.bearer(request) == "tok-test-stale"
            return Self.reply(for: request) { _ in stale ? 401 : 200 }
        }
        // Hold every stale reply until all three in-flight chunks have SENT
        // with the stale token — so the chunks provably overlap, and each one
        // really does see a 401 before any refresh exists.
        TokenStub.holdStaleReplies(until: GmailBatchProtocol.maxBatchesInFlight(for: .metadata))
        defer { TokenStub.uninstall() }

        let ids = (0..<150).map { "m\($0)" }
        let outcome = try await Self.outcome(ids: ids, tokens: tokens.source, quotaKey: "401-chunks")

        #expect(outcome.fetched.map(\.id) == ids)
        #expect(outcome.leftover.isEmpty)
        #expect(tokens.refreshes == 1, "one refresh per batch call, however many chunks saw the 401")
        #expect(TokenStub.bearers.prefix(3).allSatisfy { $0 == "tok-test-stale" }, "all three chunks were in flight on the stale token at once")
    }

    // MARK: - 2. Still 401 after the refresh

    @Test("Still 401 after the refresh → ids are LEFTOVERS with authRejected, never dropped; no second refresh")
    func persistentUnauthorizedBecomesLeftover() async throws {
        let tokens = FakeTokens()
        TokenStub.install { request in
            Self.reply(for: request) { id in id == "m1" ? 200 : 401 }
        }
        defer { TokenStub.uninstall() }

        let outcome = try await Self.outcome(ids: ["m0", "m1", "m2"], tokens: tokens.source, quotaKey: "401-persistent")

        #expect(outcome.fetched.map(\.id) == ["m1"])
        #expect(Set(outcome.leftover) == ["m0", "m2"], "a 401 is owed, not dropped")
        #expect(outcome.authRejected)
        #expect(tokens.refreshes == 1, "bounded: one refresh per batch call")
        #expect(TokenStub.bearers.count == 2, "first send + one re-issue of the 401'd ids")
    }

    @Test("The public entry point surfaces a surviving 401 as the credential-shaped authenticationFailed")
    func persistentUnauthorizedSurfacesAuthFailure() async throws {
        let tokens = FakeTokens()
        TokenStub.install { request in
            Self.reply(for: request) { _ in 401 }
        }
        defer { TokenStub.uninstall() }

        do {
            _ = try await Self.unpacedClient().getMessagesOutcome(
                tokenSource: tokens.source,
                messageIds: ["m0"],
                format: .metadata,
                quotaKey: "401-surface"
            )
            Issue.record("a 401 that survived the refresh must throw")
        } catch let error as GmailAPIError {
            guard case .authenticationFailed(let detail) = error else {
                Issue.record("expected authenticationFailed, got \(error)")
                return
            }
            // Hosts read a `status 4xx` detail as "sign in again", not "try later".
            #expect(detail.contains("status 401"))
        }
        #expect(tokens.refreshes == 1)
    }

    @Test("A refresh that fails (revoked grant) propagates its own authenticationFailed")
    func failedRefreshPropagates() async throws {
        struct RevokedGrant: Error {}
        let bridge = GmailCredentialErrors(
            isCredentialFailure: { $0 is RevokedGrant },
            rejectedRefreshedToken: { GmailAPIError.authenticationFailed($0) }
        )
        let source = GmailTokenSource(credentialErrors: bridge) { rejected in
            if rejected != nil { throw RevokedGrant() }
            return "tok-test-stale"
        }
        TokenStub.install { request in
            Self.reply(for: request) { _ in 401 }
        }
        defer { TokenStub.uninstall() }

        await #expect(throws: RevokedGrant.self) {
            _ = try await Self.outcome(ids: ["m0"], tokens: source, quotaKey: "401-revoked")
        }
    }

    // MARK: - 3. Token resolved per request

    @Test("A call that spans a token expiry sends the NEW token on the later request")
    func tokenResolvedPerRequest() async throws {
        // The bucket parks the account for its cooldown after the 429 round;
        // that wait (virtual here, hours on a frozen phone) is where the token
        // expires. The source answers by the clock, like getValidToken does.
        let clock = GmailBatch403RateLimitTests.VirtualClock()
        let client = GmailAPIClient(quotaBucket: clock.bucket())
        let source = GmailTokenSource { _ in
            clock.elapsed < 30 ? "tok-test-before-expiry" : "tok-test-after-expiry"
        }
        TokenStub.install { request in
            let early = Self.bearer(request) == "tok-test-before-expiry"
            return Self.reply(for: request) { _ in early ? 429 : 200 }
        }
        defer { TokenStub.uninstall() }

        let outcome = try await Self.outcome(ids: ["m0", "m1"], tokens: source, quotaKey: "per-request", client: client)

        #expect(TokenStub.bearers == ["tok-test-before-expiry", "tok-test-after-expiry"],
                "the re-issue resolved its token after the wait, not once up front")
        #expect(outcome.fetched.map(\.id) == ["m0", "m1"])
        #expect(outcome.leftover.isEmpty)
    }

    // MARK: - history.list

    @Test("history.list: a 401 earns one refresh and one re-send with the new token")
    func historyUnauthorizedRefreshesOnce() async throws {
        let tokens = FakeTokens()
        TokenStub.install { request in
            if Self.bearer(request) == "tok-test-stale" {
                return TokenStub.Reply(status: 401, contentType: "application/json", body: Data(Self.unauthorizedJSON.utf8))
            }
            return TokenStub.Reply(status: 200, contentType: "application/json", body: Data(#"{"historyId":"42"}"#.utf8))
        }
        defer { TokenStub.uninstall() }

        let response = try await Self.unpacedClient().listHistory(
            tokenSource: tokens.source, startHistoryId: "1", quotaKey: "history-401"
        )

        #expect(response.historyId == "42")
        #expect(tokens.refreshes == 1)
        #expect(TokenStub.bearers == ["tok-test-stale", "tok-test-fresh"])
    }

    @Test("history.list: the 401 re-send is metered through the quota bucket like any request")
    func historyResendIsMetered() async throws {
        let tokens = FakeTokens()
        let clock = GmailBatch403RateLimitTests.VirtualClock()
        let bucket = clock.bucket()
        TokenStub.install { request in
            if Self.bearer(request) == "tok-test-stale" {
                return TokenStub.Reply(status: 401, contentType: "application/json", body: Data(Self.unauthorizedJSON.utf8))
            }
            return TokenStub.Reply(status: 200, contentType: "application/json", body: Data(#"{"historyId":"42"}"#.utf8))
        }
        defer { TokenStub.uninstall() }

        _ = try await GmailAPIClient(quotaBucket: bucket).listHistory(
            tokenSource: tokens.source, startHistoryId: "1", quotaKey: "history-meter"
        )

        // The first debit starts at "now" and waits nothing; only a SECOND
        // debit queues behind it and makes the (virtual) clock move.
        let oneSend = Double(GmailQuotaProfile.current.unitCost.historyList) / GmailQuotaProfile.current.unitsPerSecond
        #expect(abs(clock.elapsed - oneSend) < 0.001, "the re-send paid for its own reservation")
    }

    @Test("Outcome classification: 429 and rate-reason 403 are transient; 5xx, a missing part, an undecodable body and a refusal are not")
    func outcomeClassification() async throws {
        let clock = GmailBatch403RateLimitTests.VirtualClock()
        let client = GmailAPIClient(quotaBucket: clock.bucket())
        let rate403 = GmailBatch403RateLimitTests.errorJSON(code: 403, reason: "userRateLimitExceeded", status: "PERMISSION_DENIED")
        let refusal403 = #"{"error":{"code":403,"message":"m","errors":[{"domain":"global","reason":"insufficientPermissions","message":"m"}],"status":"PERMISSION_DENIED"}}"#
        TokenStub.install { request in
            var text = ""
            for (index, id) in Self.requestedIds(in: request).enumerated() {
                let (code, body): (Int, String)
                switch id {
                case "m0": (code, body) = (429, "{}")
                case "m1": (code, body) = (403, rate403)
                case "m2": (code, body) = (503, "{}")
                case "m3": continue                                   // no part at all
                case "m4": (code, body) = (200, "not json")
                case "m5": (code, body) = (403, refusal403)
                case "m6": (code, body) = (404, "{}")
                default:   (code, body) = (200, Self.messageJSON(id))
                }
                text += "--\(Self.boundary)\r\nContent-Type: application/http\r\nContent-ID: <response-op-\(index)>\r\n\r\n"
                text += "HTTP/1.1 \(code) X\r\nContent-Type: application/json\r\n\r\n\(body)\r\n"
            }
            text += "--\(Self.boundary)--\r\n"
            return TokenStub.Reply(status: 200, contentType: "multipart/mixed; boundary=\(Self.boundary)", body: Data(text.utf8))
        }
        defer { TokenStub.uninstall() }

        let outcome = try await Self.outcome(
            ids: (0...7).map { "m\($0)" }, tokens: .fixed("tok-test-fixed"), quotaKey: "classify", client: client
        )

        #expect(outcome.fetched.map(\.id) == ["m7"])
        #expect(Set(outcome.leftover) == ["m0", "m1", "m2", "m3"])
        #expect(Set(outcome.transient) == ["m0", "m1"], "only rate signals are uncharged")
        #expect(Set(outcome.failed) == ["m4", "m5"], "answered but unusable — owed slowly, not dropped")
        #expect(outcome.notFound == ["m6"])
    }

    // MARK: - Fallback, fixed tokens, threads

    @Test("Per-id fallback: a 401 earns one refresh and a re-send with the new token")
    func fallbackUnauthorizedRefreshesAndSucceeds() async throws {
        let tokens = FakeTokens()
        TokenStub.install { request in
            if request.url?.path.contains("/batch/") == true {
                return TokenStub.Reply(status: 400, contentType: "text/plain", body: Data())
            }
            if Self.bearer(request) == "tok-test-stale" {
                return TokenStub.Reply(status: 401, contentType: "application/json", body: Data(Self.unauthorizedJSON.utf8))
            }
            let id = request.url?.lastPathComponent ?? ""
            return TokenStub.Reply(status: 200, contentType: "application/json", body: Data(Self.messageJSON(id).utf8))
        }
        defer { TokenStub.uninstall() }

        let outcome = try await Self.unpacedClient().getMessagesOutcome(
            tokenSource: tokens.source, messageIds: ["m0", "m1"], format: .metadata, quotaKey: "fallback-401"
        )

        #expect(Set(outcome.fetched.map(\.id)) == ["m0", "m1"])
        #expect(outcome.leftover.isEmpty)
        #expect(tokens.refreshes >= 1)
    }

    @Test("Per-id fallback: still 401 after the refresh → owed, flagged and thrown as the credential failure")
    func fallbackPersistentUnauthorizedSurfaces() async throws {
        let tokens = FakeTokens()
        TokenStub.install { request in
            if request.url?.path.contains("/batch/") == true {
                return TokenStub.Reply(status: 400, contentType: "text/plain", body: Data())
            }
            return TokenStub.Reply(status: 401, contentType: "application/json", body: Data(Self.unauthorizedJSON.utf8))
        }
        defer { TokenStub.uninstall() }

        let fallback = try? await Self.unpacedClient().getMessagesIndividually(
            tokenSource: .fixed("tok-test-stale"), messageIds: ["m0"], format: .metadata, quotaKey: "fallback-fixed"
        )
        #expect(fallback?.leftover == ["m0"], "a 401 is owed on the fallback path too")
        #expect(fallback?.authRejected == true)

        await #expect(throws: GmailAPIError.self) {
            _ = try await Self.unpacedClient().getMessagesOutcome(
                tokenSource: tokens.source, messageIds: ["m0"], format: .metadata, quotaKey: "fallback-persistent"
            )
        }
    }

    @Test("Per-id fallback: an unreachable id is a transient LEFTOVER, never dropped as gone")
    func fallbackUnreachableIsLeftover() async throws {
        TokenStub.install { request in
            if request.url?.path.contains("/batch/") == true {
                return TokenStub.Reply(status: 400, contentType: "text/plain", body: Data())
            }
            if request.url?.lastPathComponent == "m1" {
                return TokenStub.Reply(status: 0, contentType: nil, body: Data(), failWith: .notConnectedToInternet)
            }
            let id = request.url?.lastPathComponent ?? ""
            return TokenStub.Reply(status: 200, contentType: "application/json", body: Data(Self.messageJSON(id).utf8))
        }
        defer { TokenStub.uninstall() }

        let outcome = try await Self.unpacedClient().getMessagesOutcome(
            tokenSource: .fixed("tok-test-fixed"), messageIds: ["m0", "m1"], format: .metadata, quotaKey: "fallback-offline"
        )

        #expect(outcome.fetched.map(\.id) == ["m0"])
        #expect(outcome.leftover == ["m1"], "could not reach Gmail ≠ the message is gone")
        #expect(outcome.transient == ["m1"], "and it is not the id's fault — never charged")
        #expect(outcome.notFound.isEmpty)
    }

    @Test("A .fixed source reports surviving 401s as leftover + authRejected WITHOUT throwing")
    func fixedSourceReturnsLeftoverWithoutThrowing() async throws {
        TokenStub.install { request in
            Self.reply(for: request) { _ in 401 }
        }
        defer { TokenStub.uninstall() }

        let outcome = try await Self.unpacedClient().getMessagesOutcome(
            tokenSource: .fixed("tok-test-fixed"), messageIds: ["m0", "m1"], format: .metadata, quotaKey: "fixed-401"
        )
        #expect(outcome.fetched.isEmpty)
        #expect(Set(outcome.leftover) == ["m0", "m1"])
        #expect(outcome.authRejected)
        #expect(TokenStub.bearers == ["tok-test-fixed"], "a token that cannot refresh is not re-sent")
    }

    @Test("getThreadsBatch throws the credential failure when 401s outlive the refresh")
    func threadsBatchThrowsOnAuthRejected() async throws {
        let tokens = FakeTokens()
        TokenStub.install { request in
            Self.reply(for: request) { _ in 401 }
        }
        defer { TokenStub.uninstall() }

        await #expect(throws: GmailAPIError.self) {
            _ = try await Self.unpacedClient().getThreadsBatch(
                tokenSource: tokens.source, threadIds: ["t0", "t1"], format: .metadata, quotaKey: "threads-401"
            )
        }
        #expect(tokens.refreshes == 1)
    }

    // MARK: - Gate: re-send guard and cancellation

    @Test("refreshOnce refuses a re-send when Gmail rejected the token the refresh just produced")
    func gateRefusesResendOfFreshToken() async throws {
        let tokens = FakeTokens()
        let gate = GmailTokenRefreshGate(source: tokens.source)
        #expect(try await gate.refreshOnce(rejecting: "tok-test-stale"))
        #expect(try await !gate.refreshOnce(rejecting: "tok-test-fresh"), "the fresh token was refused too — re-sending it cannot help")
        #expect(tokens.refreshes == 1)
    }

    @Test("A chunk rejected with some OTHER token asks the source about it instead of re-sending blindly")
    func gateAsksSourceAboutAnotherRejectedToken() async throws {
        let asked = OSAllocatedUnfairLock(initialState: [String]())
        let source = GmailTokenSource { rejected in
            guard let rejected else { return "tok-test-a" }
            asked.withLock { $0.append(rejected) }
            return rejected == "tok-test-stale" ? "tok-test-a" : "tok-test-c"
        }
        let gate = GmailTokenRefreshGate(source: source)
        #expect(try await gate.refreshOnce(rejecting: "tok-test-stale"))
        // Another chunk was refused with a token the shared refresh never saw.
        #expect(try await gate.refreshOnce(rejecting: "tok-test-b"))
        #expect(asked.withLock { $0 } == ["tok-test-stale", "tok-test-b"], "the source decides about tok-test-b")
    }

    @Test("A cancelled waiter leaves a shared refresh immediately; the refresh itself runs on")
    func gateWaitersAbandonOnCancel() async throws {
        let latch = Latch()
        let finished = OSAllocatedUnfairLock(initialState: false)
        let source = GmailTokenSource { rejected in
            guard rejected != nil else { return "tok-test-stale" }
            await latch.wait()
            finished.withLock { $0 = true }
            return "tok-test-fresh"
        }
        let gate = GmailTokenRefreshGate(source: source)

        let starter = Task { try await gate.refreshOnce(rejecting: "tok-test-stale") }
        try await Task.sleep(nanoseconds: 50_000_000)
        let joiner = Task { try await gate.refreshOnce(rejecting: "tok-test-stale") }
        try await Task.sleep(nanoseconds: 50_000_000)
        // Safety valve so a regression FAILS instead of hanging the suite.
        let valve = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await latch.open()
        }
        defer { valve.cancel() }

        starter.cancel()
        joiner.cancel()
        let starterResult = await starter.result
        let joinerResult = await joiner.result

        #expect(throws: CancellationError.self) { try starterResult.get() }
        #expect(throws: CancellationError.self) { try joinerResult.get() }
        #expect(!finished.withLock { $0 }, "the waiters left while the refresh was still running")
        await latch.open()
    }

    /// One-shot gate: `wait()` suspends until `open()`.
    actor Latch {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }
}

}

// MARK: - Stub

/// Claims only requests carrying a `tok-test-*` bearer, so it cannot answer
/// another suite's stubbed traffic (those send `"token"`).
private struct UncheckedStubBox: @unchecked Sendable {
    let value: TokenStub
}

final class TokenStub: URLProtocol, @unchecked Sendable {

    struct Reply: Sendable {
        var status: Int
        var contentType: String?
        var body: Data
        /// Fail the request with this transport error instead of answering.
        var failWith: URLError.Code? = nil
    }

    private struct State {
        var handler: (@Sendable (URLRequest) -> Reply)?
        var bearers: [String] = []
        /// Stale-token replies are parked until this many have arrived.
        var holdStaleUntil = 0
        var heldStale: [@Sendable () -> Void] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func install(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        state.withLock { $0 = State(handler: handler) }
        URLProtocol.registerClass(TokenStub.self)
    }

    static func uninstall() {
        URLProtocol.unregisterClass(TokenStub.self)
        state.withLock { $0 = State() }
    }

    /// Park every `tok-test-stale` reply until `count` stale requests are in
    /// flight at once, then release them together (with a 2 s safety flush so
    /// a regression fails rather than hangs).
    static func holdStaleReplies(until count: Int) {
        state.withLock { $0.holdStaleUntil = count }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { flushHeld() }
    }

    private static func flushHeld() {
        let held = state.withLock { s -> [@Sendable () -> Void] in
            defer { s.heldStale = []; s.holdStaleUntil = 0 }
            return s.heldStale
        }
        held.forEach { $0() }
    }

    /// The bearer each request went out with, in arrival order.
    static var bearers: [String] { state.withLock { $0.bearers } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "gmail.googleapis.com"
            && (request.value(forHTTPHeaderField: "Authorization") ?? "").hasPrefix("Bearer tok-test-")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // The upload path strips `httpBody`; the stream is where the envelope
        // survives, and the reply is sized to it.
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            request.httpBody = data
        }
        let resolved = request

        let reply = Self.state.withLock { state -> Reply? in
            let bearer = String((resolved.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst("Bearer ".count))
            state.bearers.append(bearer)
            return state.handler?(resolved)
        }
        guard let reply, let url = resolved.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        if let code = reply.failWith {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        var headers: [String: String] = [:]
        if let contentType = reply.contentType { headers["Content-Type"] = contentType }
        let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        // Swift 6.4 no longer accepts capturing `self` (a URLProtocol subclass)
        // in a `@Sendable` closure even with `@unchecked Sendable`; the loading
        // system calls the client serially, so an unchecked box is accurate.
        let stub = UncheckedStubBox(value: self)
        let finish: @Sendable () -> Void = {
            let me = stub.value
            me.client?.urlProtocol(me, didReceive: response, cacheStoragePolicy: .notAllowed)
            me.client?.urlProtocol(me, didLoad: reply.body)
            me.client?.urlProtocolDidFinishLoading(me)
        }
        let isStale = (resolved.value(forHTTPHeaderField: "Authorization") ?? "") == "Bearer tok-test-stale"
        let release = Self.state.withLock { s -> Bool? in
            guard isStale, s.holdStaleUntil > 0 else { return nil }
            s.heldStale.append(finish)
            return s.heldStale.count >= s.holdStaleUntil
        }
        switch release {
        case nil: finish()
        case true?: Self.flushHeld()
        case false?: break
        }
    }

    override func stopLoading() {}
}
