// LINE-CAP EXEMPTION: one provider's HTTP surface (requests, paging, error mapping) — the natural unit is the API, not the endpoint.
//
//  GmailAPIClient.swift
//  SwiftGmail
//
//  Gmail REST API client. Pure HTTP — no persistence, no AppKit/UIKit.
//

import Foundation
import os

/// Gmail REST API client for native Gmail operations.
/// Bearer tokens come from the host via `GmailTokenSource` (or a plain string).
/// Nonisolated — every method is pure network I/O + JSON decoding with no mutable state.
public final class GmailAPIClient: Sendable {

    private let logger = GmailLogging.logger(category: "GmailAPIClient")

    private let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"

    /// The quota bucket every metered call debits. Defaults to the
    /// process-wide one so all clients for an account share a budget; tests
    /// inject a bucket with a virtual clock.
    let quotaBucket: GmailQuotaBucket

    /// How a request goes on the wire. `URLSession.shared` in production (so
    /// the suites that stub it with a global `URLProtocol` keep working);
    /// tests that only need a canned response inject one here.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let transport: Transport

    public init() {
        self.quotaBucket = .shared
        self.transport = { try await URLSession.shared.data(for: $0) }
    }

    public init(quotaBucket: GmailQuotaBucket, transport: Transport? = nil) {
        self.quotaBucket = quotaBucket
        self.transport = transport ?? { try await URLSession.shared.data(for: $0) }
    }

    /// Quota bucket for callers that don't know (or don't care) which account
    /// they are spending against — one-off profile lookups during account
    /// setup, not the sync fan-out. Sync paths pass the account id so each
    /// account is metered against its own per-user ceiling.
    public static let sharedQuotaKey = "gmail.default"

    /// Debit one call's documented unit cost from `key`'s bucket and wait out
    /// the reservation, on the lane the current task tree belongs to.
    ///
    /// Every network method in this client calls this before its request goes
    /// out. `units` is read off `quotaBucket.profile.unitCost`, never
    /// hard-coded at the call site — one table, cited once
    /// (`GmailUnitCost.documented`).
    ///
    /// The outcome is reported by `send(_:quotaKey:)`, which every request
    /// goes through: a 429, or a 403 whose body carries a rate reason, feeds
    /// `noteRateLimited` for the key whichever call drew it (the batch path
    /// also reports its per-part signals itself).
    /// - Parameter parkable: false ONLY for a request a person is waiting on
    ///   to send mail — see `GmailQuotaBucket.reserve(units:key:lane:parkable:)`.
    func meter(_ units: Int, key: String, parkable: Bool = true) async throws {
        try await quotaBucket.consume(units: units, key: key, parkable: parkable)
    }

    /// The unit-cost table this client meters against — its bucket's profile.
    var unitCost: GmailUnitCost { quotaBucket.profile.unitCost }

    // MARK: - URL Helpers

    // `internal` (not private) so the URL-encoding contract is testable —
    // the `+`-as-space regression class is invisible at every other seam.
    func apiURL(_ path: String, queryItems: [URLQueryItem]? = nil) throws -> URL {
        guard var components = URLComponents(string: path) else {
            throw GmailAPIError.invalidURL
        }
        if let queryItems {
            components.queryItems = queryItems
            // `URLComponents` leaves a literal `+` unescaped in query values
            // (RFC-legal), but Gmail's server form-decodes `+` as a SPACE. A
            // `rfc822msgid:` search for a Gmail-composed Message-ID (the
            // `CAL…+=…@mail.gmail.com` shape) therefore silently matched
            // nothing, and every attachment download on such a message
            // failed with messageNotFound — the 2026-08-13 Quick Look bug
            // (183 failed rows in the live store, all with `+`/`=` ids).
            // Re-encode the assembled query so `+` survives the round trip.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else {
            throw GmailAPIError.invalidURL
        }
        return url
    }

    private func simpleURL(_ string: String) throws -> URL {
        guard let url = URL(string: string) else {
            throw GmailAPIError.invalidURL
        }
        return url
    }

    // MARK: - Listing

