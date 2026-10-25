import Foundation
import os
import Testing
@testable import SwiftGmail

/// `GmailRetryPolicy` end to end through the injected `Transport`, on a
/// virtual-clock bucket: attempt caps, the rate-limit switch, the deadline
/// (quota park and backoff), the task-local override, and cancellation.
@Suite("GmailRetryPolicy — attempt caps, deadlines, overrides")
struct GmailRetryPolicyTests {

    /// Clock the bucket's sleeper advances; nothing sleeps for real.
    private final class VirtualClock: Sendable {
        static let origin = Date(timeIntervalSince1970: 1_700_000_000)
        private let state = OSAllocatedUnfairLock(initialState: VirtualClock.origin)
        var now: Date { state.withLock { $0 } }
        var elapsed: TimeInterval { now.timeIntervalSince(Self.origin) }
        func advance(_ seconds: TimeInterval) { state.withLock { $0 += seconds } }
        func bucket() -> GmailQuotaBucket {
            GmailQuotaBucket(now: { [self] in now }, sleeper: { [self] in advance($0) })
        }
    }

    /// Answers every request with `status` (or, when set, `reply` for the
    /// n-th request, 0-based) and counts them. `onRequest` runs first.
    private final class CountingTransport: @unchecked Sendable {
        typealias Reply = (status: Int, headers: [String: String], body: String)
        private let lock = NSLock()
        private var count = 0
        let status: Int
        let reply: (@Sendable (Int, URLRequest) -> Reply)?
        let onRequest: @Sendable () -> Void
        init(
            status: Int = 200,
            reply: (@Sendable (Int, URLRequest) -> Reply)? = nil,
            onRequest: @escaping @Sendable () -> Void = {}
        ) {
            self.status = status
            self.reply = reply
            self.onRequest = onRequest
        }
        var attempts: Int { lock.withLock { count } }
        func respond(to request: URLRequest) -> (Data, URLResponse) {
            let index: Int = lock.withLock { defer { count += 1 }; return count }
            onRequest()
            let answer: Reply = reply?(index, request) ?? (status: status, headers: [:], body: status == 200 ? #"{"id":"m1","threadId":"t","snippet":"","internalDate":"0"}"# : "{}")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: answer.headers
            )!
            return (Data(answer.body.utf8), response)
        }
    }

    private static func client(
        _ transport: CountingTransport,
        clock: VirtualClock = VirtualClock(),
        policy: GmailRetryPolicy = .default
    ) -> GmailAPIClient {
        GmailAPIClient(quotaBucket: clock.bucket(), transport: { transport.respond(to: $0) }, retryPolicy: policy)
    }

    private static func getMessage(_ client: GmailAPIClient, key: String = "k") async throws {
        _ = try await client.getMessage(accessToken: "t", messageId: "m1", quotaKey: key)
    }

    // MARK: - Attempt caps

    @Test("The default policy keeps today's attempt counts: four for a read's 503, four for a send's 429")
    func defaultMatchesLegacyCounts() async throws {
        #expect(GmailRetryPolicy.default == GmailRetryPolicy(maxAttempts: 4, maxElapsed: nil, retryOnRateLimit: true))

        let read = CountingTransport(status: 503)
        await #expect(throws: GmailAPIError.httpError(statusCode: 503)) { try await Self.getMessage(Self.client(read)) }
        #expect(read.attempts == 4)

        let send = CountingTransport(status: 429)
        await #expect(throws: GmailAPIError.httpError(statusCode: 429)) {
            _ = try await Self.client(send).sendMessage(accessToken: "t", rawMessage: "raw")
        }
        #expect(send.attempts == 4)

