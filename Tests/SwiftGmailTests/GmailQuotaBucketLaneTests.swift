import Foundation
import Testing
@testable import SwiftGmail

/// Two pacing lanes over one key's rate.
///
/// The incident (t-d4b3419f): an all-time history backfill had hours of
/// `messages.get` reservations queued on the account's bucket, and an
/// IDLE-triggered quick sync joined the BACK of that queue — a pushed message
/// took as long to land as the backfill had left to run. The lanes are the fix:
/// bulk work paces itself against its own clock at `bulkRateFraction` of the rate, and an
/// interactive reservation waits at most its OWN `units / rate` however long
/// the bulk queue is.
@Suite("GmailQuotaBucket — interactive vs bulk lanes")
struct GmailQuotaBucketLaneTests {

    /// Virtual clock: reservations are computed, never slept.
    private final class Clock: @unchecked Sendable {
        private(set) var now = Date(timeIntervalSince1970: 1_700_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
        func bucket() -> GmailQuotaBucket {
            GmailQuotaBucket(now: { [self] in now }, sleeper: { [self] s in advance(s) })
        }
    }

    private static let unitCost = GmailQuotaProfile.current.messagesGetCost
    private static let rate = GmailQuotaProfile.current.unitsPerSecond

    @Test("An interactive reservation never waits behind a long bulk queue")
    func interactiveJumpsTheBulkQueue() async throws {
        let clock = Clock()
        let bucket = clock.bucket()
        let key = "lane-priority"

        // A backfill queues 200 chunks of 20 messages — minutes of pacing.
        for _ in 0..<200 {
            _ = await bucket.reserve(units: 20 * Self.unitCost, key: key, lane: .bulk)
        }
        let bulkTail = await bucket.reserve(units: Self.unitCost, key: key, lane: .bulk)
        #expect(bulkTail > 60, "the bulk queue is supposed to be deep for this test (\(bulkTail)s)")

        // The push arrives.
        let interactive = await bucket.reserve(units: Self.unitCost, key: key, lane: .interactive)

        #expect(
            interactive <= Double(Self.unitCost) / Self.rate,
            "an interactive reservation queued behind bulk work (\(interactive)s)"
        )
    }

    @Test("Bulk paces itself at bulkRateFraction of the key's rate")
    func bulkPacesAtItsShare() async throws {
        let clock = Clock()
        let bucket = clock.bucket()
        let key = "lane-bulk-rate"
        let units = 100

        // First reservation is free (the idle burst); the second one shows the
        // duration the first was charged.
        _ = await bucket.reserve(units: units, key: key, lane: .bulk)
        let wait = await bucket.reserve(units: units, key: key, lane: .bulk)

        let fullRateDuration = Double(units) / Self.rate
        let bulkDuration = fullRateDuration / GmailQuotaBucket.bulkRateFraction
        #expect(abs(wait - bulkDuration) < 0.001, "bulk should pace at bulkRateFraction of the rate, waited \(wait)s")
        #expect(wait > fullRateDuration, "bulk must be SLOWER than the full rate")
    }

