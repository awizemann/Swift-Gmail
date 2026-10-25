//
//  GmailAPIModels.swift
//  SwiftGmail
//
//  Codable response models and supporting types for the Gmail REST API.
//

import Foundation

// MARK: - Response Models

public struct ListMessagesResponse: Codable, Sendable {
    public let messages: [MessageRef]?
    public let nextPageToken: String?
    public let resultSizeEstimate: Int?

    public struct MessageRef: Codable, Sendable {
        public let id: String
        public let threadId: String
    }
}

public struct ListLabelsResponse: Codable, Sendable {
    public let labels: [GmailLabel]?
}

public struct GmailLabel: Codable, Sendable {
    public let id: String
    public let name: String
    public let type: String?
    public let messageListVisibility: String?
    public let labelListVisibility: String?
    public let messagesTotal: Int?
    public let messagesUnread: Int?
    public let threadsTotal: Int?
    public let threadsUnread: Int?
    public let color: LabelColor?

    public struct LabelColor: Codable, Sendable {
        public let textColor: String?
        public let backgroundColor: String?
    }

    public var isSystem: Bool {
        type == "system"
    }

    public var isCategory: Bool {
        id.hasPrefix("CATEGORY_")
    }

    public var shouldShowInList: Bool {
        if isCategory { return false }
        if labelListVisibility == "labelHide" { return false }
        return true
    }

    public var parentPath: String? {
        guard name.contains("/") else { return nil }
        let components = name.components(separatedBy: "/")
        return components.dropLast().joined(separator: "/")
    }

    public var displayName: String {
        if name.contains("/") {
            return name.components(separatedBy: "/").last ?? name
        }
        return name
    }
}

public struct HistoryListResponse: Codable, Sendable {
    public let history: [HistoryRecord]?
    public let nextPageToken: String?
    public let historyId: String?

    public struct HistoryRecord: Codable, Sendable {
        public let id: String
        public let messages: [MessageRef]?
        public let messagesAdded: [MessageChange]?
        public let messagesDeleted: [MessageChange]?
        public let labelsAdded: [LabelChange]?
        public let labelsRemoved: [LabelChange]?

        public struct MessageRef: Codable, Sendable {
            public let id: String
            public let threadId: String
        }

        public struct MessageChange: Codable, Sendable {
            public let message: MessageRef
        }

        public struct LabelChange: Codable, Sendable {
            public let message: MessageRef
            public let labelIds: [String]
        }
    }
}

public struct ListThreadsResponse: Codable, Sendable {
    public let threads: [ThreadRef]?
    public let nextPageToken: String?
    public let resultSizeEstimate: Int?

    public struct ThreadRef: Codable, Sendable {
        public let id: String
        public let snippet: String?
        public let historyId: String?
    }
}

public struct GmailThread: Codable, Sendable {
    public let id: String
    public let historyId: String?
    public let messages: [GmailMessage]
}

public struct GmailMessage: Codable, Sendable {
    public let id: String
    public let threadId: String
    public let labelIds: [String]?
    public let snippet: String
    public let historyId: String?
    public let internalDate: String  // Unix timestamp in milliseconds
    public let payload: MessagePayload?
    public let sizeEstimate: Int?

    public struct MessagePayload: Codable, Sendable {
        public let partId: String?
        public let mimeType: String?
        public let filename: String?
        public let headers: [Header]?
        public let body: Body?
        public let parts: [MessagePart]?

        public struct Header: Codable, Sendable {
            public let name: String
            public let value: String
        }

        public struct Body: Codable, Sendable {
            public let attachmentId: String?
            public let size: Int
            public let data: String?  // Base64 URL-safe encoded
        }
    }

    public struct MessagePart: Codable, Sendable {
        public let partId: String?
        public let mimeType: String?
        public let filename: String?
        public let headers: [MessagePayload.Header]?
        public let body: MessagePayload.Body?
        public let parts: [MessagePart]?
    }

    // MARK: - Computed Properties

