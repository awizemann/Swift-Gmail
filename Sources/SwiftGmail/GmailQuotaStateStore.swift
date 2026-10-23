//
//  GmailQuotaStateStore.swift
//  SwiftGmail
//
//  What `GmailQuotaBucket` remembers across launches (t-e817c15c).
//
//  The bucket's contention hold and AIMD state used to live only in memory,
//  so a relaunch inside the two-hour contention window forgot that another
//  device was spending the account's per-user budget and probed at the full
//  lone-device share again — the 2026-10-05 device log shows exactly that: an
//  app open, a paced history backfill at 0.8, and a rate signal 40 s later,
//  just before the inbox quick sync. Persisting the state lets a fresh
//  bucket resume where the last one left off.
//
//  Device-local (UserDefaults), never synced: contention is something THIS
//  device learned from the server, and the hold is short-lived.
//

import Foundation

/// One quota key's remembered pacing state.
public struct GmailQuotaPersistedKey: Codable, Sendable, Equatable {
    /// Until when the bulk lane runs at the contended share. nil = no hold.
    var contendedUntil: Date?
    /// The AIMD rate in force when saved. nil = the profile ceiling.
    var rate: Double?
    /// The AIMD recovery origin for `rate` — so time spent closed counts as
    /// clean recovery time, measured from THIS key's last step.
    var lastRecovered: Date?
    /// The recovery ceiling hint a signal left, and when it last relaxed.
    var limitHint: Double?
    var hintRelaxedAt: Date?
    /// The end of the cooldown a signal installed.
    var pausedUntil: Date?
    /// When THIS key's state last changed — the skew guard and the eviction
    /// order. Never re-stamped by another key's write.
    var savedAt: Date

    init(
        contendedUntil: Date? = nil,
        rate: Double? = nil,
        lastRecovered: Date? = nil,
        limitHint: Double? = nil,
        hintRelaxedAt: Date? = nil,
        pausedUntil: Date? = nil,
        savedAt: Date
    ) {
        self.contendedUntil = contendedUntil
        self.rate = rate
        self.lastRecovered = lastRecovered
        self.limitHint = limitHint
        self.hintRelaxedAt = hintRelaxedAt
        self.pausedUntil = pausedUntil
        self.savedAt = savedAt
    }

    /// Lenient decode: a missing or mistyped field becomes nil instead of
    /// failing the whole map (a future build that adds or renames a field must
    /// not cost every key its state). Only `savedAt` is required.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contendedUntil = try? container.decodeIfPresent(Date.self, forKey: .contendedUntil)
        rate = try? container.decodeIfPresent(Double.self, forKey: .rate)
        lastRecovered = try? container.decodeIfPresent(Date.self, forKey: .lastRecovered)
        limitHint = try? container.decodeIfPresent(Double.self, forKey: .limitHint)
        hintRelaxedAt = try? container.decodeIfPresent(Date.self, forKey: .hintRelaxedAt)
        pausedUntil = try? container.decodeIfPresent(Date.self, forKey: .pausedUntil)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
    }

    /// True when nothing in the entry is worth keeping.
    var isEmpty: Bool {
        contendedUntil == nil && rate == nil && limitHint == nil && pausedUntil == nil
    }
}

/// Where `GmailQuotaBucket` keeps its cross-launch state. Injectable so tests
/// never touch `UserDefaults.standard`.
public protocol GmailQuotaStateStore: Sendable {
    func load() -> [String: GmailQuotaPersistedKey]
    func save(_ state: [String: GmailQuotaPersistedKey])
}

/// UserDefaults-backed store: one JSON blob, the bucket keys as its keys.
public struct UserDefaultsGmailQuotaStateStore: GmailQuotaStateStore, @unchecked Sendable {

    public static let userDefaultsKey = "SwiftGmail.quotaBucketState"

    /// Most keys remembered — one per Gmail account plus the setup-time
    /// default key. Past this, the keys whose state changed longest ago go.
    static let maxKeys = 16