    @Test("An interactive reservation delays bulk, so the two lanes share one ceiling")
    func interactiveChargesTheBulkLane() async throws {
        let clock = Clock()
        let bucket = clock.bucket()
        let key = "lane-shared-ceiling"
        let units = 100

        // Spend the idle burst on the bulk clock first, so both clocks are live.
        _ = await bucket.reserve(units: units, key: key, lane: .bulk)
        let beforeInteractive = await bucket.reserve(units: units, key: key, lane: .bulk)
        _ = await bucket.reserve(units: units, key: key, lane: .interactive)
        let afterInteractive = await bucket.reserve(units: units, key: key, lane: .bulk)

        #expect(
            afterInteractive > beforeInteractive,
            "the interactive spend did not push bulk out, so the key can exceed its rate"
        )
        // Charged at the BULK rate (t-a9825f81): bulk forgoes exactly the
        // units interactive spent, so a backfilling device's total stays
        // inside its share of the per-user budget. The old full-rate charge
        // pushed bulk out by only `units / rate` and let the device overspend.
        let bulkRate = Self.rate * GmailQuotaBucket.bulkRateFraction
        #expect(
            abs((afterInteractive - beforeInteractive) - 2 * Double(units) / bulkRate) < 0.001,
            "bulk was pushed \(afterInteractive - beforeInteractive)s, not the interactive units at the bulk rate"
        )
    }

    @Test("A rate signal parks BOTH lanes")
    func rateSignalParksBothLanes() async throws {
        let clock = Clock()
        let bucket = clock.bucket()
        let key = "lane-cooldown"

        await bucket.noteRateLimited(key: key)

        let interactive = await bucket.reserve(units: Self.unitCost, key: key, lane: .interactive)
        let bulk = await bucket.reserve(units: Self.unitCost, key: key, lane: .bulk)

        #expect(interactive >= GmailQuotaBucket.cooldown, "the interactive lane skipped the quota cooldown")
        #expect(bulk >= GmailQuotaBucket.cooldown, "the bulk lane skipped the quota cooldown")
        // One AIMD state, shared: the halved rate applies to both lanes.
        #expect(await bucket.rate(for: key) == Self.rate / 2)
    }

    @Test("A rate signal drops bulk to the contended share for the hold, then gives the full share back")
    func rateSignalYieldsTheBulkShareForTheHold() async throws {
        let clock = Clock()
        let bucket = clock.bucket()
        let key = "lane-contention"
        let units = 100

        func bulkWait() async -> TimeInterval {
            // The step between two consecutive queued reservations is one
            // reservation's duration, whatever idle burst the first spent.
            _ = await bucket.reserve(units: units, key: key, lane: .bulk)
            let second = await bucket.reserve(units: units, key: key, lane: .bulk)
            let third = await bucket.reserve(units: units, key: key, lane: .bulk)
            return third - second
        }

        await bucket.noteRateLimited(key: key)
        clock.advance(GmailQuotaBucket.cooldown + 1)
        let contended = await bulkWait()
        // Read after reserving: `reserve` applies any AIMD recovery due.
        let contendedRate = await bucket.rate(for: key)
        #expect(abs(contended - Double(units) / (contendedRate * GmailQuotaBucket.contendedBulkRateFraction)) < 0.001,
                "inside the hold bulk paces at the contended share, waited \(contended)s")

        // Past the hold (and long enough for AIMD to recover to the ceiling).
        clock.advance(GmailQuotaBucket.contentionHold + 60)
        await bucket.noteSuccess(key: key)
        let rate = await bucket.rate(for: key)
        #expect(rate == Self.rate)
        let uncontended = await bulkWait()
        #expect(abs(uncontended - Double(units) / (rate * GmailQuotaBucket.bulkRateFraction)) < 0.001,
                "after the hold bulk is back at the full share, waited \(uncontended)s")
    }

    @Test("The lane defaults to interactive — an unconverted caller keeps its priority")
    func defaultLaneIsInteractive() async throws {
        let clock = Clock()
        let bucket = clock.bucket()
        let key = "lane-default"

        for _ in 0..<50 {
            _ = await bucket.reserve(units: 20 * Self.unitCost, key: key, lane: .bulk)
        }
        let defaulted = await bucket.reserve(units: Self.unitCost, key: key)

        #expect(defaulted <= Double(Self.unitCost) / Self.rate)
    }

    @Test("withBulkLane is what the full-sync walk rides — and it does not leak out")
    func bulkLaneTaskLocalScopes() async throws {
        #expect(GmailQuotaLane.current == .interactive)
        await GmailQuotaLane.withBulkLane {
            #expect(GmailQuotaLane.current == .bulk)
            // Child tasks inherit it — the pipeline's lookahead fetch is one.
            await withTaskGroup(of: GmailQuotaLane.self) { group in
                group.addTask { GmailQuotaLane.current }
                for await lane in group { #expect(lane == .bulk) }
            }
        }
        #expect(GmailQuotaLane.current == .interactive)
    }
}
