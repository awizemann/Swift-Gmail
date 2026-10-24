import Foundation
import os
import Testing
@testable import SwiftGmail

/// t-e817c15c: the contention hold and AIMD rate survive a relaunch.
///
/// The incident (2026-10-05 08:38–08:41): on app open a history backfill
/// paced at the lone-device share, Gmail rate-limited the account 40 s later,
/// just before the inbox quick sync — the bucket had forgotten the contention
/// it learned in the previous session.
@Suite("GmailQuotaBucket — persisted contention")
struct GmailQuotaBucketPersistenceTests {

    private final class Clock: @unchecked Sendable {
        private(set) var now = Date(timeIntervalSince1970: 1_700_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
        func bucket(store: (any GmailQuotaStateStore)?) -> GmailQuotaBucket {
            GmailQuotaBucket(now: { [self] in now }, sleeper: { [self] s in advance(s) }, stateStore: store)
        }
    }

    /// In-memory store: nothing touches `UserDefaults.standard`.
    private final class MemoryStore: GmailQuotaStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var state: [String: GmailQuotaPersistedKey]
        init(_ state: [String: GmailQuotaPersistedKey] = [:]) { self.state = state }
        func load() -> [String: GmailQuotaPersistedKey] { lock.withLock { state } }
        func save(_ state: [String: GmailQuotaPersistedKey]) { lock.withLock { self.state = state } }
    }

    private static let ceiling = GmailQuotaProfile.current.unitsPerSecond
    private static let units = 100

    /// One bulk reservation's duration on `bucket` — the step between two
    /// consecutive queued reservations, whatever idle burst the first spent.
    private static func bulkStep(_ bucket: GmailQuotaBucket, key: String) async -> TimeInterval {
        _ = await bucket.reserve(units: units, key: key, lane: .bulk)
        let second = await bucket.reserve(units: units, key: key, lane: .bulk)
        let third = await bucket.reserve(units: units, key: key, lane: .bulk)
        return third - second
    }

