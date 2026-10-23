//
//  GmailQuotaBucket+InteractivePriority.swift
//  SwiftGmail
//
//  Inbox wins over bulk (t-de5eebfb).
//
//  The lanes already keep an interactive reservation off the back of the bulk
//  QUEUE, but both still spend the same per-user minute: on 2026-10-05 an
//  app-open history backfill dispatched paced envelopes right as the inbox
//  quick sync started, and Gmail rate-limited the account between them. So a
//  bulk dispatch now waits while an interactive request for the same key is
//  waiting for its slot or on the wire.
//
//  - Waiting: an interactive reservation marks the key busy until its slot
//    plus `interactiveInFlightGrace`.
//  - In flight: `GmailAPIClient.send` brackets every interactive HTTP request
//    with `beginInteractive` / `endInteractive`; the end leaves the same grace,
//    which bridges one call of a quick sync to its next.
//  - Bounded: one bulk `consume` yields at most `maxBulkYield`, then goes.
//  - Re-paced: waiters released by the same burst leave `units / bulkRate`
//    apart instead of all at once.
//

import Foundation
import os

extension GmailQuotaBucket {

    /// An interactive request for `key` is going on the wire.
    func beginInteractive(key: String) {
        var bucket = buckets[key] ?? Bucket()
        bucket.interactiveInFlight += 1
        buckets[key] = bucket
    }

    /// An interactive request for `key` finished (any outcome). Bulk keeps
    /// yielding for the grace, so the quick sync's next call is not raced.
    func endInteractive(key: String) {
        var bucket = buckets[key] ?? Bucket()
        bucket.interactiveInFlight = max(0, bucket.interactiveInFlight - 1)
        let busy = now().addingTimeInterval(policy.interactiveInFlightGrace)
        bucket.interactiveBusyUntil = max(bucket.interactiveBusyUntil ?? busy, busy)
        buckets[key] = bucket
    }

    /// Hold a bulk dispatch while interactive work for `key` is waiting or in
    /// flight. Runs AFTER the bulk reservation's own wait — right before the
    /// envelope would go out — because that is the moment it would collide
    /// with the inbox fetch.
    ///
    /// No lock is held and interactive never waits on bulk, so there is
    /// nothing to deadlock. Cancellation-aware: checked every iteration, and
    /// the default sleeper throws on cancel, so a cancelled bulk waiter (the
    /// iOS background expiry) leaves at once.
    nonisolated func yieldToInteractive(units: Int, key: String) async throws {
        guard policy.maxBulkYield > 0 else { return }
        let deadline = now().addingTimeInterval(policy.maxBulkYield)
        var waited = false
        while true {
            try Task.checkCancellation()
            guard let busy = await interactiveBusy(key: key, noteYield: !waited) else { break }
            let instant = now()
            let budget = deadline.timeIntervalSince(instant)
            guard budget > 0 else { break }
            // In flight: the end is unknown, so poll. Waiting: sleep to the slot.
            let step = busy.map { $0.timeIntervalSince(instant) } ?? policy.yieldPollInterval
            waited = true
            try await sleeper(min(max(step, 0.001), budget))
        }
        guard waited else { return }
        // Spacing counts against the same deadline: the cap bounds the WHOLE
        // extra wait a yield adds, never yield + spacing on top.
        let remaining = max(0, deadline.timeIntervalSince(now()))
        let spacing = await bulkReleaseDelay(units: units, key: key, within: remaining)
        if spacing > 0 {
            try Task.checkCancellation()
            try await sleeper(spacing)
        }
    }

    /// nil when `key` has no interactive work pending. Otherwise `.some(date)`
    /// when only the grace/slot remains (busy until `date`), or `.some(nil)`
    /// while a request is in flight. `noteYield` logs the yield, at most once
    /// per key per `yieldLogInterval`.
    func interactiveBusy(key: String, noteYield: Bool) -> Date?? {
        let instant = now()
        guard var bucket = buckets[key] else { return nil }
        let inFlight = bucket.interactiveInFlight > 0
        let until = bucket.interactiveBusyUntil.flatMap { $0 > instant ? $0 : nil }
        guard inFlight || until != nil else { return nil }
        if noteYield, bucket.lastYieldLog.map({ instant.timeIntervalSince($0) >= Self.yieldLogInterval }) ?? true {
            bucket.lastYieldLog = instant
            buckets[key] = bucket
            let reason = inFlight ? "\(bucket.interactiveInFlight) request(s) in flight" : "a reservation pending"
            logger.notice("Gmail quota: bulk yielding to interactive for \(key, privacy: .public) — \(reason, privacy: .public), up to \(String(format: "%.0f", self.policy.maxBulkYield), privacy: .public)s")
        }
        return .some(inFlight ? nil : until)
    }

    /// How much longer a waiter released from a yield must wait so that the
    /// waiters one interactive burst held back go out `units / bulkRate`
    /// apart, not as one lump into the minute interactive just used.
    ///
    /// At most `limit` (what is left of the waiter's yield deadline). The
    /// chain restarts from the waiter's ACTUAL release — a chain that lags
    /// `now` restarts at `now`, and one pushed far ahead (by earlier capped
    /// waiters) is pulled back — so it only ever spaces the waiters of one
    /// burst and never stacks a second pacing on top of the bulk clock.
    func bulkReleaseDelay(units: Int, key: String, within limit: TimeInterval) -> TimeInterval {
        let instant = now()
        var bucket = buckets[key] ?? Bucket()
        let wanted = max(instant, bucket.bulkReleaseAt ?? instant)
        let delay = min(max(0, limit), wanted.timeIntervalSince(instant))
        let release = instant.addingTimeInterval(delay)
        bucket.bulkReleaseAt = release.addingTimeInterval(Double(units) / bulkRate(of: bucket, at: instant))
        buckets[key] = bucket
        return delay
    }
}