        // The send's own stricter rule still wins over the policy: no 5xx retry.
        let sendServer = CountingTransport(status: 503)
        await #expect(throws: GmailAPIError.httpError(statusCode: 503)) {
            _ = try await Self.client(sendServer).sendMessage(accessToken: "t", rawMessage: "raw")
        }
        #expect(sendServer.attempts == 1)
    }

    @Test("maxAttempts 1 means no retry")
    func singleAttempt() async throws {
        let transport = CountingTransport(status: 503)
        await #expect(throws: GmailAPIError.httpError(statusCode: 503)) {
            try await Self.getMessage(Self.client(transport, policy: GmailRetryPolicy(maxAttempts: 1)))
        }
        #expect(transport.attempts == 1)
    }

    @Test("retryOnRateLimit false throws the first 429")
    func rateLimitNotRetried() async throws {
        let transport = CountingTransport(status: 429)
        await #expect(throws: GmailAPIError.httpError(statusCode: 429)) {
            try await Self.getMessage(Self.client(transport, policy: GmailRetryPolicy(retryOnRateLimit: false)))
        }
        #expect(transport.attempts == 1)
    }

    // MARK: - Deadline

    @Test("A 60 s quota park under failFast(within: 10) throws at once, waits nothing, debits nothing")
    func parkPastDeadlineRefused() async throws {
        let clock = VirtualClock()
        let bucket = clock.bucket()
        await bucket.noteRateLimited(key: "parked")
        let before = await bucket.buckets["parked"]
        let transport = CountingTransport(status: 200)
        let client = GmailAPIClient(
            quotaBucket: bucket, transport: { transport.respond(to: $0) }, retryPolicy: .failFast(within: 10)
        )

        do {
            try await Self.getMessage(client, key: "parked")
            Issue.record("expected a throw")
        } catch GmailAPIError.deadlineExceeded(let retryAfter) {
            #expect(retryAfter == 60, "the remaining park, so the host can reschedule")
        }
        #expect(clock.elapsed < 10)
        #expect(transport.attempts == 0)
        let after = await bucket.buckets["parked"]
        #expect(after?.nextFreeInteractive == before?.nextFreeInteractive, "no lane clock pushed")
        #expect(after?.nextFreeBulk == before?.nextFreeBulk, "no units debited")
    }

    @Test("A backoff that would pass the deadline is not slept; the last attempt's error is thrown")
    func backoffPastDeadlineThrowsUnderlying() async throws {
        let clock = VirtualClock()
        let transport = CountingTransport(status: 503)
        // Backoffs 1 s, 2 s, 4 s: the third would end at 7 s, past 5 s.
        let client = Self.client(transport, clock: clock, policy: GmailRetryPolicy(maxAttempts: 10, maxElapsed: 5))
        await #expect(throws: GmailAPIError.httpError(statusCode: 503)) { try await Self.getMessage(client) }
        #expect(transport.attempts == 3)
        #expect(clock.elapsed < 5)
    }

    @Test("Batch path: a parked account under failFast throws before any envelope is sent")
    func batchHonoursDeadline() async throws {
        let clock = VirtualClock()
        let bucket = clock.bucket()
        await bucket.noteRateLimited(key: "batch-parked")
        let before = await bucket.buckets["batch-parked"]
        let transport = CountingTransport(status: 200)
        let client = GmailAPIClient(
            quotaBucket: bucket, transport: { transport.respond(to: $0) }, retryPolicy: .failFast(within: 10)
        )

        await #expect(throws: GmailAPIError.deadlineExceeded(retryAfter: 60)) {
            _ = try await Self.batch(client, ids: ["m1", "m2"], key: "batch-parked")
        }
        #expect(transport.attempts == 0)
        #expect(clock.elapsed < 10)
        #expect(await bucket.buckets["batch-parked"]?.nextFreeBulk == before?.nextFreeBulk)
    }

    private static func batch(
        _ client: GmailAPIClient, ids: [String], key: String, retryDelay: TimeInterval = 0
    ) async throws -> BatchFetchOutcome<GmailMessage> {
        try await client.batchGet(
            accessToken: "t", resource: "messages", ids: ids, format: .metadata,
            unitCost: GmailQuotaProfile.current.messagesGetCost, quotaKey: key,
            retryDelay: retryDelay, as: GmailMessage.self
        )
    }

    /// A multipart batch reply: part `i` answers op `i` with `statuses[i]`.
    private static func multipart(_ statuses: [Int]) -> CountingTransport.Reply {
        let boundary = "b"
        var text = ""
        for (index, status) in statuses.enumerated() {
            let body = status == 200
                ? #"{"id":"m\#(index)","threadId":"t","snippet":"s","internalDate":"0"}"#
                : #"{"error":{"code":\#(status),"message":"x","errors":[{"reason":"rateLimitExceeded"}]}}"#
            text += "--\(boundary)\r\nContent-Type: application/http\r\n"
            text += "Content-ID: <response-\(GmailBatchProtocol.contentId(forIndex: index))>\r\n\r\n"
            text += "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\n\r\n\(body)\r\n"
        }
        text += "--\(boundary)--\r\n"
        return (status: 200, headers: ["Content-Type": "multipart/mixed; boundary=\(boundary)"], body: text)
    }

    @Test("Batch: a re-issue round refused by the deadline keeps what was fetched and hands the rest back as transient")
    func batchReissueRefused() async throws {
        let clock = VirtualClock()
        // Round 1: m0 ok, m1 rate-limited → the account parks 60 s, past the 10 s budget.
        let transport = CountingTransport(reply: { _, _ in Self.multipart([200, 429]) })
        let client = GmailAPIClient(
            quotaBucket: clock.bucket(), transport: { transport.respond(to: $0) }, retryPolicy: .failFast(within: 10)
        )
        let outcome = try await Self.batch(client, ids: ["m0", "m1"], key: "reissue")
        #expect(outcome.fetched.map(\.id) == ["m0"])
        #expect(outcome.leftover == ["m1"])
        #expect(outcome.transient == ["m1"])
        #expect(transport.attempts == 1)
        #expect(clock.elapsed < 10)
    }

    @Test("Batch: a part-retry backoff past the deadline is not slept; the ids come back as transient leftovers")
    func batchBackoffPastDeadline() async throws {
        let clock = VirtualClock()
        let transport = CountingTransport(reply: { _, _ in Self.multipart([200, 503]) })
        let client = GmailAPIClient(
            quotaBucket: clock.bucket(), transport: { transport.respond(to: $0) }, retryPolicy: .failFast(within: 10)
        )
        // A 20 s part-retry delay cannot fit in the 10 s budget.
        let outcome = try await Self.batch(client, ids: ["m0", "m1"], key: "backoff", retryDelay: 20)
        #expect(outcome.fetched.map(\.id) == ["m0"])
        #expect(outcome.leftover == ["m1"])
        #expect(outcome.transient == ["m1"])
        #expect(transport.attempts == 1)
        #expect(clock.elapsed < 10)
    }

    @Test("Bulk lane: the yield to interactive traffic stops at the deadline")
    func bulkYieldHonoursDeadline() async throws {
        let clock = VirtualClock()
        let bucket = clock.bucket()
        let deadline = clock.now.addingTimeInterval(0.5)
        try #require(bucket.policy.maxBulkYield > 0.5, "the yield cap must be longer than the deadline under test")
        // An interactive request that stays "in flight" for the whole test.
        _ = await bucket.reserve(units: 5, key: "yield", lane: .interactive)
        await bucket.beginInteractive(key: "yield")
        try await GmailRetryPolicy.$activeDeadline.withValue(deadline) {
            try await bucket.consume(units: 5, key: "yield", lane: .bulk)
        }
        #expect(clock.elapsed <= 0.5 + 0.001, "yielded at most until the deadline, not maxBulkYield")
    }

    @Test("An outer .with deadline shorter than the client's wins")
    func shorterOuterDeadlineWins() async throws {
        let clock = VirtualClock()
        let bucket = clock.bucket()
        await bucket.noteRateLimited(key: "nested", retryAfter: 30)
        let transport = CountingTransport(status: 200)
        // The client alone would wait out the 60 s park (budget 120 s).
        let client = GmailAPIClient(
            quotaBucket: bucket, transport: { transport.respond(to: $0) },
            retryPolicy: GmailRetryPolicy(maxElapsed: 120)
        )
        await #expect(throws: GmailAPIError.deadlineExceeded(retryAfter: 60)) {
            try await GmailRetryPolicy.with(.failFast(within: 10)) {
                try await Self.getMessage(client, key: "nested")
            }
        }
        #expect(transport.attempts == 0)
        // And unwrapped, the client's longer budget lets the call through.
        try await Self.getMessage(client, key: "nested")
        #expect(transport.attempts == 1)
        #expect(clock.elapsed >= 60)
    }

    @Test("A nested with(.default) replaces the outer budget: spawned work runs unbounded")
    func nestedDefaultClearsOuterDeadline() async throws {
        let clock = VirtualClock()
        let bucket = clock.bucket()
        await bucket.noteRateLimited(key: "child", retryAfter: 30)
        let transport = CountingTransport(status: 200)
        let client = GmailAPIClient(quotaBucket: bucket, transport: { transport.respond(to: $0) })
        try await GmailRetryPolicy.with(.failFast(until: clock.now.addingTimeInterval(5))) {
            try await GmailRetryPolicy.with(.default) {
                try await Self.getMessage(client, key: "child")
            }
        }
        #expect(transport.attempts == 1)
        #expect(clock.elapsed >= 60)
    }

    @Test("isRateLimit matches both rate-limit shapes and nothing else",
          arguments: [
            (GmailAPIError.rateLimitExceeded as any Error, true),
            (GmailAPIError.httpError(statusCode: 429), true),
            (GmailAPIError.httpError(statusCode: 429, detail: GmailErrorDetail(reason: "rateLimitExceeded")), true),
            (GmailAPIError.httpError(statusCode: 403), false),
            (GmailAPIError.httpError(statusCode: 403, detail: GmailErrorDetail(reason: "userRateLimitExceeded")), true),
            (GmailAPIError.httpError(statusCode: 403, detail: GmailErrorDetail(reason: "rateLimitExceeded")), true),
            (GmailAPIError.httpError(statusCode: 403, detail: GmailErrorDetail(reason: "quotaExceeded")), true),
            (GmailAPIError.httpError(statusCode: 403, detail: GmailErrorDetail(reason: "RESOURCE_EXHAUSTED")), true),
            (GmailAPIError.httpError(statusCode: 403, detail: GmailErrorDetail(reason: "dailyLimitExceeded")), false),
            (GmailAPIError.httpError(statusCode: 429, detail: GmailErrorDetail(reason: "dailyLimitExceeded")), false),
            (GmailAPIError.httpError(statusCode: 403, detail: GmailErrorDetail(reason: "ratelimitexceeded")), true),
            (GmailAPIError.httpError(statusCode: 403, detail: GmailErrorDetail(reason: "insufficientPermissions")), false),
            (GmailAPIError.httpError(statusCode: 503), false),
            (GmailAPIError.quotaExceeded, false),
            (GmailAPIError.deadlineExceeded(retryAfter: 10), false),
            (URLError(.timedOut), false),
          ])
    func isRateLimit(error: any Error, expected: Bool) {
        #expect(GmailAPIError.isRateLimit(error) == expected)
    }

    // MARK: - Shared deadline

    @Test("failFast(until:) shares one budget across calls; failFast(within:) restarts it per call")
    func sharedDeadlineAcrossCalls() async throws {
        // Two runs: the shared deadline refuses the second call's park, the
        // per-call budget lets it through.
        for shared in [true, false] {
            let clock = VirtualClock()
            let bucket = clock.bucket()
            await bucket.noteRateLimited(key: "second")   // parked until origin + 60
            clock.advance(35)
            let start = clock.now                        // the park has 25 s left
            // The first call takes 15 s on the wire; later ones are instant.
            let slow = CountingTransport(reply: { index, _ in
                if index == 0 { clock.advance(15) }
                return (status: 200, headers: [:], body: #"{"id":"m1","threadId":"t","snippet":"","internalDate":"0"}"#)
            })
            let client = GmailAPIClient(quotaBucket: bucket, transport: { slow.respond(to: $0) })
            let policy: GmailRetryPolicy = shared ? .failFast(until: start.addingTimeInterval(20)) : .failFast(within: 20)
            try await GmailRetryPolicy.with(policy) {
                try await Self.getMessage(client, key: "first")
                #expect(clock.now == start.addingTimeInterval(15))
                if shared {
                    // 5 s left of the pass, a 10 s park: refused.
                    await #expect(throws: GmailAPIError.deadlineExceeded(retryAfter: 10)) {
                        try await Self.getMessage(client, key: "second")
                    }
                } else {
                    try await Self.getMessage(client, key: "second")
                }
            }
            #expect(slow.attempts == (shared ? 1 : 2))
        }
    }

    @Test("Inside a bounded call, the earliest deadline wins, from deadline or from maxElapsed")
    func nestedEarliestDeadlineWins() async throws {
        let clock = VirtualClock()
        let bucket = clock.bucket()
        let client = GmailAPIClient(quotaBucket: bucket, transport: { CountingTransport().respond(to: $0) })
        let origin = clock.now
        func observed() async throws -> Date? {
            try await client.withDeadlineScope(client.effectiveRetryPolicy) { $0 }
        }
        // Outer absolute deadline sooner than the inner maxElapsed.
        try await GmailRetryPolicy.with(.failFast(until: origin.addingTimeInterval(5))) {
            try await client.withDeadlineScope(client.effectiveRetryPolicy) { _ in
                try await GmailRetryPolicy.with(.failFast(within: 30)) {
                    let observedDeadline = try await observed()
                    #expect(observedDeadline == origin.addingTimeInterval(5))
                }
            }
        }
        // Outer maxElapsed sooner than the inner absolute deadline.
        try await GmailRetryPolicy.with(.failFast(within: 5)) {
            try await client.withDeadlineScope(client.effectiveRetryPolicy) { _ in
                try await GmailRetryPolicy.with(.failFast(until: origin.addingTimeInterval(30))) {
                    let observedDeadline = try await observed()
                    #expect(observedDeadline == origin.addingTimeInterval(5))
                }
            }
        }
        // Inner absolute deadline sooner than the outer maxElapsed.
        try await GmailRetryPolicy.with(.failFast(within: 30)) {
            try await client.withDeadlineScope(client.effectiveRetryPolicy) { _ in
                try await GmailRetryPolicy.with(.failFast(until: origin.addingTimeInterval(5))) {
                    let observedDeadline = try await observed()
                    #expect(observedDeadline == origin.addingTimeInterval(5))
                }
            }
        }
        // One policy with both: the earlier of the two.
        let both = GmailRetryPolicy(maxElapsed: 8, deadline: origin.addingTimeInterval(3))
        try await GmailRetryPolicy.with(both) {
            let observedDeadline = try await observed()
            #expect(observedDeadline == origin.addingTimeInterval(3))
        }
        let both2 = GmailRetryPolicy(maxElapsed: 2, deadline: origin.addingTimeInterval(3))
        try await GmailRetryPolicy.with(both2) {
            let observedDeadline = try await observed()
            #expect(observedDeadline == origin.addingTimeInterval(2))
        }
    }

    @Test("deadline defaults to nil and takes part in equality")
    func deadlineDefaultAndEquality() {
        let date = VirtualClock.origin
        #expect(GmailRetryPolicy.default.deadline == nil)
        #expect(GmailRetryPolicy.failFast(until: date) == GmailRetryPolicy(retryOnRateLimit: false, deadline: date))
        #expect(GmailRetryPolicy.failFast(until: date) != GmailRetryPolicy.failFast(until: date.addingTimeInterval(1)))
        #expect(GmailRetryPolicy.failFast(until: date).maxElapsed == nil)
    }

    // MARK: - Task-local override

    @Test("GmailRetryPolicy.with beats the client's policy, and nesting restores the outer one")
    func taskLocalOverride() async throws {
        let client = Self.client(CountingTransport(status: 200), policy: GmailRetryPolicy(maxAttempts: 7))
        #expect(client.effectiveRetryPolicy.maxAttempts == 7)

        let attempts = CountingTransport(status: 503)
        let overridden = Self.client(attempts, policy: GmailRetryPolicy(maxAttempts: 7))
        await GmailRetryPolicy.with(GmailRetryPolicy(maxAttempts: 2)) {
            #expect(client.effectiveRetryPolicy.maxAttempts == 2)
            await #expect(throws: GmailAPIError.self) { try await Self.getMessage(overridden) }
            await GmailRetryPolicy.with(.failFast(within: 3)) {
                #expect(client.effectiveRetryPolicy == .failFast(within: 3))
            }
            #expect(client.effectiveRetryPolicy.maxAttempts == 2, "the outer override is back")
        }
        #expect(attempts.attempts == 2)
        #expect(client.effectiveRetryPolicy.maxAttempts == 7, "unset again: the client's own")
    }

    @Test("current is nil outside any with, set inside, and restored after nesting")
    func currentReflectsOverride() async {
        #expect(GmailRetryPolicy.current == nil)
        let client = Self.client(CountingTransport(), policy: GmailRetryPolicy(maxAttempts: 7))
        let outer = GmailRetryPolicy(maxAttempts: 2)
        let inner = GmailRetryPolicy.failFast(until: VirtualClock.origin)
        await GmailRetryPolicy.with(outer) {
            #expect(GmailRetryPolicy.current == outer)
            #expect(client.effectiveRetryPolicy == outer)
            await GmailRetryPolicy.with(inner) {
                #expect(GmailRetryPolicy.current == inner)
                #expect(client.effectiveRetryPolicy == inner)
            }
            #expect(GmailRetryPolicy.current == outer)
        }
        #expect(GmailRetryPolicy.current == nil)
        #expect(client.effectiveRetryPolicy == GmailRetryPolicy(maxAttempts: 7))
    }

    // MARK: - Cancellation

    @Test("A task cancelled during an attempt does not start the next one")
    func cancellationStopsRetries() async throws {
        let holder = OSAllocatedUnfairLock<Task<Void, any Error>?>(initialState: nil)
        let started = AsyncStream<Void>.makeStream()
        // The first request cancels the call's own (child) task, never the test's.
        let transport = CountingTransport(status: 503, onRequest: {
            holder.withLock { $0?.cancel() }
        })
        let client = Self.client(transport)
        let task = Task {
            for await _ in started.stream { break }
            try await Self.getMessage(client)
        }
        holder.withLock { $0 = task }
        started.continuation.yield()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(transport.attempts == 1)
    }
}

