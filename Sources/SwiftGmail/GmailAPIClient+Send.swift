//
//  GmailAPIClient+Send.swift
//  SwiftGmail
//
//  The one place every Gmail HTTP request goes on the wire.
//
//  Two things the quota bucket needs to know about a request happen here, so
//  no call site can forget them:
//
//  1. Interactive in-flight tracking (t-de5eebfb). A request on the
//     interactive lane is bracketed with `beginInteractive` / `endInteractive`
//     so bulk consumers for the same account yield while it is on the wire —
//     however long it takes, rather than a guessed window.
//  2. Rate signals from single calls. Only the batch path used to call
//     `noteRateLimited`; a 429 or rate-reason 403 on `history.list`,
//     `messages.list`, a single get or the profile read never reached the
//     bucket, so the account kept being paced as if nothing had happened.
//

import Foundation

extension GmailAPIClient {

    /// Send `request` for `quotaKey` on the current task's lane.
    ///
    /// - Parameter reportsRateSignals: false for a caller that reports its own
    ///   rate signals (the batch envelope, which also carries per-part ones),
    ///   so one response is not counted twice.
    func send(
        _ request: URLRequest,
        quotaKey: String,
        lane: GmailQuotaLane = GmailQuotaLane.current,
        reportsRateSignals: Bool = true
    ) async throws -> (Data, URLResponse) {
        let interactive = lane == .interactive
        if interactive { await quotaBucket.beginInteractive(key: quotaKey) }
        let result: (Data, URLResponse)
        do {
            result = try await transport(request)
        } catch {
            if interactive { await quotaBucket.endInteractive(key: quotaKey) }
            throw error
        }
        if interactive { await quotaBucket.endInteractive(key: quotaKey) }
        if reportsRateSignals, let http = result.1 as? HTTPURLResponse, Self.isRateSignal(http, body: result.0) {
            await quotaBucket.noteRateLimited(key: quotaKey, retryAfter: Self.retryAfter(from: http))
        }
        return result
    }

    /// A 429, or a 403 whose body names a rate/quota reason (Gmail's per-user
    /// limit arrives as 403 — `gmailError(from:body:call:)` has the history).
    static func isRateSignal(_ response: HTTPURLResponse, body: Data) -> Bool {
        switch response.statusCode {
        case 429: return true
        case 403: return GmailErrorClassification.classify(body: body).isRateLimit
        default: return false
        }
    }
}
