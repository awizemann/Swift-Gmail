//
//  GmailQuotaBucket+Persistence.swift
//  SwiftGmail
//
//  Restoring and saving the bucket's per-key state across launches
//  (t-e817c15c). The store and the entry shape live in
//  `GmailQuotaStateStore.swift`.
//

import Foundation
import os

extension GmailQuotaBucket {

    /// Rebuild the persisted keys' state.
    ///
    /// A relaunch inside a contention hold resumes at the contended share
    /// instead of re-probing at the lone-device one; the AIMD rate, ceiling
    /// hint and cooldown resume where they were, with each key's own recovery
    /// origins, so time spent closed counts as clean recovery time.
    ///
    /// Restored state throttles the BULK lane only (`restoredBulkOnly`): the
    /// cooldown parks the bulk clock, not the interactive one, and interactive
    /// paces at the ceiling hint rather than yesterday's halved rate — an
    /// app-open inbox fetch is not slowed by a signal from the last session.
    /// The first signal of this session restores the both-lanes throttle.
    static func restore(
        from store: (any GmailQuotaStateStore)?,
        now instant: Date,
        policy: Policy
    ) -> (buckets: [String: Bucket], persisted: [String: GmailQuotaPersistedKey]) {
        guard let store else { return ([:], [:]) }
        var buckets: [String: Bucket] = [:]
        var persisted: [String: GmailQuotaPersistedKey] = [:]
        for (key, raw) in store.load() {
            guard let entry = raw.sanitized(
                now: instant,
                hold: policy.contentionHold,
                maxPause: maxRestoredPause,
                minimumRate: minimumUnitsPerSecond,
                ceiling: GmailQuotaProfile.active.unitsPerSecond
            ) else { continue }
            persisted[key] = entry
            var bucket = Bucket()
            bucket.rate = entry.rate
            bucket.lastRecovered = entry.lastRecovered
            bucket.limitHint = entry.limitHint
            bucket.hintRelaxedAt = entry.hintRelaxedAt
            bucket.contendedUntil = policy.contendedBulkRateFraction == nil ? nil : entry.contendedUntil
            bucket.pausedUntil = entry.pausedUntil
            bucket.nextFreeBulk = entry.pausedUntil
            bucket.restoredBulkOnly = true
            buckets[key] = bucket
            let remaining = bucket.contendedUntil.map { Int($0.timeIntervalSince(instant) / 60) } ?? 0
            let rate = entry.rate ?? GmailQuotaProfile.active.unitsPerSecond
            logger.notice("Gmail quota: restored contended state for \(key, privacy: .public) — bulk rate \(String(format: "%.0f", rate), privacy: .public) u/s, contended for \(remaining, privacy: .public) more min, hint \(entry.limitHint.map { String(format: "%.0f", $0) } ?? "none", privacy: .public)")
        }
        return (buckets, persisted)
    }

    /// Save `key`'s state after it changed (a rate signal, an AIMD or hint
    /// step, a reset) — never per reservation. Only THAT key's entry is
    /// re-stamped; every other key keeps the `savedAt` and recovery origins
    /// it was written with.
    func persist(key: String) {
        guard let stateStore else { return }
        let instant = now()
        if let bucket = buckets[key] {
            let entry = GmailQuotaPersistedKey(
                contendedUntil: bucket.contendedUntil.flatMap { $0 > instant ? $0 : nil },
                rate: bucket.rate,
                lastRecovered: bucket.rate == nil ? nil : bucket.lastRecovered,
                limitHint: bucket.limitHint,
                hintRelaxedAt: bucket.limitHint == nil ? nil : bucket.hintRelaxedAt,
                pausedUntil: bucket.pausedUntil.flatMap { $0 > instant ? $0 : nil },
                savedAt: instant
            )
            persisted[key] = entry.isEmpty ? nil : entry
        } else {
            persisted[key] = nil
        }
        stateStore.save(persisted)
    }
}
