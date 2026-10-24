import Foundation
import Testing
import os
@testable import SwiftGmail

/// Follow-ups on the cooldown (post-t-de5eebfb review): a live `Retry-After`
/// is clamped, the yield's release spacing stays inside the per-consume cap,
/// repeat signals inside a cooldown do not rewrite the store, and a person's
/// outgoing mail is never parked.
@Suite("GmailQuotaBucket — cooldown clamps, bounded spacing, unparked sends")
struct GmailQuotaBucketCooldownTests {

    private final class Clock: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_700_000_000))
        private let hook = OSAllocatedUnfairLock<(@Sendable () async -> Void)?>(initialState: nil)
        var now: Date { state.withLock { $0 } }
        var elapsed: TimeInterval { now.timeIntervalSince1970 - 1_700_000_000 }
        func advance(_ seconds: TimeInterval) { state.withLock { $0 += seconds } }
        func onSleep(_ body: @escaping @Sendable () async -> Void) { hook.withLock { $0 = body } }
        func bucket(store: (any GmailQuotaStateStore)? = nil) -> GmailQuotaBucket {
            GmailQuotaBucket(now: { [self] in now }, sleeper: { [self] s in
                if let body = hook.withLock({ $0 }) { await body() }
                advance(s)
            }, stateStore: store)
        }
    }

    private final class CountingStore: GmailQuotaStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var state: [String: GmailQuotaPersistedKey] = [:]
        private(set) var saves = 0
        func load() -> [String: GmailQuotaPersistedKey] { lock.withLock { state } }
        func save(_ state: [String: GmailQuotaPersistedKey]) { lock.withLock { self.state = state; saves += 1 } }
    }

    @Test("A live Retry-After of an hour parks for at most maxPause")
    func liveRetryAfterClamped() async {
        let clock = Clock()
        let bucket = clock.bucket()
        await bucket.noteRateLimited(key: "clamp", retryAfter: 3600)
        let interactive = await bucket.reserve(units: 1, key: "clamp", lane: .interactive)
        #expect(interactive <= GmailQuotaBucket.maxPause + 0.001, "an hour-long Retry-After parked the inbox for \(interactive)s")
        #expect(interactive >= GmailQuotaBucket.cooldown)
    }

    @Test("Release spacing counts against the yield cap — total extra wait is bounded")
    func spacingInsideTheCap() async throws {
        let clock = Clock()
        let bucket = clock.bucket()
        let key = "spacing-cap"
        await bucket.beginInteractive(key: key)
        // A chain already pushed far ahead — earlier waiters of a long burst.
        for _ in 0..<5 {
            _ = await bucket.bulkReleaseDelay(units: bucket.bulkEnvelopeUnits, key: key, within: .infinity)
        }
        let ended = OSAllocatedUnfairLock(initialState: false)
        clock.onSleep { [clock] in
            guard clock.elapsed >= 2, !ended.withLock({ let was = $0; $0 = true; return was }) else { return }
            await bucket.endInteractive(key: key)
        }

        let start = clock.elapsed
        try await bucket.consume(units: bucket.bulkEnvelopeUnits, key: key, lane: .bulk)
        let waited = clock.elapsed - start

        #expect(waited >= 2, "bulk did not yield")
        #expect(waited <= GmailQuotaBucket.maxBulkYield + 0.001, "yield + spacing escaped the cap: \(waited)s")
    }

    @Test("Repeat signals inside one cooldown write the store once")
    func repeatSignalsPersistOnce() async {
        let clock = Clock()
        let store = CountingStore()
        let bucket = clock.bucket(store: store)
        await bucket.noteRateLimited(key: "repeat")
        for _ in 0..<5 {
            clock.advance(1)
            await bucket.noteRateLimited(key: "repeat")
        }
        #expect(store.saves == 1, "a 429 per id rewrote UserDefaults \(store.saves) times")
        // A longer Retry-After DOES move the park, so it is saved.
        await bucket.noteRateLimited(key: "repeat", retryAfter: 300)
        #expect(store.saves == 2)
    }

    @Test("An unparkable send reservation dispatches during an active cooldown")
    func unparkableReservationSkipsThePark() async {
        let clock = Clock()
        let bucket = clock.bucket()
        await bucket.noteRateLimited(key: "send-park")
        #expect(await bucket.reserve(units: 100, key: "send-park", lane: .interactive, parkable: false) == 0)
        // Ordinary interactive work is still parked, and bulk was charged.
        #expect(await bucket.reserve(units: 1, key: "send-park", lane: .interactive) >= GmailQuotaBucket.cooldown - 0.001)
    }

    @Test("messages.send during a cooldown goes out without waiting for the park")
    func sendMessageNotParked() async throws {
        let clock = Clock()
        let bucket = clock.bucket()
        let sent = OSAllocatedUnfairLock(initialState: 0)
        let client = GmailAPIClient(quotaBucket: bucket) { request in
            sent.withLock { $0 += 1 }
            let url = request.url ?? URL(string: "https://gmail.googleapis.com")!
            let body = #"{"id":"m1","threadId":"t1"}"#
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await bucket.noteRateLimited(key: "send-cooldown")
        let before = clock.elapsed

        let response = try await client.sendMessage(accessToken: "t", rawMessage: "raw", quotaKey: "send-cooldown")

        #expect(response.id == "m1")
        #expect(sent.withLock { $0 } == 1)
        #expect(clock.elapsed - before < 1, "the send waited \(clock.elapsed - before)s behind the cooldown")
    }
}
