import Foundation
import os
import Testing
@testable import SwiftGmail

/// Gmail's 403 is two different failures wearing one status code, and the
/// batch layer used to answer both the same way — `default:` → dropped.
///
/// The incident (t-172bfc74): 159,080 per-part "HTTP 403 … skipping" lines in
/// nine hours, 8,542 batches reporting every sub-response unusable, and a
/// full-sync window recorded COMPLETE with ~44% of the year's mail missing.
/// Gmail reports per-user rate limiting as 403 with `reason:
/// userRateLimitExceeded`; a real refusal is 403 with
/// `insufficientPermissions`. The reason string in the body is the only signal.
///
/// What is asserted here: a rate 403 is retried and never dropped, a refusal
/// 403 is dropped with its reason, the account's bucket halves and recovers,
/// and an envelope-level rate 403 is transient rather than fatal. Time is
/// virtual throughout — a 60 s cooldown is asserted, not waited out.
/// Nested inside `GmailAPIClientBatchTests` on purpose. Both suites stub
/// `gmail.googleapis.com` by registering a `URLProtocol` class GLOBALLY, so
/// they must never run at the same time — and Swift Testing's `.serialized`
/// only orders a suite's own subtree. Being a descendant of that suite is what
/// makes the two sets of stubs mutually exclusive.
extension GmailAPIClientBatchTests {

@Suite("Gmail 403 rate-limit classification and the adaptive quota bucket", .serialized)
struct GmailBatch403RateLimitTests {

        // MARK: - Virtual clock

        /// A clock the test moves by hand, plus the sleeper that moves it. The
        /// bucket's cooldown is 60 s; nothing here sleeps for real.
        final class VirtualClock: Sendable {
            private let state = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_700_000_000))

            var now: Date { state.withLock { $0 } }
            func advance(_ seconds: TimeInterval) { state.withLock { $0 += seconds } }

            /// Seconds elapsed since the clock started — what the fake server
            /// branches on.
            var elapsed: TimeInterval { now.timeIntervalSince(Date(timeIntervalSince1970: 1_700_000_000)) }

