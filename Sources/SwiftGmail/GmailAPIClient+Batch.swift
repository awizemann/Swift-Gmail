//
//  GmailAPIClient+Batch.swift
//  SwiftGmail
//
//  Batched `messages.get` / `threads.get` over Gmail's `/batch/gmail/v1`
//  endpoint. One HTTPS round trip carries up to 50 sub-requests (see
//  `GmailBatchProtocol.maxOperations(for:unitCost:lane:)`; the bulk lane caps an
//  envelope at 400 units), which is where the sync-speed
//  win comes from: the old path paid a full request latency per message at
//  5-way concurrency.
//
//  What batching does NOT buy is quota. A batched `messages.get` costs the
//  same units as a standalone one, so every envelope is debited from the
//  account's `GmailQuotaBucket` before it goes out — a bucket that outlives
//  the call, so a pipeline's successive chunks (and a quick sync running
//  beside it) share one budget instead of each pacing from a clean slate.
//  Ignoring quota just converts latency savings into 429s.
//
//  Wire format lives in `GmailBatchProtocol` (pure, unit-tested).
//

import Foundation
import os

private let logger = GmailLogging.logger(category: "GmailAPIClient")

private let batchEndpoint = "https://gmail.googleapis.com/batch/gmail/v1"

/// Rounds of per-part re-issue for sub-requests that came back 429/5xx.
///
/// ONE. A per-part 429 means this account is over budget right now; sitting
/// on the pass for 5 + 10 + 20 seconds hoping otherwise is how a quick sync
/// turns into a minute-long stall (and, on iOS, into a background-time kill).
/// The ids that are still failing after one round are REPORTED to the caller
/// in `BatchFetchOutcome.leftover` — never swallowed. Quick sync owes
/// them to later passes in `QuickSyncPendingStore` (its page cursor steps over
/// them — `GmailPagedQuickSync`); full sync MUST drain them before it records anything complete, because
/// nothing else would ever ask for them again (t-8b089caa).
private let maxPartRetryRounds = 1

/// Backoff before the single re-issue round.
private let partRetryDelay: TimeInterval = 5.0

extension GmailAPIClient {