    public var receivedDate: Date {
        guard let milliseconds = Double(internalDate) else {
            return Date()
        }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    public func headerValue(for name: String) -> String? {
        payload?.headers?.first { $0.name.lowercased() == name.lowercased() }?.value
    }

    public var subject: String {
        headerValue(for: "Subject") ?? "(No Subject)"
    }

    public var fromAddress: String {
        headerValue(for: "From") ?? ""
    }

    public var toAddresses: String {
        headerValue(for: "To") ?? ""
    }

    public var ccAddresses: String? {
        headerValue(for: "Cc")
    }

    /// Bcc header from the parsed payload. Gmail DOES return it for a draft at
    /// `format=full` (dogfood-confirmed 2026-06-22); nil for ordinary received
    /// mail (Bcc is stripped on delivery, but a draft retains it).
    public var bccAddresses: String? {
        headerValue(for: "Bcc")
    }

    public var messageIdHeader: String? {
        headerValue(for: "Message-ID")
    }

    public var inReplyTo: String? {
        headerValue(for: "In-Reply-To")
    }

    public var references: String? {
        headerValue(for: "References")
    }

    public var isRead: Bool {
        !(labelIds?.contains("UNREAD") ?? false)
    }

    public var isStarred: Bool {
        labelIds?.contains("STARRED") ?? false
    }

    public var isInInbox: Bool {
        labelIds?.contains("INBOX") ?? false
    }
}

public struct SendMessageResponse: Codable, Sendable {
    public let id: String
    public let threadId: String
    public let labelIds: [String]?
}

public struct DraftResponse: Codable, Sendable {
    public let id: String
    /// Optional: `drafts.list` can return a partial draft (message absent for a
    /// mid-creation draft). Keeping this Optional means one such entry can't
    /// throw out of the whole list decode and abort the pull — the draft id is
    /// still authoritative (`id` above), we just can't hydrate its body. The
    /// `drafts.create` / `drafts.update` responses always populate it.
    public let message: DraftMessage?

    public struct DraftMessage: Codable, Sendable {
        public let id: String
        public let threadId: String?
        public let labelIds: [String]?
    }
}

/// `users.drafts.list` — returns partial draft resources (each carries the
/// stable draft `id` and a minimal `message` ref with the current message
/// id + threadId). The provider pulls full bodies in a follow-up batched
/// `messages.get`, re-pairing by message id. Paginated via `nextPageToken`.
public struct ListDraftsResponse: Codable, Sendable {
    public let drafts: [DraftResponse]?
    public let nextPageToken: String?
    public let resultSizeEstimate: Int?
}

/// Response from `users.getProfile`. Returns the current historyId for the
/// account — used as the authoritative fallback when a historical sync
/// completes without one (or when the stored historyId is stale and the
/// incremental sync returns nil).
public struct GmailProfile: Codable, Sendable {
    public let emailAddress: String
    public let messagesTotal: Int?
    public let threadsTotal: Int?
    public let historyId: String
}

// MARK: - Enums

public enum MessageFormat: String, Sendable {
    case full       // Full message content including body
    case metadata   // Headers only, no body
    case minimal    // Just IDs and labels
    case raw        // Raw RFC 2822 format
}

/// What Gmail said about a failing request, parsed from its JSON error body
/// and headers. Every field is optional: a proxy's HTML page or an empty body
/// yields a detail with nothing in it rather than no error at all.
public struct GmailErrorDetail: Sendable, Equatable, Hashable {
    /// `error.errors[0].reason` (e.g. `insufficientPermissions`,
    /// `userRateLimitExceeded`), else `error.status` (e.g. `PERMISSION_DENIED`).
    public let reason: String?
    /// `error.message`, Gmail's human-readable explanation.
    public let message: String?
    /// The `Retry-After` header, seconds form only.
    public let retryAfter: TimeInterval?