    // `UserDefaults` is documented thread-safe but the SDK does not mark it
    // Sendable (verified on the macOS 15 / Xcode 27 SDK), so the conformance
    // is unchecked. The only other stored property is a `String`.
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = Self.userDefaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [String: GmailQuotaPersistedKey] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        // Decode entry by entry so one corrupt entry drops alone.
        guard let raw = try? JSONDecoder().decode([String: LenientEntry].self, from: data) else {
            return [:]
        }
        return raw.compactMapValues(\.value)
    }

    public func save(_ state: [String: GmailQuotaPersistedKey]) {
        guard !state.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        let bounded = state.count <= Self.maxKeys
            ? state
            : Dictionary(
                uniqueKeysWithValues: state
                    .sorted { $0.value.savedAt > $1.value.savedAt }
                    .prefix(Self.maxKeys)
                    .map { ($0.key, $0.value) }
            )
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        defaults.set(data, forKey: key)
    }

    /// Wraps one entry so a value that fails to decode becomes nil rather
    /// than throwing out the whole map.
    private struct LenientEntry: Decodable {
        let value: GmailQuotaPersistedKey?
        init(from decoder: Decoder) throws {
            value = try? GmailQuotaPersistedKey(from: decoder)
        }
    }
}

extension GmailQuotaPersistedKey {

    /// How far in the future an entry's `savedAt` may sit before the entry is
    /// treated as written by a skewed clock and ignored.
    static let clockSkewTolerance: TimeInterval = 5 * 60

    /// The entry as it may safely be applied at `now`, or nil when nothing in
    /// it is still worth restoring.
    ///
    /// - A `savedAt` in the future beyond `clockSkewTolerance` means the clock
    ///   that wrote it (or the one reading it) is wrong — ignore the entry.
    /// - `contendedUntil` / `pausedUntil` already past are dropped; one
    ///   further out than `now + hold` / `now + maxPause` is clamped to it.
    /// - `rate` and `limitHint` are clamped into `[minimum, ceiling]`; at the
    ///   ceiling they are nil. Origins in the future are pulled back to `now`.
    func sanitized(
        now: Date,
        hold: TimeInterval,
        maxPause: TimeInterval,
        minimumRate: Double,
        ceiling: Double
    ) -> GmailQuotaPersistedKey? {
        guard savedAt.timeIntervalSince(now) <= Self.clockSkewTolerance else { return nil }
        let stamped = min(savedAt, now)
        func until(_ date: Date?, within window: TimeInterval) -> Date? {
            guard let date, date > now else { return nil }
            return min(date, now.addingTimeInterval(window))
        }
        func clampRate(_ value: Double?) -> Double? {
            guard let value, value.isFinite else { return nil }
            let clamped = min(ceiling, max(minimumRate, value))
            return clamped >= ceiling ? nil : clamped
        }
        func origin(_ date: Date?) -> Date { min(date ?? stamped, now) }

        let rate = clampRate(rate)
        let hint = clampRate(limitHint)
        let entry = GmailQuotaPersistedKey(
            contendedUntil: until(contendedUntil, within: hold),
            rate: rate,
            lastRecovered: rate == nil ? nil : origin(lastRecovered),
            limitHint: hint,
            hintRelaxedAt: hint == nil ? nil : origin(hintRelaxedAt),
            pausedUntil: until(pausedUntil, within: maxPause),
            savedAt: stamped
        )
        return entry.isEmpty ? nil : entry
    }
}

/// Whether this process is a test runner — the shared bucket must not persist
/// into `UserDefaults.standard` from one.
enum GmailQuotaProcess {
    static let isTestProcess: Bool = {
        let info = ProcessInfo.processInfo
        if info.environment["XCTestConfigurationFilePath"] != nil { return true }
        if info.environment["XCTestBundlePath"] != nil { return true }
        let name = info.processName
        if name == "xctest" || name.contains("swiftpm-testing-helper") || name.hasSuffix("PackageTests") { return true }
        return NSClassFromString("XCTestCase") != nil
    }()
}
