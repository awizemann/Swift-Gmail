import Foundation
import os
import Testing
@testable import SwiftGmail

/// `GmailAPIClient.batchGet` against a stubbed `/batch/gmail/v1` endpoint.
///
/// The wire FORMAT is covered by `GmailBatchProtocolTests`; what is asserted
/// here is the client's behaviour around it, which is where the sync-breaking
/// bugs live: how a sub-response is matched to the id that asked for it, how
/// many times a failing sub-request is re-issued, and what happens when the
/// endpoint refuses the envelope entirely.
///
/// `URLProtocol.registerClass` is the seam — `GmailAPIClient` talks to
/// `URLSession.shared`, which consults globally registered protocols.
@Suite("GmailAPIClient — batch part matching, retry cap, fallback", .serialized)
struct GmailAPIClientBatchTests {

    // MARK: - Stub

    final class BatchStubURLProtocol: URLProtocol, @unchecked Sendable {

        struct Reply: Sendable {
            var status: Int
            var contentType: String?
            var body: Data
        }

        private struct State {
            var handler: (@Sendable (URLRequest) -> Reply)?
            var requestedURLs: [String] = []
        }

        private static let state = OSAllocatedUnfairLock(initialState: State())

        static func install(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
            state.withLock { $0 = State(handler: handler) }
            URLProtocol.registerClass(BatchStubURLProtocol.self)
        }

        static func uninstall() {
            URLProtocol.unregisterClass(BatchStubURLProtocol.self)
            state.withLock { $0 = State() }
        }

        static var requestedURLs: [String] { state.withLock { $0.requestedURLs } }

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "gmail.googleapis.com"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let request = self.request
            let reply = Self.state.withLock { state -> Reply? in
                state.requestedURLs.append(request.url?.absoluteString ?? "")
                return state.handler?(request)
            }
            guard let reply, let url = request.url else {
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

    // MARK: - Fixtures

    private static let boundary = "test_boundary"

    private static func messageJSON(_ id: String) -> String {
        #"{"id":"\#(id)","threadId":"t-\#(id)","snippet":"s","internalDate":"1700000000000"}"#
    }

    /// One multipart part. `contentId` nil = the header the positional
    /// fallback has to cover.
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

    private static func multipartReply(_ parts: [Part]) -> BatchStubURLProtocol.Reply {
        BatchStubURLProtocol.Reply(
            status: 200,
            contentType: "multipart/mixed; boundary=\(boundary)",
            body: envelope(parts)
        )
    }

    /// A client whose quota bucket never actually waits. The bucket's pacing
    /// (and the 60 s cooldown a 429 installs) is asserted in
    /// `GmailBatch403RateLimitTests` against a virtual clock; here it would
    /// only add a real minute per test.
    private static func unpacedClient() -> GmailAPIClient {
        GmailAPIClient(quotaBucket: GmailQuotaBucket(sleeper: { _ in }))
    }

    private static func fetch(
        ids: [String],
        quotaKey: String,
        client: GmailAPIClient = GmailAPIClientBatchTests.unpacedClient()
    ) async throws -> [GmailMessage] {
        try await outcome(ids: ids, quotaKey: quotaKey, client: client).fetched
    }

    /// The same call, keeping the half these tests usually discard: the ids
    /// that never came back.
    private static func outcome(
        ids: [String],
        quotaKey: String,
        client: GmailAPIClient = GmailAPIClientBatchTests.unpacedClient()
    ) async throws -> BatchFetchOutcome<GmailMessage> {
        try await client.batchGet(
            accessToken: "token",
            resource: "messages",
            ids: ids,
            format: .metadata,
            unitCost: GmailQuotaProfile.current.messagesGetCost,
            quotaKey: quotaKey,
            retryDelay: 0,             // the real 5s backoff is not under test
            as: GmailMessage.self
        )
    }

    // MARK: - Part matching

    @Test("A response that labels only SOME parts still resolves every id — the unlabelled ones match by position")
    func mixedContentIdsResolvePositionally() async throws {
        BatchStubURLProtocol.install { _ in
            Self.multipartReply([
                Part(contentId: "op-0", status: 200, body: Self.messageJSON("m0")),
                Part(contentId: nil, status: 200, body: Self.messageJSON("m1")),
                Part(contentId: "op-2", status: 200, body: Self.messageJSON("m2"))
            ])
        }
        defer { BatchStubURLProtocol.uninstall() }

        let messages = try await Self.fetch(ids: ["m0", "m1", "m2"], quotaKey: "mixed")

        // The all-or-nothing fallback this replaced dropped m1 outright.
        #expect(messages.map(\.id) == ["m0", "m1", "m2"])
        #expect(BatchStubURLProtocol.requestedURLs.count == 1)
    }

    @Test("An explicitly labelled part is never taken for another index")
    func labelledPartsWinOverPosition() async throws {
        BatchStubURLProtocol.install { _ in
            // Server returned the parts out of order but labelled them.
            Self.multipartReply([
                Part(contentId: "op-1", status: 200, body: Self.messageJSON("m1")),
                Part(contentId: "op-0", status: 200, body: Self.messageJSON("m0"))
            ])
        }
        defer { BatchStubURLProtocol.uninstall() }

        let messages = try await Self.fetch(ids: ["m0", "m1"], quotaKey: "ordered")
        #expect(Set(messages.map(\.id)) == ["m0", "m1"])
    }

    // MARK: - Retry rounds

    @Test("A 429 sub-response is re-issued exactly once, and succeeds on that round")
    func perPartRetrySucceedsOnTheSecondRound() async throws {
        let round = OSAllocatedUnfairLock(initialState: 0)
        BatchStubURLProtocol.install { _ in
            let index = round.withLock { value -> Int in
                value += 1
                return value
            }
            if index == 1 {
                return Self.multipartReply([
                    Part(contentId: "op-0", status: 200, body: Self.messageJSON("m0")),
                    Part(contentId: "op-1", status: 429, body: "{}")
                ])
            }
            // The re-issue carries just the failed id, so it is op-0 again.
            return Self.multipartReply([
                Part(contentId: "op-0", status: 200, body: Self.messageJSON("m1"))
            ])
        }
        defer { BatchStubURLProtocol.uninstall() }

        let messages = try await Self.fetch(ids: ["m0", "m1"], quotaKey: "retry-ok")
        #expect(Set(messages.map(\.id)) == ["m0", "m1"])
        #expect(BatchStubURLProtocol.requestedURLs.count == 2)
    }

    @Test("A sub-request that keeps failing is left for the next pass after ONE retry round")
    func perPartRetryIsCappedAtOneRound() async throws {
        let round = OSAllocatedUnfairLock(initialState: 0)
        BatchStubURLProtocol.install { _ in
            let index = round.withLock { value -> Int in
                value += 1
                return value
            }
            if index == 1 {
                return Self.multipartReply([
                    Part(contentId: "op-0", status: 200, body: Self.messageJSON("m0")),
                    Part(contentId: "op-1", status: 503, body: "{}")
                ])
            }
            // The re-issue carries only the still-failing id, and it fails again.
            return Self.multipartReply([Part(contentId: "op-0", status: 503, body: "{}")])
        }
        defer { BatchStubURLProtocol.uninstall() }

        let messages = try await Self.fetch(ids: ["m0", "m1"], quotaKey: "retry-capped")

        // The good id still comes back; the bad one is dropped rather than
        // holding the pass open for 5 + 10 + 20 seconds of backoff.
        #expect(messages.map(\.id) == ["m0"])
        #expect(
            BatchStubURLProtocol.requestedURLs.count == 2,
            "one initial envelope + exactly one retry round"
        )
    }