    public init(reason: String? = nil, message: String? = nil, retryAfter: TimeInterval? = nil) {
        self.reason = reason
        self.message = message
        self.retryAfter = retryAfter
    }
}

public enum GmailAPIError: Error, LocalizedError, Equatable {
    case invalidResponse
    /// A non-2xx response that no more specific case covers. `detail` is nil
    /// only when the error was not built from a response.
    case httpError(statusCode: Int, detail: GmailErrorDetail? = nil)
    /// Per-user RATE limit (429, or a 403 with a rate reason). Transient —
    /// `withRetry` backs off and retries it.
    case rateLimitExceeded
    /// The DAILY / project quota is spent (`dailyLimitExceeded`,
    /// `quotaExceeded`). Not retried: it will not clear within a backoff.
    case quotaExceeded
    case historyIdExpired
    case parsingError
    case invalidURL
    /// A refreshed access token was still rejected (401), so the credential —
    /// not the rate — is the problem. Hosts can substitute their own error
    /// through `GmailCredentialErrors`.
    case authenticationFailed(String)
    /// The call's deadline — the earliest of `GmailRetryPolicy.maxElapsed`,
    /// `GmailRetryPolicy.deadline` and any outer scope's — would pass before
    /// the quota bucket let the request go. Thrown BEFORE the request is sent,
    /// with nothing debited. `retryAfter` is how long until the bucket would
    /// let this key go (the remaining park), or nil when not known — a host
    /// can reschedule on it.
    case deadlineExceeded(retryAfter: TimeInterval?)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Gmail API"
        case .httpError(let statusCode, let detail):
            if let reason = detail?.reason {
                return "Gmail API error (HTTP \(statusCode), \(reason))"
            }
            return "Gmail API error (HTTP \(statusCode))"
        case .rateLimitExceeded:
            return "Gmail API rate limit exceeded"
        case .quotaExceeded:
            return "Gmail API daily quota exceeded"
        case .historyIdExpired:
            return "Gmail historyId expired - full sync required"
        case .parsingError:
            return "Failed to parse Gmail API response"
        case .invalidURL:
            return "Failed to construct Gmail API URL"
        case .authenticationFailed(let detail):
            return "Gmail authentication failed: \(detail)"
        case .deadlineExceeded(let retryAfter):
            if let retryAfter {
                return "Gmail request not sent: it would have waited \(Int(retryAfter.rounded(.up)))s, past its deadline"
            }
            return "Gmail request not sent: its deadline passed"
        }
    }

    /// Was `error` Gmail's per-user RATE limit? Covers both shapes a rate
    /// signal surfaces as: `.rateLimitExceeded` (a rate-reason 403) and
    /// `.httpError(429, _)` (a 429 whose retries ran out, including a
    /// `/batch` envelope's). Also true for an `.httpError` whose `detail.reason`
    /// is a rate token (the client itself maps those to `.rateLimitExceeded`,
    /// but a host may build or forward one). The `quotaExceeded` REASON token
    /// counts (a per-minute quota); the daily limit does not — neither the
    /// `.quotaExceeded` case nor a `dailyLimitExceeded` reason, even on a 429.
    /// False for `.deadlineExceeded`.
    public static func isRateLimit(_ error: any Error) -> Bool {
        switch error as? GmailAPIError {
        case .rateLimitExceeded: return true
        case .httpError(let statusCode, let detail):
            let reason = detail?.reason?.lowercased()
            if let reason, GmailErrorClassification.dailyReasons.contains(reason) { return false }
            if statusCode == 429 { return true }
            guard let reason else { return false }
            let rateTokens = GmailErrorClassification.rateReasons
                .union(GmailErrorClassification.rateStatuses)
                .subtracting(GmailErrorClassification.dailyReasons)
            return rateTokens.contains(reason)
        default: return false
        }
    }

    /// Might Gmail have ACCEPTED the non-idempotent request (`sendMessage`,
    /// `createDraft`) that threw `error`? Auto-retry a send only when this
    /// returns false; on true, check (Sent folder, drafts list) or ask.
    ///
    /// When unsure it answers true: a duplicate send is worse than a
    /// question. In particular `URLError.cancelled` and `CancellationError`
    /// ALWAYS return true — a cancellation during the pre-send quota wait
    /// looks the same as one with the request in flight, and true is the
    /// safe answer for both.
    ///
    /// Credential failures: a host's own auth error (the one its
    /// `GmailCredentialErrors` recognises) is unknown here, so it comes back
    /// true. Check your own auth error FIRST — a dead credential means the
    /// request never reached Gmail. (`.authenticationFailed`, this package's
    /// own, is handled: false.)
    public static func isAmbiguousDelivery(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let gmailError = error as? GmailAPIError {
            switch gmailError {
            case .httpError(let statusCode, _):
                // 4xx (429 and 401 included) is a refusal; 5xx can come after acceptance.
                return !(400...499).contains(statusCode)
            case .rateLimitExceeded, .quotaExceeded:
                // Rate / quota refusals: Gmail answers them before accepting.
                return false
            case .deadlineExceeded:
                // Thrown by the quota wait, before the request was sent.
                return false
            case .invalidURL:
                // The request could not even be built.
                return false
            case .authenticationFailed:
                // A refreshed token was still answered 401 — refused.
                return false
            case .historyIdExpired:
                // Only `history.list` throws it; never a send.
                return false
            case .invalidResponse, .parsingError:
                // Something came back that we could not read: it may have
                // been the success response.
                return true
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .secureConnectionFailed:
                // No connection was made, so no request reached Gmail.
                return false
            default:
                // Timed out, connection lost, unreadable / bad response,
                // cancelled — and anything unrecognised.
                return true
            }
        }
        return true
    }
}