            func bucket() -> GmailQuotaBucket {
                GmailQuotaBucket(
                    now: { [self] in now },
                    sleeper: { [self] seconds in advance(seconds) }
                )
            }
        }

        // MARK: - Fixtures

        private static let boundary = "rate_boundary"

        private static func messageJSON(_ id: String) -> String {
            #"{"id":"\#(id)","threadId":"t-\#(id)","snippet":"s","internalDate":"1700000000000"}"#
        }

        /// Gmail's error envelope, verbatim in shape.
        static func errorJSON(code: Int, reason: String, status: String) -> String {
            #"{"error":{"code":\#(code),"message":"m","errors":[{"domain":"usageLimits","reason":"\#(reason)","message":"m"}],"status":"\#(status)"}}"#
        }

        private struct Part {
            var contentId: String?
            var status: Int
            var body: String
        }

        private static func envelope(_ parts: [Part]) -> Data {
            var text = ""
            for part in parts {
                text += "--\(boundary)\r\n"
                text += "Content-Type: application/http\r\n"
                if let contentId = part.contentId {
                    text += "Content-ID: <response-\(contentId)>\r\n"
                }
                text += "\r\n"
                text += "HTTP/1.1 \(part.status) OK\r\n"
                text += "Content-Type: application/json\r\n"
                text += "\r\n"
                text += part.body
                text += "\r\n"
            }
            text += "--\(boundary)--\r\n"
            return Data(text.utf8)
        }

        private static func multipartReply(_ parts: [Part]) -> BatchStub.Reply {
            BatchStub.Reply(
                status: 200,
                contentType: "multipart/mixed; boundary=\(boundary)",
                body: envelope(parts)
            )
        }

        /// One 403-for-everything / 200-for-everything envelope, sized to the
        /// number of sub-requests the client actually sent.
        private static func reply(status: Int, body: @escaping (Int) -> String, operations: Int) -> BatchStub.Reply {
            multipartReply((0..<operations).map { index in
                Part(contentId: "op-\(index)", status: status, body: body(index))
            })
        }

        /// How many sub-requests an outgoing envelope carried — the re-issue round
        /// carries only the failures, so the reply has to match it.
        private static func operationCount(in request: URLRequest) -> Int {
            guard let body = request.httpBody, let text = String(data: body, encoding: .utf8) else { return 0 }
            return text.components(separatedBy: "Content-ID: <").count - 1
        }

        private static func outcome(
            ids: [String],
            quotaKey: String,
            client: GmailAPIClient
        ) async throws -> BatchFetchOutcome<GmailMessage> {
            try await client.batchGet(
                accessToken: "token",
                resource: "messages",
                ids: ids,
                format: .metadata,
                unitCost: GmailQuotaProfile.current.messagesGetCost,
                quotaKey: quotaKey,
                retryDelay: 0,
                as: GmailMessage.self
            )
        }

        // MARK: - (a) Rate 403 → retried, never dropped

        @Test("Every part 403 userRateLimitExceeded until the cooldown passes → zero drops, and the bucket halves")
        func rateLimited403IsRetriedNotDropped() async throws {
            let clock = VirtualClock()
            let bucket = clock.bucket()
            let client = GmailAPIClient(quotaBucket: bucket)

            BatchStub.install { request in
                let operations = Self.operationCount(in: request)
                // The quota window forgives at t+60s — which is exactly the
                // bucket's cooldown, so the re-issue must be paced by the bucket.
                if clock.elapsed < 60 {
                    return Self.reply(
                        status: 403,
                        body: { _ in Self.errorJSON(code: 403, reason: "userRateLimitExceeded", status: "PERMISSION_DENIED") },
                        operations: operations
                    )
                }
                return Self.reply(status: 200, body: { Self.messageJSON("m\($0)") }, operations: operations)
            }
            defer { BatchStub.uninstall() }

            let outcome = try await Self.outcome(ids: ["m0", "m1", "m2"], quotaKey: "rate-403", client: client)

            #expect(outcome.fetched.count == 3, "a rate 403 must never cost a message — it is retryable by definition")
            #expect(outcome.leftover.isEmpty)
            #expect(outcome.isComplete)
            #expect(BatchStub.requestCount == 2, "one refused envelope + one re-issue paced by the bucket")
            #expect(clock.elapsed >= 60, "the re-issue waited out the quota window through the bucket, not a fixed 5s")

            // Halved on the signal, then one additive step back up — the clean
            // minute the re-issue waited out IS a recovery interval, so the
            // full AIMD cycle is visible in a single fetch.
            let ceiling = GmailQuotaProfile.current.unitsPerSecond
            let step = GmailQuotaBucket.recoveryFraction * ceiling
            #expect(await bucket.rate(for: "rate-403") == ceiling / 2 + step, "multiplicative decrease, then one clean-minute recovery step")
        }

        @Test("Ids still refused when the retry round is spent come back as LEFTOVERS, not drops")
        func unforgivenRate403BecomesLeftover() async throws {
            let clock = VirtualClock()
            let client = GmailAPIClient(quotaBucket: clock.bucket())

            BatchStub.install { request in
                Self.reply(
                    status: 403,
                    body: { _ in Self.errorJSON(code: 403, reason: "rateLimitExceeded", status: "PERMISSION_DENIED") },
                    operations: Self.operationCount(in: request)
                )
            }
            defer { BatchStub.uninstall() }

            let outcome = try await Self.outcome(ids: ["m0", "m1"], quotaKey: "rate-403-stuck", client: client)

            #expect(outcome.fetched.isEmpty)
            #expect(outcome.leftover == ["m0", "m1"], "the drain — and the pending history window — depend on this set")
        }

        @Test("RESOURCE_EXHAUSTED with no usageLimits reason is still a rate signal")
        func resourceExhaustedStatusIsRateSignal() async throws {
            let classification = GmailErrorClassification.classify(
                body: Data(#"{"error":{"code":403,"status":"RESOURCE_EXHAUSTED"}}"#.utf8)
            )
            #expect(classification.isRateLimit)
            #expect(classification.reason == "RESOURCE_EXHAUSTED")
        }

        @Test("All four quota reasons classify as rate signals", arguments: [
            "userRateLimitExceeded", "rateLimitExceeded", "quotaExceeded", "dailyLimitExceeded"
        ])
        func everyQuotaReasonIsARateSignal(reason: String) {
            let classification = GmailErrorClassification.classify(
                body: Data(Self.errorJSON(code: 403, reason: reason, status: "PERMISSION_DENIED").utf8)
            )
            #expect(classification.isRateLimit, "\(reason) is Gmail telling us to slow down")
            #expect(classification.reason == reason)
        }

        // MARK: - (b) Refusal 403 → dropped with the reason

        @Test("403 insufficientPermissions / forbidden is DROPPED, never a leftover that can't drain", arguments: [
            "forbidden", "insufficientPermissions"
        ])
        func permissionRefusal403IsDropped(reason: String) async throws {
            let clock = VirtualClock()
            let client = GmailAPIClient(quotaBucket: clock.bucket())

            BatchStub.install { request in
                let operations = Self.operationCount(in: request)
                return Self.multipartReply((0..<operations).map { index in
                    index == 0
                        ? Part(contentId: "op-0", status: 403, body: Self.errorJSON(code: 403, reason: reason, status: "PERMISSION_DENIED"))
                        : Part(contentId: "op-\(index)", status: 200, body: Self.messageJSON("m\(index)"))
                })
            }
            defer { BatchStub.uninstall() }

            let outcome = try await Self.outcome(ids: ["m0", "m1"], quotaKey: "refused-403", client: client)

            #expect(outcome.fetched.map(\.id) == ["m1"])
            #expect(outcome.leftover.isEmpty, "a permission refusal can never drain — parking it would pin the window forever")
            #expect(BatchStub.requestCount == 1, "and it must not be retried")
        }

        @Test("An unparseable 403 body stays a drop — an unclassifiable failure must not loop")
        func garbled403IsNotARateSignal() async throws {
            let clock = VirtualClock()
            let client = GmailAPIClient(quotaBucket: clock.bucket())

            BatchStub.install { request in
                Self.reply(status: 403, body: { _ in "<html>nope</html>" }, operations: Self.operationCount(in: request))
            }
            defer { BatchStub.uninstall() }

            let outcome = try await Self.outcome(ids: ["m0"], quotaKey: "garbled-403", client: client)
            #expect(outcome.fetched.isEmpty)
            #expect(outcome.leftover.isEmpty)
            #expect(BatchStub.requestCount == 1)
        }

        // MARK: - (c) Envelope-level 403

        @Test("An ENVELOPE 403 with a rate reason is transient — withRetry re-sends it")
        func envelopeRate403IsRetried() async throws {
            let clock = VirtualClock()
            let bucket = clock.bucket()
            let client = GmailAPIClient(quotaBucket: bucket)

            let attempt = OSAllocatedUnfairLock(initialState: 0)
            BatchStub.install { request in
                let index = attempt.withLock { value -> Int in
                    value += 1
                    return value
                }
                if index == 1 {
                    return BatchStub.Reply(
                        status: 403,
                        contentType: "application/json",
                        body: Data(Self.errorJSON(code: 403, reason: "userRateLimitExceeded", status: "PERMISSION_DENIED").utf8)
                    )
                }
                return Self.reply(status: 200, body: { Self.messageJSON("m\($0)") }, operations: Self.operationCount(in: request))
            }
            defer { BatchStub.uninstall() }

            let outcome = try await Self.outcome(ids: ["m0"], quotaKey: "envelope-403", client: client)

            #expect(outcome.fetched.count == 1, "an envelope 403 that means 'slow down' must not fail the pass")
            #expect(BatchStub.requestCount == 2)
            let ceiling = GmailQuotaProfile.current.unitsPerSecond
            let step = GmailQuotaBucket.recoveryFraction * ceiling
            #expect(await bucket.rate(for: "envelope-403") == ceiling / 2 + step, "the envelope signal throttles the account too, then recovers a step")
        }

        @Test("An ENVELOPE 403 that is a real refusal escapes on the first attempt")
        func envelopeRefusal403IsFatal() async throws {
            let clock = VirtualClock()
            let client = GmailAPIClient(quotaBucket: clock.bucket())

            BatchStub.install { _ in
                BatchStub.Reply(
                    status: 403,
                    contentType: "application/json",
                    body: Data(Self.errorJSON(code: 403, reason: "insufficientPermissions", status: "PERMISSION_DENIED").utf8)
                )
            }
            defer { BatchStub.uninstall() }

            await #expect(throws: GmailAPIError.self) {
                _ = try await Self.outcome(ids: ["m0"], quotaKey: "envelope-refused", client: client)
            }
            #expect(BatchStub.requestCount == 1, "non-transient — no retry storm against a mailbox we may not read")
        }

        // MARK: - AIMD

        @Test("The bucket halves on a rate signal, floors at 10 u/s, and recovers +10% of the ceiling per clean minute")
        func bucketHalvesAndRecovers() async throws {
            let clock = VirtualClock()
            let bucket = clock.bucket()
            let ceiling = GmailQuotaProfile.current.unitsPerSecond
            let key = "aimd"

            #expect(await bucket.rate(for: key) == ceiling, "an unsignalled account runs at the profile ceiling")

            await bucket.noteRateLimited(key: key)
            #expect(await bucket.rate(for: key) == ceiling / 2)

            // A second signal DURING the cooldown is the tail of a batch that was
            // already in flight — it must not halve again.
            await bucket.noteRateLimited(key: key)
            #expect(await bucket.rate(for: key) == ceiling / 2, "signals inside the cooldown carry no new information")

            // Multiplicative decrease all the way down to the floor, one
            // signal per cooldown window.
            for _ in 0..<10 {
                clock.advance(GmailQuotaBucket.cooldown + 1)
                await bucket.noteRateLimited(key: key)
            }
            #expect(await bucket.rate(for: key) == GmailQuotaBucket.minimumUnitsPerSecond, "a floor, not zero — a slow sync beats a stalled one")

            // Additive increase: one step per clean minute, and no step before it.
            clock.advance(30)
            await bucket.noteSuccess(key: key)
            #expect(await bucket.rate(for: key) == GmailQuotaBucket.minimumUnitsPerSecond, "recovery is time-based, not call-based")

            // The last signal fired AT the floor, so the ceiling hint pins the
            // recovery target at the floor: a server that limits us even at
            // 10 u/s gets no probing for a full hint-relax interval.
            clock.advance(31)
            await bucket.noteSuccess(key: key)
            let step = GmailQuotaBucket.recoveryFraction * ceiling
            #expect(await bucket.rate(for: key) == GmailQuotaBucket.minimumUnitsPerSecond, "recovery cannot climb past the hint left by the last signal")

            // One hint-relax interval later the target moves up one step, and
            // the accumulated clean minutes take the rate straight to it.
            clock.advance(GmailQuotaBucket.hintRelaxInterval)
            await bucket.noteSuccess(key: key)
            #expect(await bucket.rate(for: key) == GmailQuotaBucket.minimumUnitsPerSecond + step)

            // And after a long clean stretch the hint relaxes away and the
            // rate is back at the profile ceiling, never past it.
            clock.advance(7200)
            await bucket.noteSuccess(key: key)
            #expect(await bucket.rate(for: key) == ceiling)
        }

        @Test("Recovery settles just under the rate that drew the last signal, then re-probes slowly")
        func recoverySettlesUnderTheHint() async throws {
            let clock = VirtualClock()
            let bucket = clock.bucket()
            let ceiling = GmailQuotaProfile.current.unitsPerSecond
            let key = "hint"

            // Signal at the ceiling: hint = 90% of it, rate halves.
            await bucket.noteRateLimited(key: key)
            #expect(await bucket.rate(for: key) == ceiling / 2)

            // Five clean minutes: +10% of ceiling per minute would reach the
            // ceiling, but recovery stops at the hint.
            clock.advance(5 * 60 + 1)
            await bucket.noteSuccess(key: key)
            #expect(await bucket.rate(for: key) == ceiling * GmailQuotaBucket.limitHintFraction)

            // After a clean hint-relax interval the target moves up one step.
            clock.advance(GmailQuotaBucket.hintRelaxInterval)
            await bucket.noteSuccess(key: key)
            #expect(await bucket.rate(for: key) == ceiling, "one relax step from 45 reaches the 50 ceiling and clears the hint")
        }

        @Test("A rate signal PARKS the account for the cooldown — the next reservation waits out the quota window")
        func rateSignalParksTheAccount() async throws {
            let clock = VirtualClock()
            let bucket = clock.bucket()

            await bucket.noteRateLimited(key: "parked")
            let wait = await bucket.reserve(units: 20, key: "parked")
            #expect(wait >= GmailQuotaBucket.cooldown, "Gmail's per-user quota is metered per MINUTE — a shorter pause re-enters the same window")

            // Another account is untouched: the ceiling is per user.
            #expect(await bucket.reserve(units: 20, key: "other") == 0)
        }

        @Test("A longer Retry-After wins over the default cooldown")
        func retryAfterOverridesCooldown() async throws {
            let clock = VirtualClock()
            let bucket = clock.bucket()

            await bucket.noteRateLimited(key: "retry-after", retryAfter: 120)
            #expect(await bucket.reserve(units: 20, key: "retry-after") >= 120)
        }
}

}

// MARK: - Stub

/// `/batch/gmail/v1` stub, shared by the tests above. Separate from
/// `GmailAPIClientBatchTests.BatchStubURLProtocol` only because both suites
/// register a protocol class globally and each needs its own handler slot.
final class BatchStub: URLProtocol, @unchecked Sendable {

    struct Reply: Sendable {
        var status: Int
        var contentType: String?
        var body: Data
    }

    private struct State {
        var handler: (@Sendable (URLRequest) -> Reply)?
        var requests: Int = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func install(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        state.withLock { $0 = State(handler: handler) }
        URLProtocol.registerClass(BatchStub.self)
    }

    static func uninstall() {
        URLProtocol.unregisterClass(BatchStub.self)
        state.withLock { $0 = State() }
    }

    static var requestCount: Int { state.withLock { $0.requests } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "gmail.googleapis.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // `URLRequest.httpBody` is stripped by URLSession's upload path, so the
        // stream is the only place the outgoing envelope survives — and the
        // reply has to be sized to it.
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
            state.requests += 1
            return state.handler?(resolved)
        }
        guard let reply, let url = resolved.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        var headers: [String: String] = [:]
        if let contentType = reply.contentType { headers["Content-Type"] = contentType }
        let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