    @Test("The typed outcome reports the still-failing ids EXACTLY — a leftover is never a silent short array")
    func leftoversAreReportedExactly() async throws {
        let round = OSAllocatedUnfairLock(initialState: 0)
        BatchStubURLProtocol.install { _ in
            // Every round refuses the same two ids; ids 0 and 3 always serve.
            // The re-issue carries only the failures, so their op indices shift
            // — which is exactly why the leftover set has to be built from the
            // ids the client asked for, not from positions in the reply.
            let index = round.withLock { value -> Int in
                value += 1
                return value
            }
            if index == 1 {
                return Self.multipartReply([
                    Part(contentId: "op-0", status: 200, body: Self.messageJSON("m0")),
                    Part(contentId: "op-1", status: 429, body: "{}"),
                    Part(contentId: "op-2", status: 429, body: "{}"),
                    Part(contentId: "op-3", status: 200, body: Self.messageJSON("m3")),
                ])
            }
            return Self.multipartReply([
                Part(contentId: "op-0", status: 429, body: "{}"),
                Part(contentId: "op-1", status: 429, body: "{}"),
            ])
        }
        defer { BatchStubURLProtocol.uninstall() }

        let outcome = try await Self.outcome(
            ids: ["m0", "m1", "m2", "m3"], quotaKey: "leftovers-exact"
        )

        #expect(outcome.fetched.map(\.id) == ["m0", "m3"])
        #expect(outcome.leftover == ["m1", "m2"], "the leftover set IS the contract — it drives the full-sync drain")
        #expect(outcome.isComplete == false)
    }

    @Test("A 404 sub-response is skipped, not retried")
    func notFoundIsNotRetried() async throws {
        BatchStubURLProtocol.install { _ in
            Self.multipartReply([
                Part(contentId: "op-0", status: 404, body: "{}"),
                Part(contentId: "op-1", status: 200, body: Self.messageJSON("m1"))
            ])
        }
        defer { BatchStubURLProtocol.uninstall() }

        let messages = try await Self.fetch(ids: ["m0", "m1"], quotaKey: "gone")
        #expect(messages.map(\.id) == ["m1"])
        #expect(BatchStubURLProtocol.requestedURLs.count == 1)
    }