// MARK: - Error bodies

/// Gmail's JSON error envelope, as it arrives on a failing request AND on a
/// failing sub-response inside a `/batch` reply.
///
/// Why this type exists (t-172bfc74): Gmail reports per-user RATE LIMITING as
/// HTTP **403**, not 429 — the status code alone cannot tell "you are going too
/// fast" apart from "you may not read this mailbox". The batch layer classified
/// by status only, so 159,080 rate-limited sub-responses in nine hours were
/// dropped as permanent failures and a full-sync window was recorded complete
/// with ~44% of the year's mail missing. The reason string in the body is the
/// only signal that distinguishes them.
///
/// Shape:
/// ```json
/// {"error":{"code":403,"message":"…",
///           "errors":[{"domain":"usageLimits","reason":"userRateLimitExceeded"}],
///           "status":"PERMISSION_DENIED"}}
/// ```
struct GmailErrorBody: Decodable, Sendable {

    struct Payload: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let domain: String?
            let reason: String?
            let message: String?
        }
        let code: Int?
        let message: String?
        let status: String?
        let errors: [Item]?
    }

    let error: Payload?
}

/// What a Gmail error body says about a failure: the reason string (for logs)
/// and whether it is a RATE signal (retry) or a permission refusal (drop).
struct GmailErrorClassification: Sendable {
    /// The first `error.errors[].reason`, else `error.status`, else nil.
    /// Safe to log `.public` — it is a fixed enum-ish token, never content.
    let reason: String?
    /// `error.message`, when present.
    var message: String? = nil
    /// True when the failure is Gmail saying "too fast / out of quota".
    let isRateLimit: Bool
    /// True when the reason is the DAILY / project quota rather than the
    /// per-user rate. A subset of `isRateLimit` (the bucket still backs off),
    /// but a caller must not retry it within the hour.
    var isDailyLimit: Bool = false

    /// Reason tokens Gmail uses for rate/quota exhaustion. All four arrive as
    /// HTTP 403 (`rateLimitExceeded` also arrives as 429).
    static let rateReasons: Set<String> = [
        "userratelimitexceeded",
        "ratelimitexceeded",
        "quotaexceeded",
        "dailylimitexceeded"
    ]

    /// The subset of `rateReasons` that means the day's quota is gone.
    /// `quotaExceeded` (like `RESOURCE_EXHAUSTED`) is deliberately NOT here:
    /// across Google APIs it usually names a per-minute or concurrency quota,
    /// which clears within a backoff.
    static let dailyReasons: Set<String> = ["dailylimitexceeded"]

    /// gRPC-style status that means the same thing.
    static let rateStatuses: Set<String> = ["resource_exhausted"]

    /// Classify a response/sub-response body. An unparseable or empty body is
    /// NOT a rate signal — the caller keeps whatever its status code implied,
    /// so a garbled 403 stays a permission refusal rather than looping forever.
    static func classify(body: Data) -> GmailErrorClassification {
        guard
            let decoded = try? JSONDecoder().decode(GmailErrorBody.self, from: body),
            let payload = decoded.error
        else {
            return GmailErrorClassification(reason: nil, isRateLimit: false)
        }

        let reasons = (payload.errors ?? []).compactMap(\.reason)
        let isRateReason = reasons.contains { rateReasons.contains($0.lowercased()) }
        let isRateStatus = rateStatuses.contains((payload.status ?? "").lowercased())

        return GmailErrorClassification(
            reason: reasons.first ?? payload.status,
            message: payload.message,
            isRateLimit: isRateReason || isRateStatus,
            isDailyLimit: reasons.contains { dailyReasons.contains($0.lowercased()) }
        )
    }
}