    /// Fetch many resources of one kind through the batch endpoint.
    ///
    /// - Per-part 404 is tolerated and skipped (a message can be deleted
    ///   between `list` and `get`; killing the sync over one is hostile).
    /// - Per-part 429/5xx re-issues just the failed ids in a follow-up batch.
    /// - A 429/5xx on the envelope itself retries the whole batch via `withRetry`.
    /// - A 401, envelope or per-part, forces ONE token refresh for the whole
    ///   call (`GmailTokenRefreshGate`) and re-issues the affected ids once.
    ///   Still 401 after that → those ids come back as `leftover` with
    ///   `authRejected` set, never dropped. This method does not throw for it;
    ///   the public wrappers do (`refreshedTokenRejected()`).
    /// - Throws `GmailBatchUnsupported` if the endpoint rejects the envelope
    ///   (400/415) so the caller can fall back to per-id requests. The fallback
    ///   re-fetches every id, including ones an already-completed chunk had
    ///   fetched — safe (these GETs are idempotent) and rare enough not to be
    ///   worth threading partial results through the failure path.
    ///
    /// - Parameter tokenSource: asked for a bearer right before EACH envelope
    ///   goes out (after the bucket's wait), never once up front — see
    ///   `GmailTokenSource` for the overnight-freeze failure this prevents.
    /// - Parameter unitCost: Gmail quota units per sub-request (see
    ///   `GmailQuotaProfile`) — what each envelope debits from the bucket.
    /// - Parameter quotaKey: the account this spend is metered against. Gmail's
    ///   ceiling is per USER, and one `GmailAPIClient` serves every account, so
    ///   the key — not the client instance — is what separates the buckets.
    func batchGet<T: Decodable & Sendable>(
        tokenSource: GmailTokenSource,
        resource: String,
        ids: [String],
        format: MessageFormat,
        unitCost: Int,
        quotaKey: String,
        retryDelay: TimeInterval = partRetryDelay,
        as type: T.Type
    ) async throws -> BatchFetchOutcome<T> {
        guard !ids.isEmpty else { return .complete([]) }

        let chunks = ids.chunkedForBatch(into: GmailBatchProtocol.maxOperations(
            for: format, unitCost: unitCost, lane: GmailQuotaLane.current
        ))
        let maxBatchesInFlight = GmailBatchProtocol.maxBatchesInFlight(for: format)
        let gate = GmailTokenRefreshGate(source: tokenSource)

        return try await withThrowingTaskGroup(of: (Int, BatchFetchOutcome<T>).self) { group in
            var collected: [Int: BatchFetchOutcome<T>] = [:]
            var nextChunk = 0
            var inFlight = 0

            while nextChunk < chunks.count || inFlight > 0 {
                while inFlight < maxBatchesInFlight, nextChunk < chunks.count {
                    try Task.checkCancellation()
                    let index = nextChunk
                    let chunk = chunks[index]
                    group.addTask {
                        // Pacing is the bucket's job now, inside `postBatch` —
                        // it covers the retry rounds and every OTHER call for
                        // this account too, which a sleep here could not.
                        let values: BatchFetchOutcome<T> = try await self.runBatch(
                            gate: gate,
                            resource: resource,
                            ids: chunk,
                            format: format,
                            unitCost: unitCost,
                            quotaKey: quotaKey,
                            retryDelay: retryDelay
                        )
                        return (index, values)
                    }
                    nextChunk += 1
                    inFlight += 1
                }

                if let (index, values) = try await group.next() {
                    collected[index] = values
                    inFlight -= 1
                }
            }

            // Restore request order — callers index results against their ids.
            return BatchFetchOutcome(
                fetched: chunks.indices.flatMap { collected[$0]?.fetched ?? [] },
                leftover: chunks.indices.flatMap { collected[$0]?.leftover ?? [] },
                notFound: chunks.indices.flatMap { collected[$0]?.notFound ?? [] },
                authRejected: chunks.indices.contains { collected[$0]?.authRejected == true },
                transient: chunks.indices.flatMap { collected[$0]?.transient ?? [] },
                failed: chunks.indices.flatMap { collected[$0]?.failed ?? [] }
            )
        }
    }

    /// Legacy single-string form: the token cannot be refreshed, so a 401 is
    /// reported (leftover + `authRejected`) without a retry.
    func batchGet<T: Decodable & Sendable>(
        accessToken: String,
        resource: String,
        ids: [String],
        format: MessageFormat,
        unitCost: Int,
        quotaKey: String,
        retryDelay: TimeInterval = partRetryDelay,
        as type: T.Type
    ) async throws -> BatchFetchOutcome<T> {
        try await batchGet(
            tokenSource: .fixed(accessToken),
            resource: resource,
            ids: ids,
            format: format,
            unitCost: unitCost,
            quotaKey: quotaKey,
            retryDelay: retryDelay,
            as: type
        )
    }

