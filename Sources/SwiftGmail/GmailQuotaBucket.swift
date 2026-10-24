//
//  GmailQuotaBucket.swift
//  SwiftGmail
//
//  One token bucket per Gmail user, shared by every batch the app dispatches
//  for that account.
//
//  The pacing this replaces lived inside a single `batchGet` call: it slept
//  between the chunks of ONE call and forgot everything the moment the call
//  returned. So a full-sync pipeline issuing chunk after chunk — and a quick
//  sync running beside it, and a thread fetch beside that — each started from
//  a clean slate and the real dispatch rate was a multiple of the budget.
//  A bucket that outlives the call is the whole fix: successive calls draw
//  from the same balance, so the account's aggregate rate is what's bounded.
//
//  The bucket is also ADAPTIVE (AIMD, t-172bfc74). A hard-coded ceiling is a
//  guess — Gmail's real per-user "queries per minute" is a per-project console
//  setting we cannot read from the client — so the server's own rate signals
//  are the feedback loop: `noteRateLimited` halves the account's rate and
//  parks it for a cooldown, `noteSuccess` walks it back up to the profile
//  ceiling a clean minute at a time.
//
//  The budget is per USER and every device on the account spends it
//  (t-a9825f81), so after a rate signal the bulk lane yields to a per-device
//  share sized for three devices backfilling at once — see
//  `contendedBulkRateFraction`.
//
//  Two later additions (t-e817c15c, t-de5eebfb): the contention hold and the
//  AIMD rate survive a relaunch (`GmailQuotaStateStore`), and a bulk consumer
//  YIELDS while an interactive request for the same key is waiting or in
//  flight, so an app-open backfill cannot spend the minute the inbox quick
//  sync is about to need — see `GmailQuotaBucket+InteractivePriority.swift`
//  and `GmailQuotaBucket+Persistence.swift`.
//

import Foundation
import os

/// Gmail's per-user rate limit, paired with the unit-cost table it is spent
/// against.
///
/// `legacy` is what a pre-2026-05-01 Cloud project is metered against: 250
/// units/second with the cheap per-object gets (`messages.get` = 5,
/// `threads.get` = 10). `current` — the one this build uses — is the
/// post-2026-05-01 profile, where those are 20 and 40 and the per-user ceiling
/// is a per-project console value rather than a constant.
///
/// The costs themselves are NOT declared here: they live in `GmailUnitCost`,
/// which carries the citation to Google's documented table and is the single
/// source of truth for every metered call in `GmailAPIClient`.
public struct GmailQuotaProfile: Sendable {
    /// The most ONE device paces a key at — the AIMD ceiling of its bucket.
    public let unitsPerSecond: Double

    /// Gmail's quota for the whole USER, which every device signed into the
    /// account spends against and none of them can see the others spend
    /// (t-a9825f81). Not a pacing input: `GmailQuotaBucket.bulkRateFraction`
    /// is sized against it, and the shared-budget tests model the server
    /// with it.
    public let perUserUnitsPerSecond: Double

    /// Every method's unit cost for this profile — the single source of truth
    /// for what a call debits. See `GmailUnitCost` for the documented table
    /// and its citation.
    public let unitCost: GmailUnitCost

    public init(unitsPerSecond: Double, perUserUnitsPerSecond: Double, unitCost: GmailUnitCost) {
        self.unitsPerSecond = unitsPerSecond
        self.perUserUnitsPerSecond = perUserUnitsPerSecond
        self.unitCost = unitCost
    }

    /// The two per-object gets the batch envelopes price themselves off.
    /// Derived from `unitCost` so there is exactly one table.
    var messagesGetCost: Int { unitCost.messagesGet }
    var threadsGetCost: Int { unitCost.threadsGet }

    /// Pre-2026-05-01 projects — 15,000 units/minute.
    public static let legacy = GmailQuotaProfile(unitsPerSecond: 250, perUserUnitsPerSecond: 250, unitCost: .legacy)

    /// Projects created on or after 2026-05-01 — the project this was measured on
    /// (created 2026-09-11) is metered against this one.
    ///
    /// 50 units/second is the MEASURED ceiling, not the documented default:
    /// on 2026-09-12 the project sustained ≈125 `messages.get`/min × 20 units
    /// ≈ 2,500 units/min and 403'd in per-minute waves above it, i.e. an
    /// effective ~3,000 units/min / 50 u/s. The documented 100 u/s was twice
    /// the real budget and produced 159,080 per-part 403s in nine hours.
    /// Refine to (console "Queries per minute per user" / 60) once the real
    /// figure is read off the Cloud console; the adaptive bucket below only
    /// ever paces BELOW this number, so an over-estimate here costs throughput
    /// rather than correctness.
    ///
    /// The per-user figure is Google's documented 6,000 units/minute
    /// (100 u/s). After the mail-local split a Mac, an iPad and an iPhone
    /// each ingest their own mail against it, so 50 u/s is one device's
    /// ceiling, not the account's: three devices at 50 ask for 150.
    public static let current = GmailQuotaProfile(unitsPerSecond: 50, perUserUnitsPerSecond: 100, unitCost: .documented)
}

