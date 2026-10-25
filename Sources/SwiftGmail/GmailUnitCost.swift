//
//  GmailUnitCost.swift
//  SwiftGmail
//
//  What each Gmail REST call costs against the per-user quota, and which
//  account a call is metered against when no caller passed a key.
//
//  Why this file exists (t-924d2830): until now the ONLY calls that debited
//  `GmailQuotaBucket` were the two batch envelopes (`messages.get` /
//  `threads.get`). Everything else — every `messages.list` page of a full
//  sync, every `history.list` page of a quick sync, every `getProfile` cursor
//  stamp, and above all every `attachments.get` — spent real quota units that
//  the bucket never saw. So the bucket's AIMD loop was pacing a fraction of
//  the traffic while the rest pushed the account over its ceiling: on
//  2026-09-12 a backfill's 16,603-row attachment sweep drove the bucket from
//  46 → 13 u/s in rate signals it could not attribute, and ingest fell from
//  ~1,200 to ~150 rows per 15 minutes.
//
//  A bucket that meters some of the spend is worse than no bucket, because it
//  reports a rate it is not actually holding.
//

import Foundation

/// Per-method quota unit costs.
///
/// Source: Google's published "Usage limits" table for the Gmail API —
/// <https://developers.google.com/workspace/gmail/api/reference/quota>,
/// read 2026-09-12. Verbatim from that page for the profile a project created
/// on or after 2026-05-01 is metered against:
///
/// | method                   | units |
/// | ------------------------ | ----- |
/// | `getProfile`             |     1 |
/// | `labels.list`            |     1 |
/// | `labels.create`          |     5 |
/// | `history.list`           |     2 |
/// | `messages.list`          |     5 |
/// | `messages.modify`        |     5 |
/// | `messages.untrash`       |     5 |
/// | `drafts.list`            |     5 |
/// | `drafts.get`             |     5 |
/// | `drafts.create`          |    10 |
/// | `drafts.delete`          |    10 |
/// | `messages.delete`        |    10 |
/// | `threads.list`           |    10 |
/// | `drafts.update`          |    15 |
/// | `messages.get`           |    20 |
/// | `messages.trash`         |    20 |
/// | `messages.attachments.get` | 20 |
/// | `threads.get`            |    40 |
/// | `messages.batchModify`   |    50 |
/// | `messages.send`          |   100 |
/// | `drafts.send`            |   100 |
///
/// 🚨 `messages.attachments.get` is **20**, not the 5 the legacy table
/// documented — an attachment fetch costs as much as a full `messages.get`.
/// That single number is most of the 2026-09-12 incident: 16,603 eager
/// attachment downloads were ~332,000 unmetered units.
///
/// The same page gives the per-user ceiling as **6,000 units/minute/user**
/// (= 100 u/s). `GmailQuotaProfile.current.unitsPerSecond` is deliberately
/// 50, the MEASURED ceiling on the project this was tuned against — see the note there.
public struct GmailUnitCost: Sendable {
    public let getProfile: Int
    public let labelsList: Int
    public let historyList: Int
    public let messagesList: Int
    public let messagesGet: Int
    public let messagesModify: Int
    public let messagesTrash: Int
    public let messagesUntrash: Int
    public let messagesDelete: Int
    public let messagesBatchModify: Int
    public let messagesSend: Int
    public let attachmentsGet: Int
    public let threadsList: Int
    public let threadsGet: Int
    public let draftsList: Int
    public let draftsCreate: Int
    public let draftsUpdate: Int
    public let draftsDelete: Int
    public let draftsGet: Int
    public let draftsSend: Int
    public let labelsCreate: Int

    /// The table above, verbatim. Correct for any project created on or after
    /// 2026-05-01.
    public static let documented = GmailUnitCost(
        getProfile: 1,
        labelsList: 1,
        historyList: 2,
        messagesList: 5,
        messagesGet: 20,
        messagesModify: 5,
        messagesTrash: 20,
        messagesUntrash: 5,
        messagesDelete: 10,
        messagesBatchModify: 50,
        messagesSend: 100,
        attachmentsGet: 20,
        threadsList: 10,
        threadsGet: 40,
        draftsList: 5,
        draftsCreate: 10,
        draftsUpdate: 15,
        draftsDelete: 10,
        draftsGet: 5,
        draftsSend: 100,
        labelsCreate: 5
    )

    /// Pre-2026-05-01 projects. The only documented differences are the two
    /// per-object gets (`messages.get` 5, `threads.get` 10) and
    /// `messages.trash` / `attachments.get` at 5; everything else is shared
    /// with `documented`.
    public static let legacy = GmailUnitCost(
        getProfile: 1,
        labelsList: 1,
        historyList: 2,
        messagesList: 5,
        messagesGet: 5,
        messagesModify: 5,
        messagesTrash: 5,
        messagesUntrash: 5,
        messagesDelete: 10,
        messagesBatchModify: 50,
        messagesSend: 100,
        attachmentsGet: 5,
        threadsList: 10,
        threadsGet: 40,
        draftsList: 5,
        draftsCreate: 10,
        draftsUpdate: 15,
        draftsDelete: 10,
        draftsGet: 5,
        draftsSend: 100,
        labelsCreate: 5
    )
}

/// Which account the CURRENT task tree's Gmail calls are metered against.
///
/// Every metered client method takes an explicit `quotaKey`, and the paths
/// that know their account (a host's fetch provider, the sync
/// orchestrator's cursor stamp) pass it. This task local exists for the one
/// family that cannot: `GmailActionApplier` is a deliberately narrow protocol
/// — `modify(accessToken:messageId:…)`, no account — with a dozen test fakes
/// conforming to it, and widening every signature to carry a key the fakes
/// have no use for would be a worse trade than scoping the drain.
///
/// So the action drain wraps its per-account work in `withKey(_:)` and the
/// client's default argument reads it. A caller outside any scope meters
/// against `GmailAPIClient.sharedQuotaKey`, which is the honest answer for a
/// one-off account-setup `getProfile`.
public enum GmailQuotaScope {
    @TaskLocal public static var current: String = GmailAPIClient.sharedQuotaKey

    /// Run `body` with every unkeyed Gmail call in its task tree metered
    /// against `key`. Child tasks inherit it; `Task.detached` does not.
    /// `nonisolated(nonsending)`: the non-deprecated `TaskLocal.withValue`
    /// overload runs `operation` on the caller's executor, which is exactly what
    /// the old `isolation:` parameter spelled out by hand.
    nonisolated(nonsending)
    public static func withKey<T>(
        _ key: String,
        _ body: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        try await $current.withValue(key, operation: body)
    }
}