    /// One chunk, including per-part retry rounds for 429/5xx sub-responses
    /// and the single refresh-and-re-issue round for 401s.
    private func runBatch<T: Decodable & Sendable>(
        gate: GmailTokenRefreshGate,
        resource: String,
        ids: [String],
        format: MessageFormat,
        unitCost: Int,
        quotaKey: String,
        retryDelay: TimeInterval
    ) async throws -> BatchFetchOutcome<T> {
        var decoded: [T] = []
        var notFound: [String] = []
        var leftover: [String] = []
        var pending = ids
        var round = 0
        var dropped = 0
        var authRetried = false
        var authRejected = false
        var transient: [String] = []
        var failed: [String] = []

        while !pending.isEmpty {
            try Task.checkCancellation()

            let response = try await postBatch(
                gate: gate,
                resource: resource,
                ids: pending,
                format: format,
                unitCost: unitCost,
                quotaKey: quotaKey
            )

            var retryable: [String] = []
            var unauthorized: [String] = []
            // Which of `retryable` were RATE signals this round (vs 5xx or a
            // missing part) — only those are `transient` if they run out.
            var rateSignalled: Set<String> = []
            var succeeded = 0
            var rateLimited = 0
            if response.envelopeUnauthorized {
                unauthorized = pending
            }
            for (offset, id) in pending.enumerated() where !response.envelopeUnauthorized {
                guard let part = part(for: offset, in: response.parts) else {
                    // No sub-response came back for this id at all. Treat it as
                    // transient rather than silently dropping the message.
                    retryable.append(id)
                    continue
                }

                switch part.statusCode {
                case 200...299:
                    do {
                        decoded.append(try JSONDecoder().decode(T.self, from: part.body))
                        succeeded += 1
                    } catch {
                        dropped += 1
                        failed.append(id)
                        logger.warning("Gmail batch \(resource, privacy: .public).get: undecodable body for \(id, privacy: .public), skipping")
                    }
                case 401:
                    // The token, not the message. Dropping these is how an
                    // overnight-stale token lost a whole envelope (2026-10-05).
                    unauthorized.append(id)
                case 404:
                    notFound.append(id)
                    logger.info("Gmail batch \(resource, privacy: .public).get 404 for \(id, privacy: .public) — deleted server-side, skipping")
                case 403:
                    // 403 is AMBIGUOUS on Gmail: per-user rate limiting arrives
                    // as 403 with a usageLimits reason, a real refusal arrives
                    // as 403 with insufficientPermissions/forbidden. Only the
                    // body tells them apart, and getting it wrong the first way
                    // loses mail permanently (t-172bfc74).
                    let classification = GmailErrorClassification.classify(body: part.body)
                    if classification.isRateLimit {
                        rateLimited += 1
                        retryable.append(id)
                        rateSignalled.insert(id)
                    } else {
                        dropped += 1
                        failed.append(id)
                        logger.warning("Gmail batch \(resource, privacy: .public).get HTTP 403 (\(classification.reason ?? "no reason", privacy: .public)) for \(id, privacy: .public) — not a rate signal, skipping")
                    }
                case 429:
                    rateLimited += 1
                    retryable.append(id)
                    rateSignalled.insert(id)
                case 500...599:
                    retryable.append(id)
                default:
                    dropped += 1
                    failed.append(id)
                    logger.warning("Gmail batch \(resource, privacy: .public).get HTTP \(part.statusCode, privacy: .public) for \(id, privacy: .public), skipping")
                }
            }

            // Feed the bucket BEFORE the re-issue: a rate signal halves this
            // account's pacing and parks it for the quota window, so the
            // re-issue below (and every other call for the account) waits it
            // out instead of re-spending into an exhausted minute.
            if rateLimited > 0 {
                await quotaBucket.noteRateLimited(key: quotaKey)
                logger.warning("Gmail batch \(resource, privacy: .public).get: \(rateLimited, privacy: .public) of \(pending.count, privacy: .public) sub-request(s) rate-limited — bucket for this account throttled")
            } else if succeeded > 0 {
                await quotaBucket.noteSuccess(key: quotaKey)
            }

            var next: [String] = []
            var reissuingRetryable = false
            if !retryable.isEmpty {
                round += 1
                if round > maxPartRetryRounds {
                    // Handed BACK to the caller, not dropped — see `maxPartRetryRounds`.
                    logger.warning("Gmail batch \(resource, privacy: .public).get: \(retryable.count, privacy: .public) sub-request(s) still rate-limited after \(maxPartRetryRounds, privacy: .public) retry round(s) — reported as leftovers")
                    leftover += retryable
                    transient += retryable.filter { rateSignalled.contains($0) }
                } else {
                    next += retryable
                    reissuingRetryable = true
                }
            }

            // 401: one refresh per batch call (the gate coalesces chunks), one
            // re-issue per chunk. Its own budget, separate from the rate
            // rounds above — a stale token is not a rate signal.
            if !unauthorized.isEmpty {
                if !authRetried, try await gate.refreshOnce(rejecting: response.token) {
                    authRetried = true
                    logger.warning("Gmail batch \(resource, privacy: .public).get: HTTP 401 for \(unauthorized.count, privacy: .public) sub-request(s) — token refreshed, re-issuing once")
                    next += unauthorized
                } else {
                    authRejected = true
                    logger.warning("Gmail batch \(resource, privacy: .public).get: \(unauthorized.count, privacy: .public) sub-request(s) still HTTP 401 after a token refresh — reported as leftovers")
                    leftover += unauthorized
                }
            }

            pending = next
            guard !pending.isEmpty else { break }

            if reissuingRetryable {
                if rateLimited > 0 {
                    // No fixed sleep: `postBatch`'s own `consume` now waits out the
                    // cooldown the signal just installed. One pacing object beats
                    // two backoff schedules that don't know about each other.
                    logger.warning("Gmail batch \(resource, privacy: .public).get: re-issuing \(pending.count, privacy: .public) sub-requests, paced by the account's quota bucket")
                } else {
                    logger.warning("Gmail batch \(resource, privacy: .public).get: re-issuing \(pending.count, privacy: .public) sub-requests in \(String(format: "%.1f", retryDelay), privacy: .public)s")
                    if retryDelay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    }
                }
            }
        }