/// Which pacing lane a reservation belongs to.
///
/// Two virtual clocks share one key's rate ceiling (and one key's AIMD state).
/// The point is the ordering, not the budget: a full-sync backfill can have
/// hours of `messages.get` queued on a key, and before lanes existed an
/// IDLE-triggered quick sync joined the BACK of that queue — a new message
/// took as long to land as the backfill had left to run (t-d4b3419f).
///
/// - `interactive`: anything a person is waiting for — quick sync, an
///   IDLE-triggered fetch, thread/body hydration. Paced at the key's full
///   rate against its OWN clock, so it never waits behind queued bulk work.
/// - `bulk`: history backfill — the full-sync pipeline (first window and
///   history backfill alike), its sliced listing, the leftover drain and the
///   attachment sweep. Paced at `bulkRateFraction` of the key's rate, dropping
///   to `contendedBulkRateFraction` for a while after a rate signal so several
///   devices backfilling the same account fit inside the per-user budget. It
///   never advances the interactive clock.
public enum GmailQuotaLane: Sendable, Hashable {
    case interactive
    case bulk

    /// The lane the current task tree belongs to, `interactive` by default.
    ///
    /// A task local rather than a parameter on every fetch signature: the lane
    /// is a property of the CALLER's intent, and between that caller and
    /// `GmailQuotaBucket.consume` sit the provider seam, the batch chunker and
    /// the per-part retry round — six signatures that have no business knowing
    /// about pacing. Bulk callers scope it with `withBulkLane`; everything
    /// else inherits `interactive` and needs no change. `reserve`/`consume`
    /// still take an explicit `lane` (this value is only their default), so the
    /// bucket stays testable without a task tree.
    @TaskLocal public static var current: GmailQuotaLane = .interactive

    /// Run `body` with every quota reservation in its task tree paced on the
    /// BULK lane. Child tasks inherit it; `Task.detached` does not (by
    /// design — a detached ingest is not a fetch).
    /// `isolation: #isolation` so a caller that IS actor-isolated — the
    /// a `@MainActor` sync coordinator whose sliced listing runs on this lane
    /// — can pass a closure that stays in its own isolation domain instead of
    /// having to hand a `@Sendable` one across a boundary.
    /// `nonisolated(nonsending)`: see `GmailUnitCost.withKey`.
    nonisolated(nonsending)
    public static func withBulkLane<T>(
        _ body: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        try await $current.withValue(.bulk, operation: body)
    }
}

