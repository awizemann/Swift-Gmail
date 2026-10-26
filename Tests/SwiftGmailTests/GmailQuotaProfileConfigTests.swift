import Foundation
import Testing
import os
@testable import SwiftGmail

/// A consumer picks its own quota profile per bucket, and `shared` takes its
/// profile and persistence from `configureShared` — once, before first use.
@Suite("GmailQuotaBucket — injected profile and configureShared")
struct GmailQuotaProfileConfigTests {

    private final class VirtualClock: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_700_000_000))
        var now: Date { state.withLock { $0 } }
        var elapsed: TimeInterval { now.timeIntervalSince1970 - 1_700_000_000 }
        func advance(_ seconds: TimeInterval) { state.withLock { $0 += seconds } }
    }

    /// 10 u/s with a `getProfile` that costs 30 — far enough from `.current`
    /// (50 u/s, cost 1) that reading the wrong profile cannot pass.
    private static let slow: GmailQuotaProfile = {
        let d = GmailUnitCost.documented
        let cost = GmailUnitCost(
            getProfile: 30, labelsList: d.labelsList, historyList: d.historyList,
            messagesList: d.messagesList, messagesGet: 2, messagesModify: d.messagesModify,
            messagesTrash: d.messagesTrash, messagesUntrash: d.messagesUntrash,
            messagesDelete: d.messagesDelete, messagesBatchModify: d.messagesBatchModify,
            messagesSend: d.messagesSend, attachmentsGet: d.attachmentsGet,
            threadsList: d.threadsList, threadsGet: d.threadsGet, draftsList: d.draftsList,
            draftsCreate: d.draftsCreate, draftsUpdate: d.draftsUpdate, draftsDelete: d.draftsDelete,
            draftsGet: d.draftsGet, draftsSend: d.draftsSend, labelsCreate: d.labelsCreate, labelsGet: d.labelsGet
        )
        return GmailQuotaProfile(unitsPerSecond: 10, perUserUnitsPerSecond: 20, unitCost: cost)
    }()

    private static func bucket(_ clock: VirtualClock, profile: GmailQuotaProfile) -> GmailQuotaBucket {
        GmailQuotaBucket(
            now: { clock.now },
            sleeper: { clock.advance($0) },
            profile: profile
        )
    }

    private static let profileTransport: GmailAPIClient.Transport = { request in
        let body = Data(#"{"emailAddress":"a@example.com","historyId":"1"}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }

    @Test("A custom profile sets the pacing rate: the same debits wait 5x longer at 10 u/s than at 50")
    func customProfilePaces() async {
        let slow = Self.bucket(VirtualClock(), profile: Self.slow)
        let fast = Self.bucket(VirtualClock(), profile: .current)

        #expect(await slow.rate(for: "k") == 10)
        _ = await slow.reserve(units: 20, key: "k")
        _ = await fast.reserve(units: 20, key: "k")
        let slowWait = await slow.reserve(units: 20, key: "k")
        let fastWait = await fast.reserve(units: 20, key: "k")

        #expect(slowWait > 0)
        #expect(abs(slowWait - 5 * fastWait) < 0.001, "slow \(slowWait)s vs fast \(fastWait)s")
        #expect(slow.bulkEnvelopeUnits == 40, "the bulk envelope cap is priced off the profile's messages.get")
    }

    @Test("The client meters the bucket's profile costs: two getProfile calls at 30 units / 10 u/s take 3 s")
    func clientMetersProfileCosts() async throws {
        let clock = VirtualClock()
        let client = GmailAPIClient(quotaBucket: Self.bucket(clock, profile: Self.slow), transport: Self.profileTransport)

        #expect(client.unitCost.getProfile == 30)
        _ = try await client.getProfile(accessToken: "t", quotaKey: "meter")
        _ = try await client.getProfile(accessToken: "t", quotaKey: "meter")

        // The first debit waits nothing; the second queues 30 units behind it.
        #expect(abs(clock.elapsed - 3) < 0.001, "elapsed \(clock.elapsed)s")
    }

    @Test("A 5 u/s profile still backs off on a rate signal, and never past its ceiling")
    func slowProfileBacksOff() async {
        let five = GmailQuotaProfile(unitsPerSecond: 5, perUserUnitsPerSecond: 10, unitCost: .documented)
        let bucket = Self.bucket(VirtualClock(), profile: five)
        #expect(await bucket.rate(for: "k") == 5)

        await bucket.noteRateLimited(key: "k", retryAfter: nil)
        let afterOne = await bucket.rate(for: "k")
        #expect(afterOne < 5, "a fixed 10 u/s floor would have RAISED this to 10")
        #expect(afterOne == 2.5)

        for _ in 0..<5 {
            await bucket.noteRateLimited(key: "k", retryAfter: nil)
            let rate = await bucket.rate(for: "k")
            #expect(rate <= 5)
            #expect(rate >= bucket.minimumRate)
        }
        #expect(bucket.minimumRate == 1, "a fifth of the 5 u/s ceiling")
    }

    @Test("The process-wide shared bucket is the one the config builds")
    func sharedIsTheConfigsBucket() {
        #expect(GmailQuotaBucket.shared === GmailQuotaBucket.sharedConfig.resolve())
    }

    private final class RecordingStore: GmailQuotaStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var state: [String: GmailQuotaPersistedKey] = [:]
        private(set) var saves = 0
        func load() -> [String: GmailQuotaPersistedKey] { lock.withLock { state } }
        func save(_ state: [String: GmailQuotaPersistedKey]) { lock.withLock { self.state = state; saves += 1 } }
    }

    @Test("Unconfigured, the shared bucket is .current and memory-only")
    func unconfiguredDefaults() async {
        let config = GmailQuotaBucket.SharedConfig()
        let bucket = config.resolve()
        #expect(bucket.profile.unitsPerSecond == GmailQuotaProfile.current.unitsPerSecond)
        #expect(bucket.profile.unitCost.messagesGet == GmailQuotaProfile.current.unitCost.messagesGet)
        #expect(bucket.stateStore == nil)
        #expect(config.resolve() === bucket, "built once, then reused")
    }

    @Test("configureShared before first use is honoured; a second call and a late call are ignored")
    func configureOnce() async {
        let store = RecordingStore()
        let config = GmailQuotaBucket.SharedConfig()
        #expect(config.configure(profile: Self.slow, stateStore: store))
        #expect(!config.configure(profile: .legacy, stateStore: nil), "a second call must not replace the first")

        let bucket = config.resolve()
        #expect(bucket.profile.unitsPerSecond == 10)
        #expect(bucket.profile.unitCost.getProfile == 30, "the second call's .legacy costs must not leak in")
        await bucket.noteRateLimited(key: "k", retryAfter: nil)
        #expect(store.saves > 0, "the configured store receives the bucket's state")

        let late = GmailQuotaBucket.SharedConfig()
        _ = late.resolve()
        #expect(!late.configure(profile: Self.slow, stateStore: store), "a call after first use is ignored")
        #expect(late.resolve().profile.unitsPerSecond == GmailQuotaProfile.current.unitsPerSecond)
        #expect(late.resolve().profile.unitCost.getProfile == GmailQuotaProfile.current.unitCost.getProfile)
        #expect(late.resolve().stateStore == nil)
    }
}