        if dropped > 0 {
            logger.warning("Gmail batch \(resource, privacy: .public).get: dropped \(dropped, privacy: .public) of \(ids.count, privacy: .public) sub-response(s) as unusable")
        }
        return BatchFetchOutcome(
            fetched: decoded, leftover: leftover, notFound: notFound,
            authRejected: authRejected, transient: transient, failed: failed
        )
    }

    /// Match a sub-response to its request.
    ///
    /// `Content-ID` is authoritative when present. When it is missing we fall
    /// back to wire order PER PART, not per envelope: a response that carries
    /// the header on some parts and not others (a proxy that rewrote a few, a
    /// part whose header we failed to parse) used to fail the all-or-nothing
    /// check and drop every unlabelled part — reported as a missing
    /// sub-response and retried, then skipped. A part that neither claims an
    /// id nor is claimed by one is matched positionally instead; a part that
    /// carries a DIFFERENT id is never taken for this index.
    private func part(for index: Int, in parts: [GmailBatchPart]) -> GmailBatchPart? {
        let wanted = GmailBatchProtocol.contentId(forIndex: index)
        if let matched = parts.first(where: { $0.contentId == wanted }) {
            return matched
        }
        guard index < parts.count, parts[index].contentId == nil else { return nil }
        return parts[index]
    }

    /// One envelope's answer, plus the token it went out with (a 401 names
    /// the token it rejected, so the gate can tell a stale one from a
    /// replacement another chunk already fetched).
    private struct BatchResponse: Sendable {
        var parts: [GmailBatchPart]
        var token: String
        /// The envelope itself was 401 — every id in it is unauthorized.
        var envelopeUnauthorized: Bool
    }

    /// POST one multipart envelope and decode its parts. Whole-envelope
    /// 429/5xx retry comes from `withRetry`; 400/415 escapes as
    /// `GmailBatchUnsupported` (not transient, so `withRetry` rethrows it).
    /// An envelope 401 is RETURNED, not thrown, so `runBatch` can give it the
    /// same one-refresh treatment as a per-part 401.
    private func postBatch(
        gate: GmailTokenRefreshGate,
        resource: String,
        ids: [String],
        format: MessageFormat,
        unitCost: Int,
        quotaKey: String
    ) async throws -> BatchResponse {
        try await withRetry(maxRetries: 3, rateLimitFloor: 0) {
            // Debit + wait before every attempt, retries included: a re-issued
            // envelope costs the same quota as the first one.
            try await self.quotaBucket.consume(units: ids.count * unitCost, key: quotaKey)
            // Resolved AFTER the wait, per attempt: the bucket can park this
            // account for minutes, and the process can be frozen for hours.
            let accessToken = try await gate.current()
            let boundary = GmailBatchProtocol.makeBoundary()
            let operations = ids.enumerated().map { index, id in
                GmailBatchOperation(
                    contentId: GmailBatchProtocol.contentId(forIndex: index),
                    path: "/gmail/v1/users/me/\(resource)/\(Self.pathEscaped(id))?format=\(format.rawValue)"
                )
            }

            guard let url = URL(string: batchEndpoint) else {
                throw GmailAPIError.invalidURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/mixed; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120
            request.httpBody = GmailBatchProtocol.encodeRequest(operations: operations, boundary: boundary)

            let (data, response) = try await self.send(request, quotaKey: quotaKey, reportsRateSignals: false)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GmailAPIError.invalidResponse
            }

            if httpResponse.statusCode == 401 {
                logger.warning("Gmail batch \(resource, privacy: .public).get envelope HTTP 401")
                return BatchResponse(parts: [], token: accessToken, envelopeUnauthorized: true)
            }

            if (500...599).contains(httpResponse.statusCode) || httpResponse.statusCode == 429 {
                if httpResponse.statusCode == 429 {
                    await self.quotaBucket.noteRateLimited(
                        key: quotaKey, retryAfter: Self.retryAfter(from: httpResponse)
                    )
                }
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            // An ENVELOPE-level 403 is the same ambiguity as a per-part one.
            // `withRetry` classifies by error case, not by body, so translate
            // here: a rate reason becomes `.rateLimitExceeded` (transient, and
            // already given the longer rate-limit backoff), anything else stays
            // a plain 403 and escapes on the first attempt.
            if httpResponse.statusCode == 403 {
                let classification = GmailErrorClassification.classify(body: data)
                logger.warning("Gmail batch \(resource, privacy: .public).get envelope HTTP 403 (\(classification.reason ?? "no reason", privacy: .public))")
                if classification.isRateLimit {
                    await self.quotaBucket.noteRateLimited(
                        key: quotaKey, retryAfter: Self.retryAfter(from: httpResponse)
                    )
                    throw GmailAPIError.rateLimitExceeded
                }
                throw GmailAPIError.httpError(statusCode: 403)
            }

            // The endpoint (or a proxy in front of it) doesn't speak batch —
            // fall back rather than failing the sync.
            if httpResponse.statusCode == 400 || httpResponse.statusCode == 415 {
                throw GmailBatchUnsupported(reason: "batch endpoint returned HTTP \(httpResponse.statusCode)")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                logger.warning("Gmail batch \(resource, privacy: .public).get envelope failed with HTTP \(httpResponse.statusCode, privacy: .public)")
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard let boundaryOut = GmailBatchProtocol.boundary(fromContentType: contentType) else {
                throw GmailBatchUnsupported(reason: "response was not multipart/mixed")
            }

            return BatchResponse(
                parts: try GmailBatchProtocol.decodeResponse(data: data, boundary: boundaryOut),
                token: accessToken,
                envelopeUnauthorized: false
            )
        }
    }

    /// `Retry-After`, when the server sent one. Seconds-form only — Gmail
    /// sends the integer form on rate limits; an HTTP-date value is ignored
    /// rather than mis-parsed (the bucket's own cooldown then applies).
    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard
            let raw = response.value(forHTTPHeaderField: "Retry-After"),
            let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
            seconds > 0
        else { return nil }
        return seconds
    }

    /// Gmail ids are URL-safe base64-ish, but escape anyway — an unescaped
    /// `?` or `#` in a sub-request target would silently change the call.
    private static func pathEscaped(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? id
    }
}