    @Test("A relaunch inside the hold resumes at the contended share and the AIMD rate")
    func contentionRestoresOnANewInstance() async throws {
        let clock = Clock()
        let store = MemoryStore()
        let key = "persist-restore"

        await clock.bucket(store: store).noteRateLimited(key: key)
        // Relaunch 30 s later — inside the cooldown's recovery interval, so the
        // halved rate is still the rate.
        clock.advance(30)
        let relaunched = clock.bucket(store: store)

        #expect(await relaunched.rate(for: key) == Self.ceiling / 2, "the AIMD rate was not restored")

        // Past the cooldown, still inside the 2 h hold.
        clock.advance(GmailQuotaBucket.cooldown + 600)
        let step = await Self.bulkStep(relaunched, key: key)
        let rate = await relaunched.rate(for: key)
        #expect(
            abs(step - Double(Self.units) / (rate * GmailQuotaBucket.contendedBulkRateFraction)) < 0.001,
            "a relaunch inside the hold probed at the lone-device share (step \(step)s at \(rate) u/s)"
        )
    }

    @Test("Elapsed closed time counts as recovery: an old rate walks back up on restore")
    func restoredRateRecoversByElapsedTime() async throws {
        let clock = Clock()
        let store = MemoryStore()
        let key = "persist-recovery"
        await clock.bucket(store: store).noteRateLimited(key: key)
        clock.advance(GmailQuotaBucket.recoveryInterval * 3 + 1)
        let relaunched = clock.bucket(store: store)
        _ = await relaunched.reserve(units: 1, key: key, lane: .interactive)
        let expected = Self.ceiling / 2 + 3 * GmailQuotaBucket.recoveryFraction * Self.ceiling
        #expect(abs(await relaunched.rate(for: key) - expected) < 0.001)
    }

    @Test("An expired hold is not restored")
    func expiredStateIgnored() async throws {
        let clock = Clock()
        let store = MemoryStore([
            "persist-expired": GmailQuotaPersistedKey(
                contendedUntil: clock.now.addingTimeInterval(-60),
                rate: nil,
                savedAt: clock.now.addingTimeInterval(-GmailQuotaBucket.contentionHold - 60)
            )
        ])
        let bucket = clock.bucket(store: store)
        let step = await Self.bulkStep(bucket, key: "persist-expired")
        #expect(abs(step - Double(Self.units) / (Self.ceiling * GmailQuotaBucket.bulkRateFraction)) < 0.001)
    }

    @Test("State written by a skewed (future) clock is ignored")
    func skewedStateIgnored() async throws {
        let clock = Clock()
        let future = clock.now.addingTimeInterval(24 * 60 * 60)
        let store = MemoryStore([
            "persist-skewed": GmailQuotaPersistedKey(
                contendedUntil: future.addingTimeInterval(GmailQuotaBucket.contentionHold),
                rate: 10,
                savedAt: future
            )
        ])
        let bucket = clock.bucket(store: store)
        #expect(await bucket.rate(for: "persist-skewed") == Self.ceiling)
        let step = await Self.bulkStep(bucket, key: "persist-skewed")
        #expect(abs(step - Double(Self.units) / (Self.ceiling * GmailQuotaBucket.bulkRateFraction)) < 0.001)
    }

    @Test("A hold further out than the window is clamped to now + hold")
    func overlongHoldClamped() async throws {
        let clock = Clock()
        let store = MemoryStore([
            "persist-clamp": GmailQuotaPersistedKey(
                contendedUntil: clock.now.addingTimeInterval(10 * 60 * 60),
                rate: nil,
                savedAt: clock.now
            )
        ])
        let bucket = clock.bucket(store: store)
        let inside = await Self.bulkStep(bucket, key: "persist-clamp")
        #expect(abs(inside - Double(Self.units) / (Self.ceiling * GmailQuotaBucket.contendedBulkRateFraction)) < 0.001)
        clock.advance(GmailQuotaBucket.contentionHold + 60)
        let after = await Self.bulkStep(bucket, key: "persist-clamp")
        #expect(abs(after - Double(Self.units) / (Self.ceiling * GmailQuotaBucket.bulkRateFraction)) < 0.001,
                "a 10 h hold survived past the 2 h window")
    }

    @Test("Out-of-range rates are clamped into [minimum, ceiling]")
    func rateClamped() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func sanitize(_ rate: Double) -> Double? {
            GmailQuotaPersistedKey(contendedUntil: now.addingTimeInterval(60), rate: rate, savedAt: now)
                .sanitized(now: now, hold: 7200, maxPause: 600, minimumRate: 10, ceiling: 50)?.rate
        }
        #expect(sanitize(1) == 10)
        #expect(sanitize(500) == nil)
        #expect(sanitize(.nan) == nil)
        #expect(sanitize(25) == 25)
    }

    @Test("UserDefaults store: round-trips, drops a corrupt entry alone, bounds the key count")
    func userDefaultsStoreIsLenientAndBounded() throws {
        let suite = "GmailQuotaBucketPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsGmailQuotaStateStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        store.save(["a": GmailQuotaPersistedKey(contendedUntil: now, rate: 25, savedAt: now)])
        #expect(store.load()["a"]?.rate == 25)

        // A corrupt sibling and a mistyped optional field.
        let raw = #"{"good":{"savedAt":0,"rate":20},"typo":{"savedAt":0,"rate":"fast"},"bad":{"rate":20},"junk":7}"#
        defaults.set(Data(raw.utf8), forKey: UserDefaultsGmailQuotaStateStore.userDefaultsKey)
        let loaded = store.load()
        #expect(loaded["good"]?.rate == 20)
        #expect(loaded["typo"] != nil && loaded["typo"]?.rate == nil)
        #expect(loaded["bad"] == nil && loaded["junk"] == nil)

        defaults.set(Data("not json".utf8), forKey: UserDefaultsGmailQuotaStateStore.userDefaultsKey)
        #expect(store.load().isEmpty)

        var many: [String: GmailQuotaPersistedKey] = [:]
        for i in 0..<(UserDefaultsGmailQuotaStateStore.maxKeys + 10) {
            many["k\(i)"] = GmailQuotaPersistedKey(contendedUntil: nil, rate: 20, savedAt: now.addingTimeInterval(Double(i)))
        }
        store.save(many)
        let bounded = store.load()
        #expect(bounded.count == UserDefaultsGmailQuotaStateStore.maxKeys)
        #expect(bounded["k0"] == nil, "the oldest entry should be the one dropped")

        store.save([:])
        #expect(defaults.data(forKey: UserDefaultsGmailQuotaStateStore.userDefaultsKey) == nil)
    }
}