/// `GmailAPIError.isAmbiguousDelivery` — might a send have gone out?
@Suite("GmailAPIError.isAmbiguousDelivery")
struct GmailAmbiguousDeliveryTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let error: any Error & Sendable
        let ambiguous: Bool
        var testDescription: String { name }
    }

    private struct UnknownError: Error {}

    static let cases: [Case] = [
        Case(name: "HTTP 500", error: GmailAPIError.httpError(statusCode: 500), ambiguous: true),
        Case(name: "HTTP 503", error: GmailAPIError.httpError(statusCode: 503), ambiguous: true),
        Case(name: "URLError.timedOut", error: URLError(.timedOut), ambiguous: true),
        Case(name: "URLError.networkConnectionLost", error: URLError(.networkConnectionLost), ambiguous: true),
        Case(name: "URLError.cannotParseResponse", error: URLError(.cannotParseResponse), ambiguous: true),
        Case(name: "URLError.badServerResponse", error: URLError(.badServerResponse), ambiguous: true),
        Case(name: "URLError.cancelled", error: URLError(.cancelled), ambiguous: true),
        Case(name: "CancellationError", error: CancellationError(), ambiguous: true),
        Case(name: "unknown error", error: UnknownError(), ambiguous: true),
        Case(name: "invalidResponse", error: GmailAPIError.invalidResponse, ambiguous: true),
        Case(name: "parsingError", error: GmailAPIError.parsingError, ambiguous: true),
        Case(name: "HTTP 400", error: GmailAPIError.httpError(statusCode: 400), ambiguous: false),
        Case(name: "HTTP 401", error: GmailAPIError.httpError(statusCode: 401), ambiguous: false),
        Case(name: "HTTP 403", error: GmailAPIError.httpError(statusCode: 403), ambiguous: false),
        Case(name: "HTTP 429", error: GmailAPIError.httpError(statusCode: 429), ambiguous: false),
        Case(name: "rateLimitExceeded", error: GmailAPIError.rateLimitExceeded, ambiguous: false),
        Case(name: "quotaExceeded", error: GmailAPIError.quotaExceeded, ambiguous: false),
        Case(name: "deadlineExceeded", error: GmailAPIError.deadlineExceeded(retryAfter: 30), ambiguous: false),
        Case(name: "deadlineExceeded, no hint", error: GmailAPIError.deadlineExceeded(retryAfter: nil), ambiguous: false),
        Case(name: "invalidURL", error: GmailAPIError.invalidURL, ambiguous: false),
        Case(name: "historyIdExpired", error: GmailAPIError.historyIdExpired, ambiguous: false),
        Case(name: "authenticationFailed", error: GmailAPIError.authenticationFailed("x"), ambiguous: false),
        Case(name: "URLError.notConnectedToInternet", error: URLError(.notConnectedToInternet), ambiguous: false),
        Case(name: "URLError.cannotConnectToHost", error: URLError(.cannotConnectToHost), ambiguous: false),
        Case(name: "URLError.cannotFindHost", error: URLError(.cannotFindHost), ambiguous: false),
        Case(name: "URLError.dnsLookupFailed", error: URLError(.dnsLookupFailed), ambiguous: false),
        Case(name: "URLError.secureConnectionFailed", error: URLError(.secureConnectionFailed), ambiguous: false),
    ]

    @Test("Classifies each error", arguments: cases)
    func classifies(_ testCase: Case) {
        #expect(GmailAPIError.isAmbiguousDelivery(testCase.error) == testCase.ambiguous)
    }
}