// MARK: - Per-id fallback
//
// The path batching replaced. Kept whole so a 400/415 from the batch endpoint
// degrades sync to the previously shipped behaviour instead of breaking it.

extension GmailAPIClient {

    /// Pre-batch fallback path, used only when `batchGet` reports the batch
    /// endpoint unusable. Keeps the previously shipped shape (5 concurrent +
    /// 50ms spacing) so a batch outage degrades to old behaviour, not to no
    /// sync — but it is now metered by the account's `GmailQuotaBucket` and it
    /// reports leftovers, because the two failures it used to collapse into
    /// `nil` are not the same failure at all (t-172bfc74).
    ///
    /// - A 404 is permanent (deleted server-side) → dropped, as before.
    /// - A rate signal (429, or 403 with a usageLimits reason, surfaced as
    ///   `GmailAPIError.rateLimitExceeded`) is transient → LEFTOVER, so a full
    ///   sync keeps the window pending instead of recording a hole complete.
    /// - A 401 gets one forced refresh and a re-send (token resolved per id);
    ///   still 401 → LEFTOVER with `authRejected`, and for a refreshable
    ///   source the credential error is thrown, as on the batch path.
    /// - Anything else is dropped with the error logged, as before: this path
    ///   cannot tell a permanent oddity from a transient one, and a leftover
    ///   that can never drain would pin the window pending forever.
    func getMessagesIndividually(
        tokenSource: GmailTokenSource,
        messageIds: [String],
        format: MessageFormat,
        quotaKey: String
    ) async throws -> BatchFetchOutcome<GmailMessage> {
        var messages: [GmailMessage] = []
        var leftover: [String] = []
        var notFound: [String] = []
        var authRejected = false
        var authFailure: (any Error)?
        var transient: [String] = []
        var failed: [String] = []

        for batch in messageIds.chunkedForBatch(into: 5) {
            try Task.checkCancellation()
            // The bucket debit used to happen HERE, one chunk at a time. It
            // moved into `getMessage` itself (t-924d2830) so that every single
            // call in the client is metered, whoever makes it — which means
            // this path must NOT also pre-consume, or each id would be charged
            // twice and the fallback would pace at half its budget. The 50ms
            // spacing below is still no substitute for the bucket: it knows
            // nothing about the other callers on this account.

            enum Fetched: Sendable {
                case message(GmailMessage)
                case rateLimited(String)
                case unauthorized(String)
                /// The 401 outlived its refresh, or the refresh itself failed
                /// (a revoked grant) — owed, and surfaced after the loop.
                case authFailed(String, any Error)
                /// Timed out / offline — owed, and no fault of the id's.
                case unreachable(String)
                /// The pass was cancelled; surfaced after the chunk.
                case cancelled
                case notFound(String)
                case gone(String)
            }

            let results: [Fetched] = await withTaskGroup(of: Fetched.self) { group in
                for id in batch {
                    group.addTask {
                        do {
                            // Token resolved per id, and a 401 refreshed once
                            // and re-sent — the batch path's contract, one id
                            // at a time (the refresh itself is single-flighted
                            // per mailbox in `OAuth2Service`).
                            return .message(try await self.getMessage(
                                tokenSource: tokenSource, messageId: id, format: format, quotaKey: quotaKey
                            ))
                        } catch let error where tokenSource.credentialErrors.recognises(error) {
                            logger.warning("messages.get auth failure for \(id, privacy: .public) — reported as leftover")
                            return .authFailed(id, error)
                        } catch GmailAPIError.httpError(let statusCode) where statusCode == 404 {
                            logger.info("messages.get 404 for \(id, privacy: .public) — message deleted server-side, skipping")
                            return .notFound(id)
                        } catch GmailAPIError.rateLimitExceeded {
                            logger.warning("messages.get rate-limited for \(id, privacy: .public) — reported as leftover")
                            return .rateLimited(id)
                        } catch GmailAPIError.httpError(let statusCode) where statusCode == 429 {
                            logger.warning("messages.get HTTP 429 for \(id, privacy: .public) — reported as leftover")
                            return .rateLimited(id)
                        } catch GmailAPIError.httpError(let statusCode) where statusCode == 401 {
                            // A `.fixed` token that cannot be refreshed: owed,
                            // not dropped, and flagged like the batch path does.
                            logger.warning("messages.get HTTP 401 for \(id, privacy: .public) — reported as leftover")
                            return .unauthorized(id)
                        } catch {
                            if error is CancellationError
                                || ((error as? URLError)?.code == .cancelled && Task.isCancelled) {
                                return .cancelled
                            }
                            if let urlError = error as? URLError, Self.unreachableCodes.contains(urlError.code) {
                                logger.warning("messages.get unreachable for \(id, privacy: .public) (\(urlError.code.rawValue, privacy: .public)) — reported as leftover")
                                return .unreachable(id)
                            }
                            logger.warning("messages.get failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                            return .gone(id)
                        }
                    }
                }

                var collected: [Fetched] = []
                for await result in group { collected.append(result) }
                return collected
            }

            var sawRateLimit = false
            var wasCancelled = false
            for result in results {
                switch result {
                case .message(let message): messages.append(message)
                case .rateLimited(let id):
                    leftover.append(id)
                    transient.append(id)
                    sawRateLimit = true
                case .unreachable(let id):
                    leftover.append(id)
                    transient.append(id)
                case .cancelled:
                    wasCancelled = true
                case .unauthorized(let id):
                    leftover.append(id)
                    authRejected = true
                case .authFailed(let id, let error):
                    leftover.append(id)
                    authRejected = true
                    if authFailure == nil { authFailure = error }
                case .notFound(let id): notFound.append(id)
                case .gone(let id): failed.append(id)
                }
            }
            // A cancelled pass stops HERE — never reported as a pile of
            // "gone" ids a caller would settle as resolved.
            if wasCancelled || Task.isCancelled { throw CancellationError() }
            if sawRateLimit {
                await quotaBucket.noteRateLimited(key: quotaKey)
            } else if !messages.isEmpty {
                await quotaBucket.noteSuccess(key: quotaKey)
            }

            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        // A refreshable source already got its refresh; surface the
        // credential failure itself (a revoked grant keeps its own detail).
        if let authFailure, tokenSource.canRefresh { throw authFailure }
        return BatchFetchOutcome(
            fetched: messages, leftover: leftover, notFound: notFound,
            authRejected: authRejected, transient: transient, failed: failed
        )
    }

    /// Pre-batch fallback path, used only when `batchGet` reports the batch
    /// endpoint unusable. Retained verbatim (5 concurrent + 50ms spacing) so a
    /// batch outage degrades to the previously shipped behaviour, not to no sync.
    func getThreadsIndividually(
        tokenSource: GmailTokenSource,
        threadIds: [String],
        format: MessageFormat,
        quotaKey: String
    ) async throws -> [GmailThread] {
        var threads: [GmailThread] = []

        for batch in threadIds.chunkedForBatch(into: 5) {
            try Task.checkCancellation()
            let batchThreads = try await withThrowingTaskGroup(of: GmailThread.self) { group in
                for id in batch {
                    group.addTask {
                        // Metered inside `getThread` — see the note in
                        // `getMessagesIndividually` on why this path does not
                        // pre-consume.
                        // Token per id; a 401 gets one refresh + re-send.
                        try await self.getThread(
                            tokenSource: tokenSource, threadId: id, format: format, quotaKey: quotaKey
                        )
                    }
                }

                var results: [GmailThread] = []
                for try await thread in group {
                    results.append(thread)
                }
                return results
            }
            threads.append(contentsOf: batchThreads)

            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        return threads
    }
}

extension GmailAPIClient {
    /// Transport failures that say "could not reach Gmail", not "this id is
    /// bad" — the per-id fallback owes these instead of dropping them.
    static let unreachableCodes: Set<URLError.Code> = [
        .timedOut, .notConnectedToInternet, .networkConnectionLost,
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        .dataNotAllowed, .internationalRoamingOff
    ]
}

private extension Array {
    func chunkedForBatch(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