/// t-de5eebfb: while an interactive reservation for a key is waiting or in
/// flight, bulk consumers for the SAME key hold their dispatch — bounded, and
/// cancellation-aware.
@Suite("GmailQuotaBucket — inbox priority over bulk")
struct GmailQuotaBucketInteractivePriorityTests {

    private final class Clock: @unchecked Sendable {
        private(set) var now = Date(timeIntervalSince1970: 1_700_000_000)
        private(set) var sleeps = 0
        var onSleep: (@Sendable () async -> Void)?
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
        func bucket(policy: GmailQuotaBucket.Policy = .shipped) -> GmailQuotaBucket {
            GmailQuotaBucket(now: { [self] in now }, sleeper: { [self] s in
                sleeps += 1
                if sleeps > 10_000 { throw CancellationError() } // a runaway loop fails, not hangs
                await onSleep?()
                advance(s)
            }, policy: policy)
        }
    }

    private static let unitCost = GmailQuotaProfile.current.messagesGetCost

    @Test("Bulk waits while an interactive request is pending, then proceeds")
    func bulkYieldsToPendingInteractive() async throws {
        let clock = Clock()
        let bucket = clock.bucket()
        let key = "priority-pending"

        _ = await bucket.reserve(units: Self.unitCost, key: key, lane: .interactive)
        let start = clock.now
        try await bucket.consume(units: Self.unitCost, key: key, lane: .bulk)
        let waited = clock.now.timeIntervalSince(start)

        #expect(waited >= GmailQuotaBucket.interactiveInFlightGrace - 0.001,
                "bulk went out while the interactive fetch was in flight (waited \(waited)s)")
        #expect(waited <= GmailQuotaBucket.interactiveInFlightGrace + 1, "bulk waited too long (\(waited)s)")