    // MARK: - Envelope width by lane (t-a9825f81)

    @Test("A bulk-lane batch caps each envelope at bulkEnvelopeUnits; an interactive one keeps the format's width")
    func bulkLaneNarrowsTheEnvelope() async throws {
        // Every envelope gets a reply labelled for the widest possible chunk;
        // parts past the chunk's own ids are simply unmatched.
        let width = GmailBatchProtocol.maxOperations(for: .metadata)
        BatchStubURLProtocol.install { _ in
            Self.multipartReply((0..<width).map {
                Part(contentId: "op-\($0)", status: 200, body: Self.messageJSON("m\($0)"))
            })
        }
        defer { BatchStubURLProtocol.uninstall() }
        let ids = (0..<width).map { "m\($0)" }

        _ = try await Self.outcome(ids: ids, quotaKey: "lane-width-interactive")
        #expect(BatchStubURLProtocol.requestedURLs.count == 1, "interactive: one 50-part envelope")

        BatchStubURLProtocol.install { _ in
            Self.multipartReply((0..<width).map {
                Part(contentId: "op-\($0)", status: 200, body: Self.messageJSON("m\($0)"))
            })
        }
        _ = try await GmailQuotaLane.withBulkLane {
            try await Self.outcome(ids: ids, quotaKey: "lane-width-bulk")
        }
        let perEnvelope = GmailQuotaBucket.bulkEnvelopeUnits(for: .current) / GmailQuotaProfile.current.messagesGetCost
        let expected = (width + perEnvelope - 1) / perEnvelope
        #expect(BatchStubURLProtocol.requestedURLs.count == expected,
                "bulk: 1,000-unit metadata envelopes split into \(expected) of at most \(GmailQuotaBucket.bulkEnvelopeUnits(for: .current)) units")
    }

    // MARK: - Envelope rejection → per-id fallback

    @Test("A 400 from the batch endpoint degrades to per-id gets rather than failing the sync")
    func batchUnsupportedFallsBackToPerIdGets() async throws {
        BatchStubURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/batch") {
                return BatchStubURLProtocol.Reply(
                    status: 400, contentType: "application/json", body: Data("{}".utf8)
                )
            }
            let id = String(path.split(separator: "/").last ?? "")
            return BatchStubURLProtocol.Reply(
                status: 200,
                contentType: "application/json",
                body: Data(Self.messageJSON(id).utf8)
            )
        }
        defer { BatchStubURLProtocol.uninstall() }

        let messages = try await Self.unpacedClient().getMessages(
            tokenSource: .fixed("token"),
            messageIds: ["m0", "m1"],
            format: .metadata,
            quotaKey: "fallback"
        )

        #expect(Set(messages.map(\.id)) == ["m0", "m1"])
        let perId = BatchStubURLProtocol.requestedURLs.filter { !$0.contains("/batch/") }
        #expect(perId.count == 2, "every id must be re-fetched on the fallback path")
    }
}

/// The quota bucket the batch dispatcher debits.
@Suite("GmailQuotaBucket")
struct GmailQuotaBucketTests {

    @Test("Successive reservations for one account draw from the SAME balance")
    func successiveCallsShareTheBudget() async throws {
        let bucket = GmailQuotaBucket()
        let profile = GmailQuotaProfile.current
        // A full second of budget is free (the burst), everything after it is paced.
        let units = Int(profile.unitsPerSecond)

        let first = await bucket.reserve(units: units, key: "a")
        let second = await bucket.reserve(units: units, key: "a")
        let third = await bucket.reserve(units: units, key: "a")

        #expect(first == 0, "an idle account spends its first second of budget immediately")
        #expect(second > 0.5, "the second call must be paced by the first — this is the bug the per-call sleep had")
        #expect(third > second, "and the third by both")
    }

    @Test("Accounts are metered independently — Gmail's ceiling is per user")
    func bucketsAreKeyedPerAccount() async throws {
        let bucket = GmailQuotaBucket()
        let units = Int(GmailQuotaProfile.current.unitsPerSecond) * 3

        _ = await bucket.reserve(units: units, key: "account-a")
        let other = await bucket.reserve(units: 5, key: "account-b")

        #expect(other == 0)
    }

    @Test("The shipped profile is the current (post-2026-05-01) one, paced at the MEASURED 50 u/s ceiling")
    func profileIsCurrent() {
        // 50, not the documented 100: the project 403'd in per-minute waves
        // above ~3,000 units/min (t-172bfc74). Raise this only from the Cloud
        // console's real "Queries per minute per user" / 60.
        #expect(GmailQuotaProfile.current.unitsPerSecond == 50)
        #expect(GmailQuotaProfile.current.messagesGetCost == 20)
        #expect(GmailQuotaProfile.current.threadsGetCost == 40)
    }
}