    /// List messages matching a Gmail search query.
    public func listMessages(
        accessToken: String,
        query: String,
        maxResults: Int = 100,
        pageToken: String? = nil,
        includeSpamTrash: Bool = false,
        quotaKey: String = GmailQuotaScope.current
    ) async throws -> ListMessagesResponse {
        try await meter(self.unitCost.messagesList, key: quotaKey)
        // `includeSpamTrash` defaults to FALSE server-side, and that filter is
        // applied to the RESULTS — an `in:spam` query without it comes back
        // empty. Only full sync's spam listing asks for it.
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxResults))
        ]

        if includeSpamTrash {
            queryItems.append(URLQueryItem(name: "includeSpamTrash", value: "true"))
        }

        if let pageToken = pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }

        let url = try apiURL("\(baseURL)/messages", queryItems: queryItems)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await self.send(request, quotaKey: quotaKey)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            logger.error("Gmail messages.list failed with HTTP \(httpResponse.statusCode)")
            // Gmail reports per-user rate limiting as a 403 whose body carries
            // the reason; classify it like `getThread` does so a caller sees a
            // rate limit (and backs off) rather than a bare 403.
            if httpResponse.statusCode == 403 {
                throw gmailError(from: httpResponse, body: data, call: "messages.list")
            }
            throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(ListMessagesResponse.self, from: data)
    }

    /// List the account's drafts (partial resources: stable draft id +
    /// minimal message ref). Paginated by the caller via `nextPageToken`.
    /// Full bodies come from a follow-up batched `getMessages` on the
    /// referenced message ids — a draft's underlying message is a real
    /// message resource, so no separate `drafts.get` is needed.
    public func listDrafts(
        accessToken: String,
        maxResults: Int = 100,
        pageToken: String? = nil,
        quotaKey: String = GmailQuotaScope.current
    ) async throws -> ListDraftsResponse {
        try await meter(self.unitCost.draftsList, key: quotaKey)
        var queryItems = [URLQueryItem(name: "maxResults", value: String(maxResults))]
        if let pageToken = pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }

        let url = try apiURL("\(baseURL)/drafts", queryItems: queryItems)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await self.send(request, quotaKey: quotaKey)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            logger.error("Gmail drafts.list failed with HTTP \(httpResponse.statusCode, privacy: .public)")
            throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(ListDraftsResponse.self, from: data)
    }

    /// Fetch the user's profile (cheap; useful as a historyId fallback).
    public func getProfile(
        accessToken: String,
        quotaKey: String = GmailQuotaScope.current
    ) async throws -> GmailProfile {
        try await meter(self.unitCost.getProfile, key: quotaKey)
        let url = try simpleURL("\(baseURL)/profile")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await self.send(request, quotaKey: quotaKey)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
        }
        return try JSONDecoder().decode(GmailProfile.self, from: data)
    }

    public func listLabels(
        accessToken: String,
        quotaKey: String = GmailQuotaScope.current
    ) async throws -> [GmailLabel] {
        try await meter(self.unitCost.labelsList, key: quotaKey)
        let url = try simpleURL("\(baseURL)/labels")

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await self.send(request, quotaKey: quotaKey)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
        }

        let labelsResponse = try JSONDecoder().decode(ListLabelsResponse.self, from: data)
        return labelsResponse.labels ?? []
    }

    /// List history changes since a given historyId.
    /// Throws `.historyIdExpired` (404) if the cursor is stale — caller should do a full sync.
    public func listHistory(
        accessToken: String,
        startHistoryId: String,
        labelId: String? = nil,
        pageToken: String? = nil,
        quotaKey: String = GmailQuotaScope.current
    ) async throws -> HistoryListResponse {
        try await meter(self.unitCost.historyList, key: quotaKey)
        return try await historyRequest(
            accessToken: accessToken, startHistoryId: startHistoryId, labelId: labelId, pageToken: pageToken,
            quotaKey: quotaKey
        )
    }

    /// The same page, with the token resolved AFTER the bucket's wait and a
    /// 401 given one forced refresh and one re-send — the paged quick sync's
    /// entry point. A 401 that survives the refresh throws
    /// `refreshedTokenRejected()`; a refresh that fails throws its own
    /// `authenticationFailed`. Either way the page was never ingested, so no
    /// cursor moved.
    public func listHistory(
        tokenSource: GmailTokenSource,
        startHistoryId: String,
        labelId: String? = nil,
        pageToken: String? = nil,
        quotaKey: String = GmailQuotaScope.current
    ) async throws -> HistoryListResponse {
        try await withTokenSource(tokenSource, meter: {
            // Every send is metered — the 401 re-send included.
            try await self.meter(self.unitCost.historyList, key: quotaKey)
        }) { token in
            try await historyRequest(
                accessToken: token, startHistoryId: startHistoryId, labelId: labelId, pageToken: pageToken,
                quotaKey: quotaKey
            )
        }
    }

    /// One unmetered `history.list` request — callers meter first.
    private func historyRequest(
        accessToken: String,
        startHistoryId: String,
        labelId: String?,
        pageToken: String?,
        quotaKey: String
    ) async throws -> HistoryListResponse {
        var queryItems = [
            URLQueryItem(name: "startHistoryId", value: startHistoryId)
        ]

        if let labelId = labelId {
            queryItems.append(URLQueryItem(name: "labelId", value: labelId))
        }

        if let pageToken = pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }

        let url = try apiURL("\(baseURL)/history", queryItems: queryItems)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await self.send(request, quotaKey: quotaKey)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailAPIError.invalidResponse
        }

        if httpResponse.statusCode == 404 {
            throw GmailAPIError.historyIdExpired
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            logger.error("Gmail history.list failed with HTTP \(httpResponse.statusCode)")
            throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(HistoryListResponse.self, from: data)
    }

    // MARK: - Threads

    /// ⚠️ No `includeSpamTrash` here. `messages.list` has the parameter (and
    /// full sync's spam listing needs it, since the filter is applied to the
    /// RESULTS and an `in:spam` query comes back empty without it);
    /// `threads.list` takes the same parameter server-side but it is NOT
    /// plumbed through this method. Any caller that ever needs a thread-level
    /// spam or trash query must add it — a `q:` operator alone will silently
    /// return nothing, exactly as it did for `listMessages`.
    public func listThreads(
        accessToken: String,
        query: String,
        maxResults: Int = 100,
        pageToken: String? = nil,
        quotaKey: String = GmailQuotaScope.current
    ) async throws -> ListThreadsResponse {
        try await meter(self.unitCost.threadsList, key: quotaKey)
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
            URLQueryItem(name: "fields", value: "threads(id,snippet,historyId),nextPageToken,resultSizeEstimate")
        ]

        if let pageToken = pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }

        let url = try apiURL("\(baseURL)/threads", queryItems: queryItems)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await self.send(request, quotaKey: quotaKey)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            logger.error("Gmail threads.list failed with HTTP \(httpResponse.statusCode)")
            throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(ListThreadsResponse.self, from: data)
    }

    public func getThread(
        accessToken: String,
        threadId: String,
        format: MessageFormat = .full,
        quotaKey: String = GmailQuotaScope.current
    ) async throws -> GmailThread {
        try await withRetry(maxRetries: 3) {
            try await self.meter(self.unitCost.threadsGet, key: quotaKey)
            return try await self.threadRequest(accessToken: accessToken, threadId: threadId, format: format, quotaKey: quotaKey)
        }
    }

    /// The same fetch with the token resolved AFTER the bucket's wait, on
    /// every attempt (and a 401 given one refresh + re-send) — the per-id
    /// fallback's entry point, so a long wait cannot age the token it sends.
    func getThread(
        tokenSource: GmailTokenSource,
        threadId: String,
        format: MessageFormat = .full,
        quotaKey: String = GmailQuotaScope.current
    ) async throws -> GmailThread {
        try await withRetry(maxRetries: 3) {
            try await self.withTokenSource(tokenSource, meter: {
                try await self.meter(self.unitCost.threadsGet, key: quotaKey)
            }) { token in
                try await self.threadRequest(accessToken: token, threadId: threadId, format: format, quotaKey: quotaKey)
            }
        }
    }

    /// One unmetered request — callers meter first.
    private func threadRequest(
        accessToken: String,
        threadId: String,
        format: MessageFormat,
        quotaKey: String
    ) async throws -> GmailThread {
        let url = try self.apiURL("\(self.baseURL)/threads/\(threadId)", queryItems: [
            URLQueryItem(name: "format", value: format.rawValue)
        ])
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let (data, response) = try await self.send(request, quotaKey: quotaKey)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailAPIError.invalidResponse
        }

        if (500...599).contains(httpResponse.statusCode) || httpResponse.statusCode == 429 {
            throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
        }

        // Gmail reports per-user RATE LIMITING as 403, not 429 — only the
        // body's reason tells it apart from a real permission refusal.
        if httpResponse.statusCode == 403 {
            throw self.gmailError(from: httpResponse, body: data, call: "getThread")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(GmailThread.self, from: data)
    }

    /// Batched thread fetch: one `/batch/gmail/v1` envelope per chunk of up to
    /// 50 threads (`GmailBatchProtocol.maxOperations(for:unitCost:lane:bulkEnvelopeUnits:)`)
    /// (was 5 concurrent single gets + a 50ms sleep — one round trip per
    /// thread). Falls back to the per-id path if the batch endpoint rejects
    /// the envelope. `threads.get` costs `quotaBucket.profile.threadsGetCost`
    /// quota units, debited from `quotaKey`'s bucket (the account id — Gmail's
    /// ceiling is per user and this client is shared across accounts).
    public func getThreadsBatch(
        tokenSource: GmailTokenSource,
        threadIds: [String],
        format: MessageFormat = .full,
        quotaKey: String = GmailAPIClient.sharedQuotaKey
    ) async throws -> [GmailThread] {
        guard !threadIds.isEmpty else { return [] }

        do {
            // Threads are only ever fetched for enrichment, never as the sole
            // record of a message, so a leftover here costs a re-fetch on a
            // later pass rather than a permanent hole.
            let outcome = try await batchGet(
                tokenSource: tokenSource,
                resource: "threads",
                ids: threadIds,
                format: format,
                unitCost: quotaBucket.profile.threadsGetCost,
                quotaKey: quotaKey,
                as: GmailThread.self
            )
            try Self.throwIfAuthRejected(outcome, tokenSource: tokenSource)
            if !outcome.isComplete {
                logger.warning("threads.get: \(outcome.leftover.count, privacy: .public) thread(s) left rate-limited this pass")
            }
            return outcome.fetched
        } catch let unsupported as GmailBatchUnsupported {
            logger.warning("Gmail batch endpoint unusable (\(unsupported.reason, privacy: .public)) — falling back to per-thread gets")
            return try await getThreadsIndividually(
                tokenSource: tokenSource,
                threadIds: threadIds,
                format: format,
                quotaKey: quotaKey
            )
        }
    }

    // MARK: - Messages

    public func getMessage(
        accessToken: String,
        messageId: String,
        format: MessageFormat = .full,
        quotaKey: String = GmailQuotaScope.current
    ) async throws -> GmailMessage {
        try await withRetry(maxRetries: 3) {
            try await self.meter(self.unitCost.messagesGet, key: quotaKey)
            return try await self.messageRequest(accessToken: accessToken, messageId: messageId, format: format, quotaKey: quotaKey)
        }
    }

    /// The same fetch with the token resolved AFTER the bucket's wait, on
    /// every attempt (and a 401 given one refresh + re-send) — the per-id
    /// fallback's entry point, so a long wait cannot age the token it sends.
    func getMessage(
        tokenSource: GmailTokenSource,
        messageId: String,
        format: MessageFormat = .full,
        quotaKey: String = GmailQuotaScope.current
    ) async throws -> GmailMessage {
        try await withRetry(maxRetries: 3) {
            try await self.withTokenSource(tokenSource, meter: {
                try await self.meter(self.unitCost.messagesGet, key: quotaKey)
            }) { token in
                try await self.messageRequest(accessToken: token, messageId: messageId, format: format, quotaKey: quotaKey)
            }
        }
    }

    /// One unmetered request — callers meter first.
    private func messageRequest(
        accessToken: String,
        messageId: String,
        format: MessageFormat,
        quotaKey: String
    ) async throws -> GmailMessage {
        let url = try self.apiURL("\(self.baseURL)/messages/\(messageId)", queryItems: [
            URLQueryItem(name: "format", value: format.rawValue)
        ])
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await self.send(request, quotaKey: quotaKey)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailAPIError.invalidResponse
        }

        if (500...599).contains(httpResponse.statusCode) || httpResponse.statusCode == 429 {
            throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
        }

        // Gmail reports per-user RATE LIMITING as 403, not 429 — only the
        // body's reason tells it apart from a real permission refusal.
        if httpResponse.statusCode == 403 {
            throw self.gmailError(from: httpResponse, body: data, call: "getMessage")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(GmailMessage.self, from: data)
    }

    public func getAttachment(
        accessToken: String,
        messageId: String,
        attachmentId: String,
        quotaKey: String = GmailQuotaScope.current
    ) async throws -> Data {
        try await withRetry(maxRetries: 3) {
            // 20 units — as expensive as a full `messages.get`. This is the
            // call whose 16,603-row eager sweep starved the 2026-09-12
            // backfill while the bucket showed a rate it was not holding.
            try await self.meter(self.unitCost.attachmentsGet, key: quotaKey)
            let url = try self.simpleURL("\(self.baseURL)/messages/\(messageId)/attachments/\(attachmentId)")

            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 60

            let (data, response) = try await self.send(request, quotaKey: quotaKey)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GmailAPIError.invalidResponse
            }

            if (500...599).contains(httpResponse.statusCode) || httpResponse.statusCode == 429 {
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            // Gmail reports per-user RATE LIMITING as 403, not 429 — only the
            // body's reason tells it apart from a real permission refusal.
            if httpResponse.statusCode == 403 {
                throw self.gmailError(from: httpResponse, body: data, call: "getAttachment")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            struct AttachmentResponse: Codable {
                let size: Int
                let data: String
            }

            let attachmentResponse = try JSONDecoder().decode(AttachmentResponse.self, from: data)

            // Base64url → Data
            var base64 = attachmentResponse.data
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")

            let padding = (4 - base64.count % 4) % 4
            base64 += String(repeating: "=", count: padding)

            guard let attachmentData = Data(base64Encoded: base64) else {
                throw GmailAPIError.parsingError
            }

            return attachmentData
        }
    }

    /// Batched message fetch: one `/batch/gmail/v1` envelope per chunk of up to
    /// 50 ids (`GmailBatchProtocol.maxOperations(for:unitCost:lane:bulkEnvelopeUnits:)`)
    /// instead of one HTTPS round trip per message at 5-way concurrency.
    /// Falls back to the per-id path if the batch endpoint rejects the
    /// envelope. `messages.get` costs `quotaBucket.profile.messagesGetCost`
    /// quota units, debited from `quotaKey`'s bucket (see `getThreadsBatch`).
    public func getMessages(
        tokenSource: GmailTokenSource,
        messageIds: [String],
        format: MessageFormat = .full,
        quotaKey: String = GmailAPIClient.sharedQuotaKey
    ) async throws -> [GmailMessage] {
        // Callers on this overload have no place to put a leftover (drafts
        // hydration, on-demand body fetch — all of which re-ask naturally).
        // Anything whose completeness MATTERS must use `getMessagesOutcome`.
        try await getMessagesOutcome(
            tokenSource: tokenSource,
            messageIds: messageIds,
            format: format,
            quotaKey: quotaKey
        ).fetched
    }

    /// The same batched fetch, with the ids that never came back reported
    /// rather than dropped. Full sync uses this one: a leftover it cannot
    /// drain must keep the history window pending (t-8b089caa).
    public func getMessagesOutcome(
        tokenSource: GmailTokenSource,
        messageIds: [String],
        format: MessageFormat = .full,
        quotaKey: String = GmailAPIClient.sharedQuotaKey
    ) async throws -> BatchFetchOutcome<GmailMessage> {
        guard !messageIds.isEmpty else { return .complete([]) }

        do {
            let outcome = try await batchGet(
                tokenSource: tokenSource,
                resource: "messages",
                ids: messageIds,
                format: format,
                unitCost: quotaBucket.profile.messagesGetCost,
                quotaKey: quotaKey,
                as: GmailMessage.self
            )
            try Self.throwIfAuthRejected(outcome, tokenSource: tokenSource)
            return outcome
        } catch let unsupported as GmailBatchUnsupported {
            logger.warning("Gmail batch endpoint unusable (\(unsupported.reason, privacy: .public)) — falling back to per-message gets")
            // The fallback reports leftovers too, but only for failures it can
            // PROVE are transient (429 / 403-with-a-rate-reason). A 404 or an
            // unclassifiable error is still dropped: a leftover that can never
            // drain would pin the history window pending forever, which is
            // worse than the gap.
            let outcome = try await getMessagesIndividually(
                tokenSource: tokenSource,
                messageIds: messageIds,
                format: format,
                quotaKey: quotaKey
            )
            try Self.throwIfAuthRejected(outcome, tokenSource: tokenSource)
            return outcome
        }
    }

    // MARK: - Modify

    @discardableResult
    public func modifyMessage(
        accessToken: String,
        messageId: String,
        addLabelIds: [String] = [],
        removeLabelIds: [String] = [],
        quotaKey: String = GmailQuotaScope.current
    ) async throws -> GmailMessage {
        try await withRetry(maxRetries: 3) {
            try await self.meter(self.unitCost.messagesModify, key: quotaKey)
            let url = try self.simpleURL("\(self.baseURL)/messages/\(messageId)/modify")

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30

            let body: [String: [String]] = [
                "addLabelIds": addLabelIds,
                "removeLabelIds": removeLabelIds
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await self.send(request, quotaKey: quotaKey)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GmailAPIError.invalidResponse
            }

            if (500...599).contains(httpResponse.statusCode) || httpResponse.statusCode == 429 {
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            // Gmail reports per-user RATE LIMITING as 403, not 429 — only the
            // body's reason tells it apart from a real permission refusal.
            if httpResponse.statusCode == 403 {
                throw self.gmailError(from: httpResponse, body: data, call: "modifyMessage")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                self.logger.error("Gmail messages.modify failed with HTTP \(httpResponse.statusCode) for message \(messageId)")
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            return try JSONDecoder().decode(GmailMessage.self, from: data)
        }
    }

    public func batchModifyMessages(
        accessToken: String,
        messageIds: [String],
        addLabelIds: [String] = [],
        removeLabelIds: [String] = [],
        quotaKey: String = GmailQuotaScope.current
    ) async throws {
        guard !messageIds.isEmpty else { return }

        for batch in messageIds.chunked(into: 1000) {
            try Task.checkCancellation()
            try await withRetry(maxRetries: 3) {
                // Flat 50 units per CALL, not per id — `messages.batchModify`
                // is priced as one operation however many ids it carries,
                // which is exactly why the drainer batches by (kind, payload).
                try await self.meter(self.unitCost.messagesBatchModify, key: quotaKey)
                let url = try self.simpleURL("\(self.baseURL)/messages/batchModify")

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 60

                let body: [String: Any] = [
                    "ids": batch,
                    "addLabelIds": addLabelIds,
                    "removeLabelIds": removeLabelIds
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (_, response) = try await self.send(request, quotaKey: quotaKey)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw GmailAPIError.invalidResponse
                }

                if (500...599).contains(httpResponse.statusCode) || httpResponse.statusCode == 429 {
                    throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    self.logger.error("Gmail messages.batchModify failed with HTTP \(httpResponse.statusCode)")
                    throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
                }
            }
        }

        logger.info("Batch modified \(messageIds.count) messages")
    }

    // MARK: - Trash / Delete

    @discardableResult
    public func trashMessage(
        accessToken: String,
        messageId: String,
        quotaKey: String = GmailQuotaScope.current
    ) async throws -> GmailMessage {
        try await withRetry(maxRetries: 3) {
            try await self.meter(self.unitCost.messagesTrash, key: quotaKey)
            let url = try self.simpleURL("\(self.baseURL)/messages/\(messageId)/trash")

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30

            let (data, response) = try await self.send(request, quotaKey: quotaKey)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GmailAPIError.invalidResponse
            }

            if (500...599).contains(httpResponse.statusCode) || httpResponse.statusCode == 429 {
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            // Gmail reports per-user RATE LIMITING as 403, not 429 — only the
            // body's reason tells it apart from a real permission refusal.
            if httpResponse.statusCode == 403 {
                throw self.gmailError(from: httpResponse, body: data, call: "trashMessage")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                self.logger.error("Gmail messages.trash failed with HTTP \(httpResponse.statusCode) for message \(messageId)")
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            return try JSONDecoder().decode(GmailMessage.self, from: data)
        }
    }

    @discardableResult
    public func untrashMessage(
        accessToken: String,
        messageId: String,
        quotaKey: String = GmailQuotaScope.current
    ) async throws -> GmailMessage {
        try await withRetry(maxRetries: 3) {
            try await self.meter(self.unitCost.messagesUntrash, key: quotaKey)
            let url = try self.simpleURL("\(self.baseURL)/messages/\(messageId)/untrash")

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30

            let (data, response) = try await self.send(request, quotaKey: quotaKey)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GmailAPIError.invalidResponse
            }

            if (500...599).contains(httpResponse.statusCode) || httpResponse.statusCode == 429 {
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            // Gmail reports per-user RATE LIMITING as 403, not 429 — only the
            // body's reason tells it apart from a real permission refusal.
            if httpResponse.statusCode == 403 {
                throw self.gmailError(from: httpResponse, body: data, call: "untrashMessage")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                self.logger.error("Gmail messages.untrash failed with HTTP \(httpResponse.statusCode) for message \(messageId)")
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            return try JSONDecoder().decode(GmailMessage.self, from: data)
        }
    }

    /// Permanently delete (cannot be undone).
    public func deleteMessage(
        accessToken: String,
        messageId: String,
        quotaKey: String = GmailQuotaScope.current
    ) async throws {
        try await withRetry(maxRetries: 3) {
            try await self.meter(self.unitCost.messagesDelete, key: quotaKey)
            let url = try self.simpleURL("\(self.baseURL)/messages/\(messageId)")

            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30

            let (_, response) = try await self.send(request, quotaKey: quotaKey)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GmailAPIError.invalidResponse
            }

            if (500...599).contains(httpResponse.statusCode) || httpResponse.statusCode == 429 {
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                self.logger.error("Gmail messages.delete failed with HTTP \(httpResponse.statusCode) for message \(messageId)")
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }
        }

        logger.info("Permanently deleted message \(messageId)")
    }

    // MARK: - Send / Drafts

    /// Send `rawMessage` — a base64url-encoded RFC 2822 message the caller
    /// built. 100 units; never retried on a client-side timeout.
    @discardableResult
    public func sendMessage(
        accessToken: String,
        rawMessage: String,
        threadId: String? = nil,
        quotaKey: String = GmailQuotaScope.current
    ) async throws -> SendMessageResponse {
        // retryClientErrors: false — messages.send is NOT idempotent (Gmail has
        // no idempotency-key surface), so a CLIENT-side timeout
        // must NOT trigger a re-POST: the server may have accepted the first
        // attempt, and retrying would double-send. A client timeout surfaces as
        // a failure after one attempt (~60s) → the caller reverts to a failed
        // state fast. 5xx/429 remain retryable (server rejected → safe).
        try await withRetry(maxRetries: 3, retryClientErrors: false) {
            // 100 units — the most expensive call in the API, and the reason a
            // send must never sit behind a backfill's queue. It rides the
            // INTERACTIVE lane (the task-local default): a person is waiting.
            // Unparkable: a cooldown left by a backfill's 429 must not hold a
            // person's outgoing mail for a minute (or ten). The send is still
            // charged and still reports any rate signal (`send(_:quotaKey:)`),
            // so bulk backs off; its own 429 gets `withRetry`'s short backoff.
            try await self.meter(self.unitCost.messagesSend, key: quotaKey, parkable: false)
            let url = try self.simpleURL("\(self.baseURL)/messages/send")

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 60

            var body: [String: Any] = ["raw": rawMessage]
            if let threadId {
                body["threadId"] = threadId
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await self.send(request, quotaKey: quotaKey)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GmailAPIError.invalidResponse
            }

            if (500...599).contains(httpResponse.statusCode) || httpResponse.statusCode == 429 {
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            // Gmail reports per-user RATE LIMITING as 403, not 429 — only the
            // body's reason tells it apart from a real permission refusal.
            if httpResponse.statusCode == 403 {
                throw self.gmailError(from: httpResponse, body: data, call: "sendMessage")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                self.logger.error("Gmail messages.send failed with HTTP \(httpResponse.statusCode)")
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            return try JSONDecoder().decode(SendMessageResponse.self, from: data)
        }
    }

    public func createDraft(
        accessToken: String,
        rawMessage: String,
        threadId: String? = nil,
        quotaKey: String = GmailQuotaScope.current
    ) async throws -> DraftResponse {
        try await withRetry(maxRetries: 3) {
            try await self.meter(self.unitCost.draftsCreate, key: quotaKey)
            let url = try self.simpleURL("\(self.baseURL)/drafts")

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30

            var messageBody: [String: Any] = ["raw": rawMessage]
            if let threadId = threadId {
                messageBody["threadId"] = threadId
            }
            let body: [String: Any] = ["message": messageBody]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await self.send(request, quotaKey: quotaKey)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GmailAPIError.invalidResponse
            }

            if (500...599).contains(httpResponse.statusCode) || httpResponse.statusCode == 429 {
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            // Gmail reports per-user RATE LIMITING as 403, not 429 — only the
            // body's reason tells it apart from a real permission refusal.
            if httpResponse.statusCode == 403 {
                throw self.gmailError(from: httpResponse, body: data, call: "createDraft")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                self.logger.error("Gmail drafts.create failed with HTTP \(httpResponse.statusCode)")
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            return try JSONDecoder().decode(DraftResponse.self, from: data)
        }
    }

    @discardableResult
    public func updateDraft(
        accessToken: String,
        draftId: String,
        rawMessage: String,
        threadId: String? = nil,
        quotaKey: String = GmailQuotaScope.current
    ) async throws -> DraftResponse {
        try await withRetry(maxRetries: 3) {
            try await self.meter(self.unitCost.draftsUpdate, key: quotaKey)
            let url = try self.simpleURL("\(self.baseURL)/drafts/\(draftId)")

            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30

            var messageBody: [String: Any] = ["raw": rawMessage]
            if let threadId = threadId {
                messageBody["threadId"] = threadId
            }
            let body: [String: Any] = ["message": messageBody]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await self.send(request, quotaKey: quotaKey)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GmailAPIError.invalidResponse
            }

            if (500...599).contains(httpResponse.statusCode) || httpResponse.statusCode == 429 {
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            // Gmail reports per-user RATE LIMITING as 403, not 429 — only the
            // body's reason tells it apart from a real permission refusal.
            if httpResponse.statusCode == 403 {
                throw self.gmailError(from: httpResponse, body: data, call: "updateDraft")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                self.logger.error("Gmail drafts.update failed with HTTP \(httpResponse.statusCode) for draft \(draftId)")
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            return try JSONDecoder().decode(DraftResponse.self, from: data)
        }
    }

    public func deleteDraft(
        accessToken: String,
        draftId: String,
        quotaKey: String = GmailQuotaScope.current
    ) async throws {
        try await withRetry(maxRetries: 3) {
            try await self.meter(self.unitCost.draftsDelete, key: quotaKey)
            let url = try self.simpleURL("\(self.baseURL)/drafts/\(draftId)")

            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30

            let (_, response) = try await self.send(request, quotaKey: quotaKey)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GmailAPIError.invalidResponse
            }

            if (500...599).contains(httpResponse.statusCode) || httpResponse.statusCode == 429 {
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            // Idempotent: 404/410 means the draft is already gone (sent, or
            // deleted on another device) — the desired end state, not a
            // failure. Treat as success so a discard/cleanup never "fails"
            // because the work was already done (and so a retried delete after
            // a flaky first attempt still resolves cleanly).
            if httpResponse.statusCode == 404 || httpResponse.statusCode == 410 {
                self.logger.info("Gmail drafts.delete: draft \(draftId) already gone (HTTP \(httpResponse.statusCode)) — treating as success")
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                self.logger.error("Gmail drafts.delete failed with HTTP \(httpResponse.statusCode) for draft \(draftId)")
                throw GmailAPIError.httpError(statusCode: httpResponse.statusCode)
            }
        }

        logger.info("Deleted draft \(draftId)")
    }

    // MARK: - Auth rejection

    /// A batch whose 401s outlived the one forced refresh is a CREDENTIAL
    /// failure, not a rate one. Throwing it — rather than handing the ids back
    /// as plain leftovers — is deliberate: a full sync would otherwise spend
    /// its whole leftover-drain budget re-asking with a token Gmail keeps
    /// refusing, and the on-demand paths would read it as "try later" instead
    /// of "sign in again". A quick sync that throws stamps nothing, so the
    /// page replays once the account is fixed.
    ///
    /// Only for a refreshable source: a `.fixed` token never got its refresh,
    /// so its 401s stay leftovers for the caller to judge.
    static func throwIfAuthRejected<T>(_ outcome: BatchFetchOutcome<T>, tokenSource: GmailTokenSource) throws {
        guard outcome.authRejected, tokenSource.canRefresh else { return }
        throw refreshedTokenRejected(tokenSource)
    }

    // MARK: - Error classification

    /// Translate a failing HTTP response into a typed error, disambiguating
    /// Gmail's 403.
    ///
    /// 403 is overloaded: per-user rate limiting arrives as 403 with a
    /// `usageLimits` reason, a real refusal as 403 with
    /// `insufficientPermissions`/`forbidden`. Only the body separates them, and
    /// treating a rate signal as permanent is what lost 44% of a year's mail
    /// (t-172bfc74). A rate reason becomes `.rateLimitExceeded`, which
    /// `withRetry` already knows is transient and worth the longer backoff.
    func gmailError(from response: HTTPURLResponse, body: Data, call: String) -> GmailAPIError {
        if response.statusCode == 403 {
            let classification = GmailErrorClassification.classify(body: body)
            logger.warning("Gmail \(call, privacy: .public) HTTP 403 (\(classification.reason ?? "no reason", privacy: .public))")
            if classification.isRateLimit { return .rateLimitExceeded }
        }
        return .httpError(statusCode: response.statusCode)
    }

    // MARK: - Retry

    /// Retry helper with exponential backoff. Retries 5xx, 429, and transient
    /// network errors. Rate-limit errors get a longer base delay.
    /// - Parameter retryClientErrors: retry client-side transport failures
    ///   (URLSession timeout / connection-lost). Safe for IDEMPOTENT GETs, but
    ///   DANGEROUS for a non-idempotent write like `messages.send`: a client
    ///   timeout is ambiguous (the server may have already accepted the send),
    ///   so retrying risks a DOUBLE-SEND. Send passes `false` → a client timeout
    ///   surfaces as a failure after one attempt (~60s) instead of ~3 minutes of
    ///   re-POSTing. 5xx/429 stay retryable regardless: those are server-side
    ///   rejections (the message was NOT accepted), so a retry can't duplicate.
    /// Internal (not private) so the retry semantics — especially the
    /// non-retryable client-timeout contract for `messages.send` — can be
    /// unit-tested directly (`@testable`).
    /// - Parameter rateLimitFloor: minimum base delay applied to a RATE-LIMIT
    ///   retry. Defaults to 5s for callers that do their own pacing nowhere
    ///   else. The batch path passes 0: `GmailQuotaBucket` has already parked
    ///   the account for its cooldown (≥60s) and is consulted inside the
    ///   retried closure, so a second fixed backoff on top is double-counting.
    func withRetry<T>(
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 1.0,
        rateLimitFloor: TimeInterval = 5.0,
        retryClientErrors: Bool = true,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var currentRetry = 0

        while true {
            do {
                return try await operation()
            } catch {
                currentRetry += 1

                let isTransient: Bool
                let isRateLimit: Bool
                if let gmailError = error as? GmailAPIError {
                    switch gmailError {
                    case .httpError(let statusCode):
                        isTransient = (500...599).contains(statusCode) || statusCode == 429
                        isRateLimit = statusCode == 429
                    case .rateLimitExceeded, .quotaExceeded:
                        isTransient = true
                        isRateLimit = true
                    default:
                        isTransient = false
                        isRateLimit = false
                    }
                } else {
                    let nsError = error as NSError
                    isTransient = retryClientErrors &&
                                 nsError.domain == NSURLErrorDomain &&
                                 (nsError.code == NSURLErrorTimedOut || nsError.code == NSURLErrorNetworkConnectionLost)
                    isRateLimit = false
                }

                if currentRetry > maxRetries || !isTransient {
                    throw error
                }

                let effectiveBase = isRateLimit ? max(baseDelay, rateLimitFloor) : baseDelay
                let delay = effectiveBase * pow(2.0, Double(currentRetry - 1))
                let cause: String
                if let gmailError = error as? GmailAPIError, case .httpError(let code) = gmailError {
                    cause = "HTTP \(code)"
                } else {
                    cause = String(describing: error)
                }
                logger.warning("Transient \(cause, privacy: .public), retrying in \(String(format: "%.1f", delay))s (attempt \(currentRetry)/\(maxRetries))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
}

// MARK: - Array Chunking Extension

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