        // Interactive cleared: the next bulk dispatch does not yield again.
        clock.advance(10)
        let again = clock.now
        try await bucket.consume(units: Self.unitCost, key: key, lane: .bulk)
        #expect(clock.now.timeIntervalSince(again) < GmailQuotaBucket.interactiveInFlightGrace)
    }

    @Test("Bulk on another key does not yield")
    func otherKeyUnaffected() async throws {
        let clock = Clock()
        let bucket = clock.bucket()
        _ = await bucket.reserve(units: Self.unitCost, key: "priority-a", lane: .interactive)
        let start = clock.now
        try await bucket.consume(units: Self.unitCost, key: "priority-b", lane: .bulk)
        #expect(clock.now == start)
    }

    @Test("A stream of interactive requests delays bulk by at most maxBulkYield")
    func bulkNotStarved() async throws {
        let clock = Clock()
        let bucket = clock.bucket()
        let key = "priority-stream"
        // Every time bulk sleeps, another interactive request arrives —
        // interactive is never idle.
        clock.onSleep = {
            _ = await bucket.reserve(units: Self.unitCost, key: key, lane: .interactive)
        }
        _ = await bucket.reserve(units: Self.unitCost, key: key, lane: .interactive)

        let start = clock.now
        try await bucket.consume(units: Self.unitCost, key: key, lane: .bulk)
        let waited = clock.now.timeIntervalSince(start)

        #expect(waited <= GmailQuotaBucket.maxBulkYield + 1, "bulk starved under interactive load (\(waited)s)")
        #expect(waited >= GmailQuotaBucket.interactiveInFlightGrace - 0.001, "bulk did not yield at all")
    }

    @Test("A cancelled bulk waiter leaves promptly — cancelled DURING the yield sleep")
    func cancelledBulkWaiterExits() async throws {
        // Real sleeps: the cancellation has to cut a real wait. The sleeper
        // signals when it starts, so the cancel lands inside the yield sleep.
        var policy = GmailQuotaBucket.Policy.shipped
        policy.maxBulkYield = 5
        policy.yieldPollInterval = 30
        let (started, signal) = AsyncStream<Void>.makeStream()
        let bucket = GmailQuotaBucket(sleeper: { seconds in
            signal.yield()
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }, policy: policy)
        let key = "priority-cancel"
        // In flight with no reservation: the bulk reservation is free, so the
        // first sleep IS the yield.
        await bucket.beginInteractive(key: key)

        let clockStart = Date()
        let task = Task {
            try await bucket.consume(units: 1, key: key, lane: .bulk)
        }
        // If bulk never sleeps (no yield), end the stream instead of hanging.
        Task { _ = await task.result; signal.finish() }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        let result = await task.result
        let elapsed = Date().timeIntervalSince(clockStart)

        #expect(elapsed < 2, "the cancelled bulk waiter lingered \(elapsed)s")
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test("A slow interactive request (longer than any fixed window) keeps bulk off the wire until it ends")
    func explicitInFlightBlocksBulk() async throws {
        let clock = Clock()
        let bucket = clock.bucket()
        let key = "priority-inflight"
        // The request takes 8 s; it ends from inside bulk's poll sleeps.
        let ended = OSAllocatedUnfairLock(initialState: false)
        clock.onSleep = { [clock] in
            guard clock.now.timeIntervalSince1970 - 1_700_000_000 >= 8,
                  !ended.withLock({ let was = $0; $0 = true; return was }) else { return }
            await bucket.endInteractive(key: key)
        }
        _ = await bucket.reserve(units: Self.unitCost, key: key, lane: .interactive)
        await bucket.beginInteractive(key: key)

        try await bucket.consume(units: Self.unitCost, key: key, lane: .bulk)
        let released = clock.now.timeIntervalSince1970 - 1_700_000_000

        #expect(released >= 8, "bulk went out while the interactive request was still in flight (at \(released)s)")
        #expect(released <= 8 + GmailQuotaBucket.interactiveInFlightGrace + GmailQuotaBucket.yieldPollInterval + 0.5)
    }

    @Test("Bulk waiters released by one interactive burst go out spaced, not all at once")
    func yieldedWaitersAreRepaced() async throws {
        var policy = GmailQuotaBucket.Policy.shipped
        policy.interactiveInFlightGrace = 0.1
        policy.yieldPollInterval = 0.02
        let bucket = GmailQuotaBucket(policy: policy)
        let key = "priority-repace"
        // 12 units at the bulk rate (50 × 0.8 = 40 u/s) = 0.3 s apart.
        let units = 12
        let spacing = Double(units) / (GmailQuotaProfile.current.unitsPerSecond * GmailQuotaBucket.bulkRateFraction)

        await bucket.beginInteractive(key: key)
        let origin = Date()
        let finishes = try await withThrowingTaskGroup(of: TimeInterval.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try await bucket.consume(units: units, key: key, lane: .bulk)
                    return Date().timeIntervalSince(origin)
                }
            }
            // A long interactive request: every waiter's own slot passes
            // while it is still on the wire.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            await bucket.endInteractive(key: key)
            var all: [TimeInterval] = []
            for try await t in group { all.append(t) }
            return all.sorted()
        }

        #expect(finishes[0] >= 1.0, "a waiter went out during the interactive request")
        #expect(finishes[1] - finishes[0] >= spacing * 0.6, "waiters released as one lump: \(finishes)")
        #expect(finishes[2] - finishes[1] >= spacing * 0.6, "waiters released as one lump: \(finishes)")
    }
}

/// Second round on persistence (t-e817c15c follow-up): per-key stamps, the
/// hint and cooldown, and restored state throttling bulk only.
@Suite("GmailQuotaBucket — persisted state, per key and bulk-only")
struct GmailQuotaBucketPersistedStateTests {

