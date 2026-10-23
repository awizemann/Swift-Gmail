//
//  BatchFetchOutcome.swift
//  SwiftGmail
//
//  What a batched fetch actually came back with, and what it did NOT.
//
//  Why this type exists: the Gmail batch path tolerates per-sub-request 429s
//  by re-issuing them a bounded number of times and then *giving up on the
//  rest*. For a year that partial array was returned as if it were the whole
//  answer, and the only trace of the gap was a log line. Quick sync was
//  believed to survive that, but did not either: its per-page cursor is the
//  page's max history record id, which steps over an id it never fetched
//  (an incremental sync has to record such ids and owe them). Full sync: it ingested what came back, stamped the cursor past the
//  gap and recorded the history window complete, so ~20% of a large window was
//  lost permanently (t-8b089caa).
//
//  The fix is a type, not a comment: a batched fetch returns BOTH halves, so a
//  caller that wants only `fetched` has to say so at the call site, in writing.
//

import Foundation

/// The result of a batched fetch: what came back, and the ids that did not.
///
/// `leftover` is never an error — it is a *rate* signal (429/5xx sub-responses
/// that outlived the retry rounds), or a 401 that outlived the one token
/// refresh (see `authRejected`). A caller may drain it, defer it, or
/// knowingly ignore it; what it may not do is mistake `fetched` for complete.
public struct BatchFetchOutcome<Element: Sendable>: Sendable {
    public var fetched: [Element]
    public var leftover: [String]
    /// Ids the server answered with an explicit 404 — the message does not
    /// exist any more. Only a real 404 lands here, never an unclassified
    /// failure: a full-sync deletion check deletes local rows on
    /// this answer, so "could not tell" must never be read as "gone".
    public var notFound: [String]
    /// Some of `leftover` came back 401 even after a token refresh — the
    /// credential, not the rate, is the problem. The Gmail client's public
    /// entry points turn this into the credential error the token source's
    /// `GmailCredentialErrors` builds (`GmailAPIError.authenticationFailed`
    /// by default) so it surfaces the way a revoked refresh token does; the
    /// ids stay in `leftover` either way, so nothing reads them as fetched.
    public var authRejected: Bool
    /// The subset of `leftover` whose failure says nothing about the id
    /// itself — a rate signal (429, a 403 with a rate reason) or a
    /// connectivity failure. A caller that counts failures against an id
    /// (an incremental sync's pending store) must not charge these: a rate-limit storm
    /// would otherwise abandon healthy mail within a few ticks.
    public var transient: [String]
    /// Ids the server answered but that were NOT usable and NOT worth an
    /// immediate re-ask: an undecodable body, a non-rate 403, an unexpected
    /// status, a per-id 5xx or unclassified error on the fallback path. Not
    /// in `leftover` (full sync must not pin a window on them), but reported,
    /// so quick sync can owe them a slow, charged retry instead of silently
    /// stepping over them.
    public var failed: [String]

    public init(
        fetched: [Element],
        leftover: [String] = [],
        notFound: [String] = [],
        authRejected: Bool = false,
        transient: [String] = [],
        failed: [String] = []
    ) {
        self.fetched = fetched
        self.leftover = leftover
        self.notFound = notFound
        self.authRejected = authRejected
        self.transient = transient
        self.failed = failed
    }

    /// True when every requested id was accounted for.
    public var isComplete: Bool { leftover.isEmpty }

    public func mapFetched<Other: Sendable>(_ transform: (Element) -> Other) -> BatchFetchOutcome<Other> {
        BatchFetchOutcome<Other>(
            fetched: fetched.map(transform), leftover: leftover, notFound: notFound,
            authRejected: authRejected, transient: transient, failed: failed
        )
    }

    public static func complete(_ fetched: [Element]) -> BatchFetchOutcome<Element> {
        BatchFetchOutcome(fetched: fetched, leftover: [])
    }
}
