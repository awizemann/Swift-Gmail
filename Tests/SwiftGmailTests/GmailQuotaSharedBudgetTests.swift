import Foundation
import Testing
@testable import SwiftGmail

/// Gmail's quota is per USER, and every device signed into the account spends
/// against it (t-a9825f81).
///
/// Found live 2026-09-26: after the mail-local split a Mac, an iPad and an
/// iPhone all re-ingested at once. Each device's bucket paced its backfill at
/// `bulkRateFraction` (0.8) of its 50 u/s ceiling — 40 u/s each, 120 u/s
/// together against a 100 u/s (6,000 units/min) per-user budget. Every device
/// drew rate signals, every signal parked BOTH lanes for a minute and halved
/// the rate, and the quick sync / IDLE path stalled with them.
///
/// These tests run three real `GmailQuotaBucket`s against one simulated
/// per-user server on a shared virtual clock. Nothing sleeps.
@Suite("GmailQuotaBucket — three devices share one per-user budget")
struct GmailQuotaSharedBudgetTests {

    // MARK: - Simulation

    /// A clock every simulated device reads. The event loop below is the only
    /// thing that moves it, and it runs on one task, so no lock is needed.
    private final class SimClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        func bucket(policy: GmailQuotaBucket.Policy) -> GmailQuotaBucket {
            // The event loop honours the returned wait itself; `consume` is
            // never called here, so the sleeper must never run.
            GmailQuotaBucket(
                now: { [self] in now },
                sleeper: { _ in Issue.record("the simulation must not sleep") },
                policy: policy
            )
        }
    }

    /// Gmail's per-user quota, modelled as a rolling one-minute window of
    /// accepted units — the strictest reading of "6,000 units per minute",
    /// which is what makes envelope lumps matter. Rejected requests are not
    /// charged.
    private struct PerUserServer {
        let unitsPerMinute: Int
        private var accepted: [(at: Date, units: Int)] = []

        init(unitsPerMinute: Int) { self.unitsPerMinute = unitsPerMinute }

        mutating func accept(_ units: Int, at instant: Date) -> Bool {
            accepted.removeAll { instant.timeIntervalSince($0.at) >= 60 }
            let spent = accepted.reduce(0) { $0 + $1.units }
            guard spent + units <= unitsPerMinute else { return false }
            accepted.append((instant, units))
            return true
        }
    }

    private enum Phase { case reserve, dispatch, respond(accepted: Bool) }

    private struct SimActor {
        let device: Int
        let lane: GmailQuotaLane
        let units: Int
        /// For the interactive actor: seconds between quick syncs.
        let period: TimeInterval?
        var next: Date
        var phase: Phase = .reserve
        var reservedAt: Date?
        /// When the current quick sync first tried — survives a rejection.
        var firstAttempt: Date?
    }

    private struct Outcome {
        var bulkUnits: [Int]
        var bulkSignals: [Int]
        /// Seconds since t0 of every rate signal, bulk or interactive.
        var signalTimes: [TimeInterval] = []
        /// (seconds since t0, delivery latency) per quick sync.
        var quickSyncTimeline: [(at: TimeInterval, latency: TimeInterval)] = []
        var interactiveWaits: [TimeInterval] = []
        var interactiveRejected = 0
        /// First attempt → accepted, per quick sync: what a person waits for
        /// a pushed message, retries after a rejection included.
        var quickSyncLatencies: [TimeInterval] = []
    }

    /// One `messages.get` batch envelope as the full-sync walk sends it — the
    /// chunk width comes from the production chunker on the bulk lane.
    /// `.full` is the history backfill, `.metadata` a fresh install's first
    /// window (50 parts, 1,000 units, before the bulk cap). The quota lands in
    /// these lumps, not smoothly. With the bulk cap both formats send 400-unit
    /// envelopes; the `.metadata` case is the guard that fails if the cap is
    /// removed (two 1,000-unit envelopes a minute per device fill the budget).
    ///
    /// The model is idealised on purpose: one serial envelope stream per
    /// device (production keeps 2–3 in flight, but the shared bulk clock
    /// bounds them the same way), whole-envelope rejection (Gmail rejects per
    /// part), all devices phase-aligned at t0 (the worst case), and only small
    /// quick syncs on the interactive lane.
    private static func envelopeUnits(_ format: MessageFormat) -> Int {
        let cost = GmailQuotaProfile.active.messagesGetCost
        return GmailBatchProtocol.maxOperations(for: format, unitCost: cost, lane: .bulk) * cost
    }
    /// A quick sync that finds three new messages: `history.list` + 3 gets.
    private static let quickSyncUnits = GmailQuotaProfile.active.unitCost.historyList
        + 3 * GmailQuotaProfile.active.messagesGetCost
    /// Round trip before a device learns whether the server took a request.
    private static let latency: TimeInterval = 1
    /// A rejected quick sync tries again after the batch layer's part-retry
    /// delay (`partRetryDelay`), rather than hammering the server.
    private static let quickSyncRetryDelay: TimeInterval = 5

    /// Run `devices` buckets, each driving one continuous bulk pass, against
    /// one per-user server for `duration`. Device 0 also runs a quick sync
    /// every `quickSyncPeriod` seconds on the interactive lane.
    private static func simulate(
        devices: Int,
        duration: TimeInterval,
        format: MessageFormat,
        quickSyncPeriod: TimeInterval? = 45,
        policy: GmailQuotaBucket.Policy = .shipped
    ) async -> Outcome {
        let clock = SimClock()
        let key = "alan@example.com"
        let buckets = (0..<devices).map { _ in clock.bucket(policy: policy) }
        var server = PerUserServer(unitsPerMinute: Int(GmailQuotaProfile.active.perUserUnitsPerSecond * 60))
        let units = envelopeUnits(format)
        var actors = (0..<devices).map {
            SimActor(device: $0, lane: .bulk, units: units, period: nil, next: clock.now)
        }
        if let quickSyncPeriod {
            actors.append(SimActor(
                device: 0, lane: .interactive, units: quickSyncUnits,
                period: quickSyncPeriod, next: clock.now.addingTimeInterval(quickSyncPeriod)
            ))
        }
        var outcome = Outcome(bulkUnits: Array(repeating: 0, count: devices),
                              bulkSignals: Array(repeating: 0, count: devices))
        let end = clock.now.addingTimeInterval(duration)
        let t0 = clock.now

        while true {
            guard let index = actors.indices.min(by: { actors[$0].next < actors[$1].next }),
                  actors[index].next < end else { break }
            var actor = actors[index]
            clock.now = actor.next
            let bucket = buckets[actor.device]

            switch actor.phase {
            case .reserve:
                let wait = await bucket.reserve(units: actor.units, key: key, lane: actor.lane)
                actor.reservedAt = clock.now
                if actor.firstAttempt == nil { actor.firstAttempt = clock.now }
                actor.phase = .dispatch
                actor.next = clock.now.addingTimeInterval(wait)
            case .dispatch:
                if actor.lane == .interactive, let reservedAt = actor.reservedAt {
                    outcome.interactiveWaits.append(clock.now.timeIntervalSince(reservedAt))
                }
                let accepted = server.accept(actor.units, at: clock.now)
                actor.phase = .respond(accepted: accepted)
                actor.next = clock.now.addingTimeInterval(latency)
            case .respond(let accepted):
                if accepted {
                    if actor.lane == .bulk { outcome.bulkUnits[actor.device] += actor.units }
                    await bucket.noteSuccess(key: key)
                } else {
                    if actor.lane == .bulk {
                        outcome.bulkSignals[actor.device] += 1
                    } else {
                        outcome.interactiveRejected += 1
                    }
                    outcome.signalTimes.append(clock.now.timeIntervalSince(t0))
                    await bucket.noteRateLimited(key: key)
                }
                actor.phase = .reserve
                // Bulk runs back to back and a rejected envelope retries at
                // once (its bucket decides how long that waits). A quick sync
                // that landed comes back one period later; a rejected one
                // retries after the part-retry delay.
                if let period = actor.period {
                    if accepted {
                        if let first = actor.firstAttempt {
                            let landed = clock.now.addingTimeInterval(-latency)
                            outcome.quickSyncLatencies.append(landed.timeIntervalSince(first))
                            outcome.quickSyncTimeline.append((first.timeIntervalSince(t0), landed.timeIntervalSince(first)))
                        }
                        actor.firstAttempt = nil
                        actor.next = actor.next.addingTimeInterval(period)
                    } else {
                        actor.next = actor.next.addingTimeInterval(quickSyncRetryDelay)
                    }
                }
            }
            actors[index] = actor
        }
        return outcome
    }

    // MARK: - Tests

    /// How long three devices may take to find each other: the first
    /// collision, and the tail signals of envelopes already in flight.
    private static let settle: TimeInterval = 120

    private static var contendedShare: Double {
        GmailQuotaProfile.active.unitsPerSecond * GmailQuotaBucket.contendedBulkRateFraction
    }

    @Test("Three devices backfilling at once collide once, then share the budget with no further signals for the hold", arguments: [MessageFormat.full, .metadata])
    func threeDevicesCollideOnceThenShare(format: MessageFormat) async {
        let duration = GmailQuotaBucket.contentionHold
        let outcome = await Self.simulate(devices: 3, duration: duration, format: format)

        let late = outcome.signalTimes.filter { $0 > Self.settle }
        #expect(late.isEmpty, "rate signals after the devices settled: \(late.map { Int($0) }) s")
        for (device, signals) in outcome.bulkSignals.enumerated() {
            #expect(signals <= 2, "device \(device) drew \(signals) signals — it did not yield")
        }

        // Fair and not crawling: every device keeps (close to) the contended
        // share for the whole hold, and together they stay inside the budget.
        for (device, units) in outcome.bulkUnits.enumerated() {
            let rate = Double(units) / duration
            #expect(rate >= 0.8 * Self.contendedShare, "device \(device) crawled at \(rate) u/s")
        }
        let total = Double(outcome.bulkUnits.reduce(0, +)) / duration
        #expect(total <= GmailQuotaProfile.active.perUserUnitsPerSecond)
    }

    @Test("After the first collision, a quick sync beside three backfilling devices is never parked", arguments: [MessageFormat.full, .metadata])
    func quickSyncStaysResponsiveDuringThreeDeviceBackfill(format: MessageFormat) async {
        let outcome = await Self.simulate(devices: 3, duration: GmailQuotaBucket.contentionHold,
                                          format: format, quickSyncPeriod: 45)

        let settled = outcome.quickSyncTimeline.filter { $0.at > Self.settle }
        #expect(settled.count >= 100, "the quick-sync actor did not run")
        // Its own reservation at the full rate, nothing more. At 0.8 without
        // the contended share, AIMD re-probes into the wall every few minutes
        // and parks a quick sync for up to a minute each time.
        let ownDuration = Double(Self.quickSyncUnits) / GmailQuotaProfile.active.unitsPerSecond
        let slow = settled.filter { $0.latency > ownDuration + 0.001 }
        #expect(slow.isEmpty, "quick syncs parked after settling: \(slow.map { "\(Int($0.at))s waited \(Int($0.latency))s" })")
    }

    @Test("One device alone backfills at the full uncontended share and never draws a signal", arguments: [MessageFormat.full, .metadata])
    func singleDeviceGetsItsWholeShare(format: MessageFormat) async {
        let duration: TimeInterval = 60 * 60
        let outcome = await Self.simulate(devices: 1, duration: duration, format: format, quickSyncPeriod: 45)
        let share = GmailQuotaProfile.active.unitsPerSecond * GmailQuotaBucket.bulkRateFraction
        #expect(outcome.signalTimes.isEmpty)
        // A quick sync every 45 s is charged to the bulk clock, hence 0.9.
        #expect(Double(outcome.bulkUnits[0]) / duration >= 0.9 * share)
        #expect(outcome.quickSyncLatencies.allSatisfy { $0 <= 2 })
    }

    @Test("The contended share fits three devices with headroom; the uncontended one does not need to")
    func bulkShareArithmetic() {
        let budget = GmailQuotaProfile.active.perUserUnitsPerSecond
        let devices = Double(GmailQuotaBucket.concurrentBulkDevices)
        #expect(devices * Self.contendedShare <= 0.9 * budget,
                "\(devices) × \(Self.contendedShare) u/s leaves under 10% of \(budget) u/s for quick syncs")
        let alone = GmailQuotaProfile.active.unitsPerSecond * GmailQuotaBucket.bulkRateFraction
        #expect(alone > Self.contendedShare, "the lone device must not pay for contention it does not have")
        #expect(alone <= 0.9 * GmailQuotaProfile.active.unitsPerSecond, "interactive keeps headroom on its own device")
    }

    // MARK: - Policy comparison (t-a9825f81: A/B/C asked for, D variants added; D2h ships)

    /// The three candidate policies. All share the 400-unit bulk envelope cap
    /// and the bulk-rate interactive charge; they differ in the share, in
    /// whether a rate signal also throttles the interactive lane, and in
    /// whether a signal drops bulk to a contended share for a while (D).
    static let candidates: [(name: String, policy: GmailQuotaBucket.Policy)] = [
        ("A 0.8", .init(bulkRateFraction: 0.8, signalsThrottleInteractive: true)),
        ("B 0.8 bulk-only signals", .init(bulkRateFraction: 0.8, signalsThrottleInteractive: false)),
        ("C 0.5", .init(bulkRateFraction: 0.5, signalsThrottleInteractive: true)),
        // D: 0.8 alone, but a rate signal drops bulk to 0.5 for 30 minutes.
        ("D 0.8→0.5 30m", .init(bulkRateFraction: 0.8, signalsThrottleInteractive: true,
                                contendedBulkRateFraction: 0.5, contentionHold: 30 * 60)),
        ("D2h 0.8→0.5 2h", .init(bulkRateFraction: 0.8, signalsThrottleInteractive: true,
                                 contendedBulkRateFraction: 0.5, contentionHold: 2 * 60 * 60)),
        ("D2h' 0.8→0.5 2h bulk-only signals", .init(bulkRateFraction: 0.8, signalsThrottleInteractive: false,
                                 contendedBulkRateFraction: 0.5, contentionHold: 2 * 60 * 60)),
        ("D' 0.8→0.5 30m bulk-only signals", .init(bulkRateFraction: 0.8, signalsThrottleInteractive: false,
                                                   contendedBulkRateFraction: 0.5, contentionHold: 30 * 60)),
    ]

    @Test("Policy comparison report — prints the A/B/C table; asserts only that each ran")
    func policyComparisonReport() async {
        let duration: TimeInterval = 3 * 60 * 60
        let cost = Double(GmailQuotaProfile.active.messagesGetCost)
        for (name, policy) in Self.candidates {
            for format in [MessageFormat.full, .metadata] {
                for devices in [1, 3] {
                    let o = await Self.simulate(devices: devices, duration: duration, format: format,
                                                quickSyncPeriod: 45, policy: policy)
                    let perDevice = o.bulkUnits.map { Double($0) / duration }
                    let total = perDevice.reduce(0, +)
                    let worstWait = o.quickSyncLatencies.max() ?? .infinity
                    let lone = perDevice[0]
                    let hours = { (messages: Double) in messages * cost / lone / 3600 }
                    let line = [
                        "POLICY \(name)", "\(format)", "devices=\(devices)",
                        "total=\(String(format: "%.1f", total))u/s",
                        "perDevice=\(perDevice.map { String(format: "%.1f", $0) })",
                        "signals=\(o.bulkSignals.reduce(0, +) + o.interactiveRejected)",
                        "quickSyncWorst=\(String(format: "%.1f", worstWait))s",
                        "quickSyncRejected=\(o.interactiveRejected)",
                        devices == 1 ? "9k=\(String(format: "%.2f", hours(9_000)))h 134k=\(String(format: "%.1f", hours(134_000)))h" : "",
                    ].joined(separator: " ")
                    print(line)
                    if devices == 3 {
                        let slow = o.quickSyncTimeline.filter { $0.latency > 2 }.map { "\(Int($0.at))s:\(Int($0.latency))s" }
                        print("POLICY \(name) \(format) signalTimes=\(o.signalTimes.map { Int($0) }) slowQuickSyncs=\(slow)")
                    }
                    #expect(total > 0)
                }
            }
        }
    }
}