    private final class Clock: @unchecked Sendable {
        private(set) var now = Date(timeIntervalSince1970: 1_700_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
        func bucket(store: (any GmailQuotaStateStore)?) -> GmailQuotaBucket {
            GmailQuotaBucket(now: { [self] in now }, sleeper: { [self] s in advance(s) }, stateStore: store)
        }
    }

    private final class MemoryStore: GmailQuotaStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var state: [String: GmailQuotaPersistedKey] = [:]
        func load() -> [String: GmailQuotaPersistedKey] { lock.withLock { state } }
        func save(_ state: [String: GmailQuotaPersistedKey]) { lock.withLock { self.state = state } }
    }

    private static let ceiling = GmailQuotaProfile.current.unitsPerSecond
    private static let step = GmailQuotaBucket.recoveryFraction * ceiling

    private static func laneStep(_ bucket: GmailQuotaBucket, key: String, lane: GmailQuotaLane, units: Int = 100) async -> TimeInterval {
        _ = await bucket.reserve(units: units, key: key, lane: lane)
        let second = await bucket.reserve(units: units, key: key, lane: lane)
        let third = await bucket.reserve(units: units, key: key, lane: lane)
        return third - second
    }

    @Test("Another key's write does not erase an idle key's earned recovery")
    func twoKeyPersistenceKeepsEachKeysOrigin() async throws {
        let clock = Clock()
        let store = MemoryStore()
        let first = clock.bucket(store: store)
        await first.noteRateLimited(key: "acct-a")
        clock.advance(3 * GmailQuotaBucket.recoveryInterval)
        await first.noteRateLimited(key: "acct-b")   // re-saves the whole map
        clock.advance(1)

        let relaunched = clock.bucket(store: store)
        _ = await relaunched.reserve(units: 1, key: "acct-a", lane: .bulk)
        #expect(abs(await relaunched.rate(for: "acct-a") - (Self.ceiling / 2 + 3 * Self.step)) < 0.001,
                "acct-a lost the three clean minutes it earned before acct-b's signal")
        #expect(await relaunched.rate(for: "acct-b") == Self.ceiling / 2)
    }

    @Test("The ceiling hint and the cooldown survive a relaunch")
    func hintAndPauseRestored() async throws {
        let clock = Clock()
        let store = MemoryStore()
        await clock.bucket(store: store).noteRateLimited(key: "hint")
        clock.advance(10)

        let relaunched = clock.bucket(store: store)
        let bulkWait = await relaunched.reserve(units: 1, key: "hint", lane: .bulk)
        #expect(bulkWait >= GmailQuotaBucket.cooldown - 10 - 0.001, "the restored cooldown did not park bulk (\(bulkWait)s)")

        // Five clean minutes: recovery climbs to the hint (0.9 × 50 = 45),
        // not to the profile ceiling.
        clock.advance(5 * GmailQuotaBucket.recoveryInterval)
        await relaunched.noteSuccess(key: "hint")
        #expect(abs(await relaunched.rate(for: "hint") - Self.ceiling * GmailQuotaBucket.limitHintFraction) < 0.001,
                "the restored rate recovered past the hint")
    }

    @Test("After a restore interactive paces normally (at the hint, unparked) while bulk stays throttled")
    func restoredStateThrottlesBulkOnly() async throws {
        let clock = Clock()
        let store = MemoryStore()
        await clock.bucket(store: store).noteRateLimited(key: "bulk-only")
        clock.advance(20)

        let relaunched = clock.bucket(store: store)
        let interactiveWait = await relaunched.reserve(units: 1, key: "bulk-only", lane: .interactive)
        #expect(interactiveWait == 0, "yesterday's cooldown parked the app-open inbox fetch (\(interactiveWait)s)")
        let hint = Self.ceiling * GmailQuotaBucket.limitHintFraction
        let interactive = await Self.laneStep(relaunched, key: "bulk-only", lane: .interactive)
        #expect(abs(interactive - 100 / hint) < 0.001, "interactive paced at the restored AIMD rate (\(interactive)s)")
        let bulk = await Self.laneStep(relaunched, key: "bulk-only", lane: .bulk)
        let rate = await relaunched.rate(for: "bulk-only")
        #expect(abs(bulk - 100 / (rate * GmailQuotaBucket.contendedBulkRateFraction)) < 0.001, "bulk lost its restored throttle")

        // A signal THIS session brings the both-lanes throttle back.
        clock.advance(GmailQuotaBucket.cooldown + 1)
        await relaunched.noteRateLimited(key: "bulk-only")
        let parked = await relaunched.reserve(units: 1, key: "bulk-only", lane: .interactive)
        #expect(parked >= GmailQuotaBucket.cooldown - 0.001)
    }
}

