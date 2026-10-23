import Foundation
import Testing
@testable import SwiftGmail

/// The unit-cost table, and the two task locals that decide WHICH bucket a
/// call debits and at what priority.
///
/// The incident (t-924d2830): only the two batch envelopes were metered.
/// `messages.list`, `history.list`, `getProfile` and — worst — `attachments.get`
/// spent real quota the bucket never saw, so its AIMD loop reported a rate it
/// was not holding and a 16,603-row attachment sweep starved the backfill it
/// was running beside.
@Suite("Gmail quota — unit costs and metering scope")
struct GmailUnitCostTests {

    // MARK: The table

    /// Verbatim against Google's published "Usage limits" page for the Gmail
    /// API, read 2026-09-12:
    /// https://developers.google.com/workspace/gmail/api/reference/quota
    ///
    /// This test is the citation. If Google restates the table, this is the
    /// one place that has to change — every call site reads
    /// `GmailQuotaProfile.active.unitCost` rather than a literal.
    @Test(
        "Every metered method's cost matches Google's documented table",
        arguments: [
            ("getProfile", GmailUnitCost.documented.getProfile, 1),
            ("labels.list", GmailUnitCost.documented.labelsList, 1),
            ("history.list", GmailUnitCost.documented.historyList, 2),
            ("messages.list", GmailUnitCost.documented.messagesList, 5),
            ("messages.modify", GmailUnitCost.documented.messagesModify, 5),
            ("messages.untrash", GmailUnitCost.documented.messagesUntrash, 5),
            ("drafts.list", GmailUnitCost.documented.draftsList, 5),
            ("drafts.create", GmailUnitCost.documented.draftsCreate, 10),
            ("drafts.delete", GmailUnitCost.documented.draftsDelete, 10),
            ("messages.delete", GmailUnitCost.documented.messagesDelete, 10),
            ("threads.list", GmailUnitCost.documented.threadsList, 10),
            ("drafts.update", GmailUnitCost.documented.draftsUpdate, 15),
            ("messages.get", GmailUnitCost.documented.messagesGet, 20),
            ("messages.trash", GmailUnitCost.documented.messagesTrash, 20),
            ("messages.attachments.get", GmailUnitCost.documented.attachmentsGet, 20),
            ("threads.get", GmailUnitCost.documented.threadsGet, 40),
            ("messages.batchModify", GmailUnitCost.documented.messagesBatchModify, 50),
            ("messages.send", GmailUnitCost.documented.messagesSend, 100)
        ] as [(String, Int, Int)]
    )
    func documentedCosts(method: String, actual: Int, expected: Int) {
        #expect(actual == expected, "\(method) should cost \(expected) units")
    }

    /// The number the whole task turns on. An attachment fetch is as expensive
    /// as a full message fetch — not the 5 the legacy table documented — so
    /// 16,603 eager downloads were ~332,000 units, not ~83,000.
    @Test("attachments.get costs as much as a full messages.get")
    func attachmentGetIsExpensive() {
        #expect(GmailUnitCost.documented.attachmentsGet == GmailUnitCost.documented.messagesGet)
        #expect(GmailUnitCost.documented.attachmentsGet == 20)
    }

    /// The batch envelopes price themselves off the profile, and the profile
    /// now reads the table — so there is exactly one source of truth and it
    /// cannot drift.
    @Test("The profile's batch costs are derived from the table, not duplicated")
    func profileDerivesFromTable() {
        #expect(GmailQuotaProfile.current.messagesGetCost == GmailUnitCost.documented.messagesGet)
        #expect(GmailQuotaProfile.current.threadsGetCost == GmailUnitCost.documented.threadsGet)
        #expect(GmailQuotaProfile.legacy.messagesGetCost == GmailUnitCost.legacy.messagesGet)
        #expect(GmailQuotaProfile.legacy.messagesGetCost == 5, "the legacy profile's cheap messages.get")
    }

    // MARK: Lane inheritance

    @Test("A metered call inherits the caller's lane — bulk inside withBulkLane")
    func laneIsInherited() async {
        #expect(GmailQuotaLane.current == .interactive, "interactive is the default")

        await GmailQuotaLane.withBulkLane {
            #expect(GmailQuotaLane.current == .bulk)
            // A child task inherits it — this is what lets the lane cross the
            // provider seam, the batch chunker and the retry round without
            // appearing in any of their signatures.
            await withTaskGroup(of: GmailQuotaLane.self) { group in
                group.addTask { GmailQuotaLane.current }
                for await lane in group { #expect(lane == .bulk) }
            }
        }

        #expect(GmailQuotaLane.current == .interactive, "the scope does not leak out")
    }

    /// A bulk reservation must actually pace SLOWER than an interactive one of
    /// the same size — that is what leaves headroom for the person-facing lane.
    @Test("Bulk and interactive reservations of one call differ by bulkRateFraction")
    func bulkPacesSlower() async {
        let clock = VirtualClock()
        let bucket = clock.bucket()
        let cost = GmailUnitCost.documented.attachmentsGet
        let rate = GmailQuotaProfile.active.unitsPerSecond

        // Two reservations on each lane; the SECOND is the one that waits,
        // because the first consumes the idle burst.
        _ = await bucket.reserve(units: cost, key: "a", lane: .interactive)
        let interactive = await bucket.reserve(units: cost, key: "a", lane: .interactive)
        _ = await bucket.reserve(units: cost, key: "b", lane: .bulk)
        let bulk = await bucket.reserve(units: cost, key: "b", lane: .bulk)

        #expect(abs(interactive - Double(cost) / rate) < 0.001)
        #expect(
            abs(bulk - Double(cost) / (rate * GmailQuotaBucket.bulkRateFraction)) < 0.001,
            "bulk paces at bulkRateFraction of the rate"
        )
        #expect(bulk > interactive)
    }

    // MARK: Quota key scope

    @Test("An unkeyed call meters against the shared key; withKey scopes it per account")
    func quotaKeyScope() async {
        #expect(GmailQuotaScope.current == GmailAPIClient.sharedQuotaKey)

        let accountKey = UUID().uuidString
        await GmailQuotaScope.withKey(accountKey) {
            #expect(GmailQuotaScope.current == accountKey)
            // The action drain's per-row work runs in child tasks; the key has
            // to reach them or a drain would meter against the shared bucket.
            await withTaskGroup(of: String.self) { group in
                group.addTask { GmailQuotaScope.current }
                for await key in group { #expect(key == accountKey) }
            }
        }

        #expect(GmailQuotaScope.current == GmailAPIClient.sharedQuotaKey, "the scope does not leak out")
    }

    /// Two accounts must not share a budget: the per-user quota is per user.
    @Test("Separate keys keep separate clocks")
    func keysAreIndependent() async {
        let clock = VirtualClock()
        let bucket = clock.bucket()
        let cost = GmailUnitCost.documented.messagesSend

        // Spend a lot on one key.
        for _ in 0..<20 { _ = await bucket.reserve(units: cost, key: "account-a") }
        let a = await bucket.reserve(units: cost, key: "account-a")
        let b = await bucket.reserve(units: cost, key: "account-b")

        #expect(a > 1, "account-a has queued a real backlog (\(a)s)")
        #expect(b == 0, "account-b has spent nothing and pays nothing")
    }
}

/// Virtual clock so a rate-limited bucket is asserted without a real wait.
final class VirtualClock: @unchecked Sendable {
    private(set) var now = Date(timeIntervalSince1970: 1_700_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    func bucket() -> GmailQuotaBucket {
        GmailQuotaBucket(now: { [self] in now }, sleeper: { [self] s in advance(s) })
    }
}