/// Per-account token buckets over the bucket's `GmailQuotaProfile`, with AIMD
/// adaptation from the server's rate signals.
///
/// Modelled as a virtual clock rather than a literal token count: each
/// reservation pushes the account's "next free instant" forward by
/// `units / rate`, and the caller sleeps until it. Equivalent to a bucket
/// refilling at the quota rate, but it never has to be woken to refill, and
/// the wait is computed in one hop so the actor is not held across a sleep.
///
/// A bucket is allowed to run one second behind the clock (`burstSeconds`),
/// which is the same one-second smoothing window Gmail meters over — an idle
/// account can therefore spend a full second of budget at once instead of
/// being paced from a standing start.
///
/// ## The AIMD invariant
///
/// `rate` for a key only ever moves two ways: HALVED (floor
/// `minimumRate`) the moment the server says we are over budget, and
/// raised by `recoveryFraction` of the profile ceiling per clean
/// `recoveryInterval`, never above the bucket's `profile.unitsPerSecond`.
/// A rate signal also parks the key until `now + cooldown`, so the first
/// reservation after a 403/429 wave waits out the per-minute quota window
/// instead of re-spending into it. Every paced caller — batch envelopes, the
/// per-part re-issue round, the full-sync leftover drain — goes through the
/// same object, so one account's backoff is shared rather than re-learned.
public actor GmailQuotaBucket {

    /// The process-wide bucket a default `GmailAPIClient()` debits. Built on
    /// first touch from the `configureShared` settings — `.current` and
    /// memory-only unless the host asked otherwise before that.
    public static var shared: GmailQuotaBucket { sharedConfig.resolve() }

    /// Choose the profile and persistence of `shared`. Call once at launch,
    /// before anything touches `shared` (a default `GmailAPIClient()` does).
    /// A second call, or one after `shared` was built, is ignored and
    /// reported as a fault — honouring it would leave clients already
    /// holding the old bucket metering against a different one.
    ///
    /// `shared` is built (and `stateStore.load()` runs) under a lock, so a
    /// store must never touch `GmailQuotaBucket.shared` itself.
    public static func configureShared(
        profile: GmailQuotaProfile = .current,
        stateStore: (any GmailQuotaStateStore)? = nil
    ) {
        sharedConfig.configure(profile: profile, stateStore: stateStore)
    }

    static let sharedConfig = SharedConfig()

    /// The lock-protected, configure-once settings behind `shared`. A type
    /// rather than bare statics so tests can exercise the ordering rules on
    /// an instance of their own instead of the process-wide one.
    final class SharedConfig: Sendable {
        private struct State {
            var profile = GmailQuotaProfile.current
            var stateStore: (any GmailQuotaStateStore)?
            var configured = false
            var built: GmailQuotaBucket?
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        /// Whether the settings were taken; false = ignored (and logged).
        @discardableResult
        func configure(profile: GmailQuotaProfile, stateStore: (any GmailQuotaStateStore)?) -> Bool {
            let accepted = state.withLock { s -> Bool in
                guard !s.configured, s.built == nil else { return false }
                s.profile = profile
                s.stateStore = stateStore
                s.configured = true
                return true
            }
            if !accepted {
                GmailQuotaBucket.logger.fault("configureShared called twice or after GmailQuotaBucket.shared was first used — ignored")
            }
            return accepted
        }

        /// The bucket, built from the settings on the first call.
        func resolve() -> GmailQuotaBucket {
            state.withLock { s in
                if let built = s.built { return built }
                let bucket = GmailQuotaBucket(profile: s.profile, stateStore: s.stateStore)
                s.built = bucket
                return bucket
            }
        }
    }

    public typealias NowProvider = @Sendable () -> Date
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    /// How far behind the wall clock a bucket may sit, i.e. the burst it can
    /// accumulate while idle. One second = one full second of quota.
    private static let burstSeconds: TimeInterval = 1.0

    /// How long a key is parked after a rate signal. Gmail's per-user quota is
    /// metered per MINUTE, so anything shorter re-enters the same exhausted
    /// window; a `Retry-After` from the server overrides this when it is longer.
    static let cooldown: TimeInterval = 60

    /// The rate never falls below this, however many signals arrive — at
    /// `messages.get` = 20 units it still buys one message every two seconds,
    /// which is a slow sync rather than a stalled one. A cap, not the floor
    /// itself: see `minimumRate(ceiling:)`.
    static let minimumUnitsPerSecond: Double = 10

    /// The floor for a profile whose ceiling is `ceiling`: `minimumUnitsPerSecond`,
    /// or a fifth of the ceiling when that is lower — so a slow profile (at
    /// or under 10 u/s) still backs off, and the floor never sits above the
    /// ceiling.
    static func minimumRate(ceiling: Double) -> Double {
        min(minimumUnitsPerSecond, ceiling * 0.2)
    }

    /// `minimumRate(ceiling:)` at this bucket's profile.
    nonisolated var minimumRate: Double { Self.minimumRate(ceiling: profile.unitsPerSecond) }

    /// Additive recovery: a clean interval adds this fraction of the profile
    /// ceiling back to the key's rate.
    static let recoveryFraction: Double = 0.10
    static let recoveryInterval: TimeInterval = 60

    /// A rate signal also leaves a CEILING HINT just under the rate that drew
    /// it (`limitHintFraction` of it): recovery climbs back to the hint, not
    /// to the profile ceiling, so the bucket settles where the server said
    /// the budget ends instead of sawtoothing into the same wall every few
    /// minutes. The hint itself relaxes upward by `recoveryFraction` of the
    /// profile ceiling per clean `hintRelaxInterval`, so a limit that was
    /// transient is re-probed slowly rather than remembered forever.
    static let limitHintFraction: Double = 0.9
    static let hintRelaxInterval: TimeInterval = 600

    /// The share of a key's rate the BULK lane paces itself against, per
    /// device, while nobody else is spending the account's budget.
    ///
    /// Gmail's 6,000 units/minute is per USER (t-a9825f81): every device on
    /// the account spends it and none can see the others. One device
    /// backfilling alone is the normal case, so the uncontended share stays
    /// 0.8 (40 u/s: a 134k-message re-ingest × 20 units ≈ 19 h, a 9k first
    /// window ≈ 1.3 h). Three devices at 0.8 ask for 120 u/s of 100; the
    /// first rate signal then drops each of them to
    /// `contendedBulkRateFraction` for `contentionHold` — see there.
    ///
    /// An interactive reservation is charged to the bulk clock AT THE BULK
    /// SHARE in force (see `reserve`), so a backfilling device spends no more
    /// than its share in total unless its interactive work alone exceeds it.
    static let bulkRateFraction: Double = 0.8

    /// The bulk share after a rate signal: "someone else is spending this
    /// budget — yield".
    ///
    /// 0.5 × 50 = 25 u/s per device, 75 u/s for `concurrentBulkDevices`
    /// together. The margin is not slack: bulk spends in whole envelopes
    /// (`bulkEnvelopeUnits`, 400 units), so what lands inside one minute is
    /// lumpy. At 25 u/s an envelope goes out every 16 s and no minute ever
    /// holds more than four per device — 3 × 1,600 = 4,800 of 6,000, leaving
    /// 1,200 units a minute for everyone's everyday quick syncs. At 0.6
    /// (30 u/s) a minute can hold five, 3 × 2,000 is the whole budget, and
    /// the first quick sync collides. A heavy interactive burst (a catch-up
    /// quick sync, a 2,000-unit `threads.get` envelope) can still draw a
    /// signal; the AIMD below handles it as before.
    ///
    /// Why not simply 0.5 always: it costs the lone device 37.5% of its
    /// speed (≈ 31 h for 134k) to avoid a collision that only happens when
    /// several devices backfill at once. Why not AIMD alone: halving and
    /// recovering at 0.8 re-probes into the wall every ~4 minutes, parking
    /// quick sync each time (`GmailQuotaSharedBudgetTests` policy report).
    ///
    /// The arithmetic above is for `GmailQuotaProfile.current` (50 u/s
    /// device, 100 u/s user, 400-unit envelopes). The fraction is applied
    /// unchanged to any other profile, where it still halves bulk but the
    /// envelope-per-minute margin is NOT re-derived: a profile with a much
    /// smaller user budget relative to its envelope size may collide sooner.
    static let contendedBulkRateFraction: Double = 0.5

    /// How long a device stays at the contended share after a rate signal.
    /// Each signal restarts it. Two hours: long enough that three devices
    /// backfilling together collide about once per hold rather than every
    /// few minutes, short enough that a device left alone gets its full
    /// share back the same afternoon. A 4th device, or a hold that expires
    /// mid-backfill, costs one more collision and re-arms it.
    static let contentionHold: TimeInterval = 2 * 60 * 60

    /// How many devices `bulkRateFraction` assumes are backfilling the same
    /// account at once — a Mac, an iPad and an iPhone.
    static let concurrentBulkDevices = 3

    /// The most quota one BULK batch envelope may carry: 20 `messages.get`.
    /// The arithmetic in `contendedBulkRateFraction` assumes lumps this size; a
    /// 50-part `.metadata` envelope (a fresh install's first window) is
    /// 1,000 units, and at 25 u/s two of them fit in one minute per device —
    /// 6,000 for three devices, the whole budget. Applied by
    /// `GmailBatchProtocol.maxOperations(for:unitCost:lane:bulkEnvelopeUnits:)`.
    static func bulkEnvelopeUnits(for profile: GmailQuotaProfile) -> Int { 20 * profile.messagesGetCost }

    /// `bulkEnvelopeUnits(for:)` at this bucket's profile.
    nonisolated var bulkEnvelopeUnits: Int { Self.bulkEnvelopeUnits(for: profile) }

    /// How long the key still counts as interactive-busy after an
    /// interactive reservation's slot, and after an interactive request ends
    /// (t-de5eebfb). The request itself is tracked explicitly
    /// (`beginInteractive` / `endInteractive` around the HTTP send); the grace
    /// covers the gap between the slot and the send (token resolution) and
    /// between one call of a quick sync and its next.
    static let interactiveInFlightGrace: TimeInterval = 1

    /// How often a yielding bulk waiter re-checks while an interactive
    /// request is in flight (its end time is unknown until it ends).
    static let yieldPollInterval: TimeInterval = 0.25

    /// The longest cooldown a rate signal may install, live or restored.
    ///
    /// Gmail's per-user quota is metered per MINUTE, so a `Retry-After` of an
    /// hour (seen on a single call, or a daily-quota answer) says more than
    /// the pacing can use: honoured verbatim it parks BOTH lanes — the inbox
    /// included — for the whole hour, and persists that across a relaunch.
    /// Ten minutes is ten quota windows: long enough that re-probing costs at
    /// most one call per ten minutes if the limit really is longer (the next
    /// signal re-parks), short enough that a person is never locked out of
    /// their inbox for an hour on one header. The restored clamp is the same
    /// value so a live park and a relaunched one agree.
    static let maxPause: TimeInterval = 10 * 60
    static var maxRestoredPause: TimeInterval { maxPause }

    /// How far a repeat signal must move the park past the SAVED one before
    /// the state is written again (see `noteRateLimited`).
    static let persistSlack: TimeInterval = 30

    /// The most one bulk `consume` will yield to interactive work before it
    /// goes out anyway — the starvation bound. Interactive bursts are short
    /// (a quick sync is seconds); a stream of them longer than this still lets
    /// bulk through one envelope per `maxBulkYield`.
    static let maxBulkYield: TimeInterval = 20

    /// At most one "bulk yielding" log line per key per this interval.
    static let yieldLogInterval: TimeInterval = 60

    /// Per-key pacing state. Internal (not private) only so the bucket's
    /// extensions in sibling files can reach it.
    struct Bucket {
        /// The interactive lane's virtual clock. Advanced only by interactive
        /// reservations (and by a rate signal's park), which is what keeps a
        /// person-facing fetch off the back of the bulk queue.
        var nextFreeInteractive: Date?
        /// The bulk lane's virtual clock. Advanced by bulk reservations AND by
        /// interactive ones, so the two lanes share the rate ceiling.
        var nextFreeBulk: Date?
        /// nil = never signalled, so the key runs at the profile ceiling.
        var rate: Double?
        var lastRecovered: Date?
        /// The end of the current cooldown. A signal that arrives before it
        /// is the tail of a batch that was already in flight when we parked —
        /// it carries no new information and must not halve the rate again.
        var pausedUntil: Date?
        /// Recovery target, nil = the profile ceiling.
        var limitHint: Double?
        var hintRelaxedAt: Date?
        /// Until when the bulk lane runs at the contended share.
        var contendedUntil: Date?
        /// Until when an interactive reservation is waiting for its slot, or
        /// an ended interactive request's grace runs. Bulk consumers for the
        /// key yield while it is in the future or `interactiveInFlight > 0`,
        /// up to `maxBulkYield`.
        var interactiveBusyUntil: Date?
        /// Interactive HTTP requests for the key currently on the wire.
        var interactiveInFlight = 0
        /// When the next yielded bulk waiter may go: waiters released by the
        /// same interactive burst are spaced `units / bulkRate` apart instead
        /// of all dispatching the instant interactive clears.
        var bulkReleaseAt: Date?
        /// Rate-limits the "bulk yielding" notice.
        var lastYieldLog: Date?
        /// Set when the state was RESTORED from a previous launch: yesterday's
        /// signal throttles the bulk lane only, and interactive paces at the
        /// ceiling hint rather than the restored AIMD rate (and is not parked).
        /// Cleared by the first rate signal of this session.
        var restoredBulkOnly = false
    }

    /// The tunable half of the pacing — what share bulk takes, and whether a
    /// rate signal parks the interactive lane too. One value per bucket so a
    /// test can compare policies side by side; production uses `shipped`.
    public struct Policy: Sendable, Equatable {
        /// See `GmailQuotaBucket.bulkRateFraction`.
        var bulkRateFraction: Double
        /// true: a rate signal halves the key's rate for BOTH lanes and parks
        /// both clocks. false: the AIMD rate and the park apply to the BULK
        /// lane only; interactive always paces at the profile ceiling on its
        /// own clock and is never parked.
        var signalsThrottleInteractive: Bool
        /// When set, a rate signal drops the bulk share to this fraction for
        /// `contentionHold` — "someone else is spending this budget, yield".
        var contendedBulkRateFraction: Double? = nil
        var contentionHold: TimeInterval = 0
        /// See `GmailQuotaBucket.interactiveInFlightGrace`.
        var interactiveInFlightGrace: TimeInterval = GmailQuotaBucket.interactiveInFlightGrace
        /// See `GmailQuotaBucket.maxBulkYield`. 0 disables the yield.
        var maxBulkYield: TimeInterval = GmailQuotaBucket.maxBulkYield
        /// See `GmailQuotaBucket.yieldPollInterval`.
        var yieldPollInterval: TimeInterval = GmailQuotaBucket.yieldPollInterval

        public static let shipped = Policy(
            bulkRateFraction: GmailQuotaBucket.bulkRateFraction,
            signalsThrottleInteractive: true,
            contendedBulkRateFraction: GmailQuotaBucket.contendedBulkRateFraction,
            contentionHold: GmailQuotaBucket.contentionHold
        )
    }

    // Internal (not private) only for the sibling-file extensions.
    var buckets: [String: Bucket] = [:]
    /// What the state store holds, per key — each entry stamped when THAT
    /// key last changed, so one key's write never re-dates another's.
    var persisted: [String: GmailQuotaPersistedKey] = [:]

    nonisolated let policy: Policy
    /// The rates and unit costs this bucket (and every client debiting it)
    /// meters against.
    public nonisolated let profile: GmailQuotaProfile
    nonisolated let now: NowProvider
    nonisolated let sleeper: Sleeper
    nonisolated let stateStore: (any GmailQuotaStateStore)?

    static let logger = GmailLogging.logger(category: "GmailQuotaBucket")
    var logger: Logger { Self.logger }

    /// - Parameters:
    ///   - now: clock seam. Tests pass a virtual clock so a 60 s cooldown is
    ///     asserted without a 60 s test.
    ///   - sleeper: how a paced caller waits. Tests advance the virtual clock
    ///     here instead of sleeping.
    ///   - policy: the pacing policy; tests compare alternatives with it.
    ///   - profile: the project's quota profile — the AIMD ceiling and the
    ///     unit costs clients debit.
    ///   - stateStore: where the contention hold and AIMD rate persist across
    ///     launches. nil (the default) = memory only; `shared` uses whatever
    ///     `configureShared` was given.
    public init(
        now: @escaping NowProvider = { Date() },
        sleeper: Sleeper? = nil,
        policy: Policy = .shipped,
        profile: GmailQuotaProfile = .current,
        stateStore: (any GmailQuotaStateStore)? = nil
    ) {
        self.policy = policy
        self.profile = profile
        self.now = now
        self.sleeper = sleeper ?? { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        self.stateStore = stateStore
        let restored = Self.restore(from: stateStore, now: now(), policy: policy, ceiling: profile.unitsPerSecond)
        self.buckets = restored.buckets
        self.persisted = restored.persisted
    }

    /// The rate `key` is currently paced at. Exposed for tests and for the
    /// log line that explains a slow sync.
    public func rate(for key: String) -> Double {
        buckets[key]?.rate ?? profile.unitsPerSecond
    }

    /// Debit `units` for `key` in `lane` and return how long the caller must
    /// wait before spending them. Never negative.
    ///
    /// The two lanes share one rate (and one AIMD state) but keep separate
    /// virtual clocks:
    ///
    /// - An `interactive` reservation is placed on the interactive clock at the
    ///   key's FULL rate, and it also pushes the bulk clock by what the same
    ///   units cost AT THE BULK RATE — bulk gives up exactly the units
    ///   interactive spent. So it jumps ahead of everything bulk has queued,
    ///   and a backfilling device's total stays inside its bulk share.
    /// - A `bulk` reservation is placed on the bulk clock at the bulk share
    ///   (`bulkRateFraction`, or the contended one) × rate and NEVER touches the interactive clock —
    ///   which is the whole invariant: however long the backfill queue grows,
    ///   the next interactive reservation waits at most its own
    ///   `units / rate`.
    ///
    /// - Parameter parkable: false for a request a person is actively waiting
    ///   on to SEND mail (`messages.send`). It is charged like any interactive
    ///   reservation — both clocks move, so bulk backs off — but it is never
    ///   held behind a cooldown park or the interactive queue: it dispatches
    ///   now and leaves retries to `withRetry`'s own short backoff.
    func reserve(
        units: Int,
        key: String,
        lane: GmailQuotaLane = .interactive,
        parkable: Bool = true
    ) -> TimeInterval {
        let instant = now()
        recoverIfDue(key: key, at: instant)

        var bucket = buckets[key] ?? Bucket()
        let rate = bucket.rate ?? profile.unitsPerSecond
        let floor = instant.addingTimeInterval(-Self.burstSeconds)
        // A bucket that has never spent starts AT `instant`, not at the floor:
        // the burst is credit an account earns by being idle, not a free
        // second handed to the first caller on top of its own reservation.
        let laneClock = lane == .bulk ? bucket.nextFreeBulk : bucket.nextFreeInteractive
        let queued = max(laneClock ?? instant, floor)
        // An unparkable send goes NOW; the lane clock is still pushed out by
        // its units below (from where it stood), never dragged backwards.
        let unparked = lane == .interactive && !parkable
        let start = unparked ? max(instant, floor) : queued
        let bulkDuration = Double(units) / bulkRate(of: bucket, at: instant)
        // Under a bulk-only policy the AIMD rate is the bulk lane's alone; a
        // restored state is the bulk lane's alone too, until this session's
        // own first signal (interactive then paces at the ceiling hint).
        let ceiling = profile.unitsPerSecond
        let interactiveRate: Double
        if !policy.signalsThrottleInteractive {
            interactiveRate = ceiling
        } else if bucket.restoredBulkOnly {
            interactiveRate = min(ceiling, bucket.limitHint ?? ceiling)
        } else {
            interactiveRate = rate
        }

        switch lane {
        case .bulk:
            bucket.nextFreeBulk = start.addingTimeInterval(bulkDuration)
        case .interactive:
            bucket.nextFreeInteractive = queued.addingTimeInterval(Double(units) / interactiveRate)
            // Waiting for its slot, then in flight: bulk yields until both pass.
            let busy = start.addingTimeInterval(policy.interactiveInFlightGrace)
            bucket.interactiveBusyUntil = max(bucket.interactiveBusyUntil ?? busy, busy)
            // Charge the bulk lane for what interactive just spent, at the
            // bulk rate: bulk forgoes exactly these units, so a backfilling
            // device stays inside its share of the per-user budget. Bulk is
            // DELAYED by it, never dragged backwards.
            let bulkStart = max(bucket.nextFreeBulk ?? instant, floor)
            bucket.nextFreeBulk = bulkStart.addingTimeInterval(bulkDuration)
        }
        buckets[key] = bucket
        return max(0, start.timeIntervalSince(instant))
    }

    /// The bulk lane's rate for `bucket` at `instant`: the AIMD rate times
    /// the bulk share — the contended share while the hold runs.
    func bulkRate(of bucket: Bucket, at instant: Date) -> Double {
        let rate = bucket.rate ?? profile.unitsPerSecond
        let contended = policy.contendedBulkRateFraction.flatMap { fraction in
            (bucket.contendedUntil.map { instant < $0 } ?? false) ? fraction : nil
        }
        return rate * (contended ?? policy.bulkRateFraction)
    }

    /// Record a server rate signal (HTTP 429, or a 403 whose body carries a
    /// rate/quota reason) for `key`: park it for a cooldown and halve its rate.
    ///
    /// - Parameter retryAfter: the value of a `Retry-After` header, when the
    ///   response carried one. Honoured when it is longer than the cooldown.
    public func noteRateLimited(key: String, retryAfter: TimeInterval? = nil) {
        let instant = now()
        var bucket = buckets[key] ?? Bucket()
        let ceiling = profile.unitsPerSecond
        let previous = bucket.rate ?? ceiling
        let pause = min(Self.maxPause, max(Self.cooldown, retryAfter ?? 0))
        if policy.contendedBulkRateFraction != nil {
            bucket.contendedUntil = instant.addingTimeInterval(policy.contentionHold)
        }
        // A signal THIS session: the account is contended now, so the shipped
        // both-lanes throttle applies again.
        bucket.restoredBulkOnly = false

        if let pausedUntil = bucket.pausedUntil, instant < pausedUntil {
            // Already throttled for this window; the in-flight batch that
            // produced this signal was dispatched before the park. Keep the
            // park (extend it if the server asked for longer) and change nothing else.
            bucket.pausedUntil = max(pausedUntil, instant.addingTimeInterval(pause))
            let parkedUntil = bucket.pausedUntil ?? instant
            if policy.signalsThrottleInteractive {
                bucket.nextFreeInteractive = max(bucket.nextFreeInteractive ?? instant, parkedUntil)
            }
            bucket.nextFreeBulk = max(bucket.nextFreeBulk ?? instant, parkedUntil)
            buckets[key] = bucket
            // Only when the park MOVED beyond what is already saved: the
            // per-id fallback can draw a 429 per id inside one cooldown, each
            // nudging the park (and the re-armed hold) forward by seconds.
            // Rewriting UserDefaults for that is not worth it — a relaunch
            // that loses a few seconds of park is harmless — so a storm costs
            // at most one write per `persistSlack`.
            let saved = persisted[key]?.pausedUntil ?? .distantPast
            if parkedUntil.timeIntervalSince(saved) > Self.persistSlack { persist(key: key) }
            logger.info("Gmail quota: rate signal for \(key, privacy: .public) during cooldown — already paced at \(String(format: "%.0f", previous), privacy: .public) u/s, not halving again")
            return
        }

        let halved = max(minimumRate, previous / 2)
        bucket.rate = halved
        bucket.lastRecovered = instant
        bucket.pausedUntil = instant.addingTimeInterval(pause)
        bucket.limitHint = max(minimumRate, min(ceiling, previous * Self.limitHintFraction))
        bucket.hintRelaxedAt = instant
        // Park the key: the next reservation waits out the quota window, and
        // anything already queued past that point keeps its later slot.
        let parkedUntil = instant.addingTimeInterval(pause)
        if policy.signalsThrottleInteractive {
            bucket.nextFreeInteractive = max(bucket.nextFreeInteractive ?? instant, parkedUntil)
        }
        bucket.nextFreeBulk = max(bucket.nextFreeBulk ?? instant, parkedUntil)
        buckets[key] = bucket
        persist(key: key)

        logger.warning(
            "Gmail quota: rate signal for \(key, privacy: .public) — pacing \(String(format: "%.0f", previous), privacy: .public) → \(String(format: "%.0f", halved), privacy: .public) u/s, paused \(String(format: "%.0f", pause), privacy: .public)s"
        )
    }

    /// Record a clean spend for `key`. Recovery is time-based, not call-based,
    /// so a burst of successes does not walk the rate back up in one pass.
    public func noteSuccess(key: String) {
        recoverIfDue(key: key, at: now())
    }

    /// Drop a bucket's state (tests, and account removal).
    public func reset(key: String? = nil) {
        if let key {
            buckets[key] = nil
            persist(key: key)
        } else {
            let keys = Array(buckets.keys) + Array(persisted.keys)
            buckets.removeAll()
            for key in Set(keys) { persist(key: key) }
        }
    }

    /// Additive increase: one step of `recoveryFraction × ceiling` per clean
    /// `recoveryInterval`, capped at the ceiling. A key that has never been
    /// signalled has no rate of its own and needs no recovery.
    private func recoverIfDue(key: String, at instant: Date) {
        let before = (buckets[key]?.rate, buckets[key]?.limitHint)
        applyRecovery(key: key, at: instant)
        if buckets[key]?.rate != before.0 || buckets[key]?.limitHint != before.1 { persist(key: key) }
    }

    private func applyRecovery(key: String, at instant: Date) {
        guard var bucket = buckets[key], let rate = bucket.rate else { return }
        let ceiling = profile.unitsPerSecond
        relaxHintIfDue(&bucket, at: instant, ceiling: ceiling)
        let target = min(ceiling, bucket.limitHint ?? ceiling)
        guard rate < target else {
            // At the target. Only a target AT the profile ceiling means the
            // key is back to unsignalled; a hint keeps its own rate.
            if bucket.limitHint == nil {
                bucket.rate = nil
                bucket.lastRecovered = nil
            } else {
                bucket.rate = target
            }
            buckets[key] = bucket
            return
        }
        guard let last = bucket.lastRecovered else {
            bucket.lastRecovered = instant
            buckets[key] = bucket
            return
        }
        let elapsed = instant.timeIntervalSince(last)
        guard elapsed >= Self.recoveryInterval else { return }
        let steps = (elapsed / Self.recoveryInterval).rounded(.down)
        let raised = min(target, rate + steps * Self.recoveryFraction * ceiling)
        let atCeiling = raised >= ceiling && bucket.limitHint == nil
        bucket.rate = atCeiling ? nil : raised
        bucket.lastRecovered = atCeiling ? nil : last.addingTimeInterval(steps * Self.recoveryInterval)
        buckets[key] = bucket
    }

    /// The ceiling hint relaxes upward one `recoveryFraction × ceiling` step
    /// per clean `hintRelaxInterval`, and clears once it reaches the ceiling.
    private func relaxHintIfDue(_ bucket: inout Bucket, at instant: Date, ceiling: Double) {
        guard let hint = bucket.limitHint, let since = bucket.hintRelaxedAt else { return }
        let elapsed = instant.timeIntervalSince(since)
        guard elapsed >= Self.hintRelaxInterval else { return }
        let steps = (elapsed / Self.hintRelaxInterval).rounded(.down)
        let relaxed = hint + steps * Self.recoveryFraction * ceiling
        if relaxed >= ceiling {
            bucket.limitHint = nil
            bucket.hintRelaxedAt = nil
        } else {
            bucket.limitHint = relaxed
            bucket.hintRelaxedAt = since.addingTimeInterval(steps * Self.hintRelaxInterval)
        }
    }

    /// Reserve, then wait out the reservation. The sleep happens OUTSIDE the
    /// actor (this method is `nonisolated`), so one paced account never blocks
    /// another's reservation.
    nonisolated func consume(
        units: Int,
        key: String,
        lane: GmailQuotaLane = GmailQuotaLane.current,
        parkable: Bool = true
    ) async throws {
        let wait = await reserve(units: units, key: key, lane: lane, parkable: parkable)
        if wait > 0 { try await sleeper(wait) }
        if lane == .bulk { try await yieldToInteractive(units: units, key: key) }
    }

    /// Convenience for the process-wide bucket.
    static func consume(
        units: Int,
        key: String,
        lane: GmailQuotaLane = GmailQuotaLane.current
    ) async throws {
        try await shared.consume(units: units, key: key, lane: lane)
    }
}