/// The client half: every request is bracketed for in-flight tracking and
/// reports its own rate signal (t-de5eebfb; the single-call gap).
@Suite("GmailAPIClient.send — in-flight tracking and single-call rate signals")
struct GmailAPIClientSendQuotaTests {

    private static func response(_ status: Int, _ body: String = "{}") -> (Data, URLResponse) {
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    @Test("A single-call 429 halves the account's rate")
    func singleCall429FeedsTheBucket() async throws {
        let bucket = GmailQuotaBucket()
        let client = GmailAPIClient(quotaBucket: bucket) { _ in Self.response(429) }
        await #expect(throws: (any Error).self) {
            _ = try await client.getProfile(accessToken: "t", quotaKey: "single-429")
        }
        #expect(await bucket.rate(for: "single-429") == GmailQuotaProfile.current.unitsPerSecond / 2)
    }

    @Test("A single-call rate-reason 403 feeds the bucket; a refusal 403 does not")
    func singleCall403Classified() async throws {
        let rate403 = #"{"error":{"code":403,"errors":[{"domain":"usageLimits","reason":"userRateLimitExceeded"}]}}"#
        let refusal403 = #"{"error":{"code":403,"errors":[{"domain":"global","reason":"insufficientPermissions"}]}}"#
        let bucket = GmailQuotaBucket()
        let rateClient = GmailAPIClient(quotaBucket: bucket) { _ in Self.response(403, rate403) }
        let refusalClient = GmailAPIClient(quotaBucket: bucket) { _ in Self.response(403, refusal403) }
        await #expect(throws: (any Error).self) {
            _ = try await rateClient.listMessages(accessToken: "t", query: "x", quotaKey: "single-403")
        }
        await #expect(throws: (any Error).self) {
            _ = try await refusalClient.listMessages(accessToken: "t", query: "x", quotaKey: "refusal-403")
        }
        #expect(await bucket.rate(for: "single-403") == GmailQuotaProfile.current.unitsPerSecond / 2)
        #expect(await bucket.rate(for: "refusal-403") == GmailQuotaProfile.current.unitsPerSecond)
    }

    @Test("A bulk consumer waits for an interactive request that is still on the wire")
    func clientBracketsInteractiveRequests() async throws {
        var policy = GmailQuotaBucket.Policy.shipped
        policy.interactiveInFlightGrace = 0.05
        policy.yieldPollInterval = 0.02
        let bucket = GmailQuotaBucket(policy: policy)
        let profile = #"{"emailAddress":"a@b.c","messagesTotal":1,"threadsTotal":1,"historyId":"1"}"#
        // The interactive request takes 0.8 s on the wire.
        let client = GmailAPIClient(quotaBucket: bucket) { _ in
            try await Task.sleep(nanoseconds: 800_000_000)
            return Self.response(200, profile)
        }
        let origin = Date()
        async let interactive: GmailProfile = client.getProfile(accessToken: "t", quotaKey: "bracket")
        try await Task.sleep(nanoseconds: 200_000_000)
        try await bucket.consume(units: 1, key: "bracket", lane: .bulk)
        let bulkAt = Date().timeIntervalSince(origin)
        _ = try await interactive

        #expect(bulkAt >= 0.75, "bulk went out while the interactive request was on the wire (at \(bulkAt)s)")
    }
}
