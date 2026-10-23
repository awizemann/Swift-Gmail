//
//  GmailAPIModels.swift
//  SwiftGmail
//
//  Codable response models and supporting types for the Gmail REST API.
//  Lifted verbatim from Threader; access modifiers raised to `public`
//  for cross-module use. No behavioral changes.
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

public enum GmailAPIError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case rateLimitExceeded
    case quotaExceeded
    case historyIdExpired
    case parsingError
    case invalidURL
    /// A refreshed access token was still rejected (401), so the credential —
    /// not the rate — is the problem. Hosts can substitute their own error
    /// through `GmailCredentialErrors`.
    case authenticationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Gmail API"
        case .httpError(let statusCode):
            return "Gmail API error (HTTP \(statusCode))"
        case .rateLimitExceeded:
            return "Gmail API rate limit exceeded"
        case .quotaExceeded:
            return "Gmail API quota exceeded"
        case .historyIdExpired:
            return "Gmail historyId expired - full sync required"
        case .parsingError:
            return "Failed to parse Gmail API response"
        case .invalidURL:
            return "Failed to construct Gmail API URL"
        case .authenticationFailed(let detail):
            return "Gmail authentication failed: \(detail)"
        }
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
    /// True when the failure is Gmail saying "too fast / out of quota".
    let isRateLimit: Bool

    /// Reason tokens Gmail uses for rate/quota exhaustion. All four arrive as
    /// HTTP 403 (`rateLimitExceeded` also arrives as 429).
    static let rateReasons: Set<String> = [
        "userratelimitexceeded",
        "ratelimitexceeded",
        "quotaexceeded",
        "dailylimitexceeded"
    ]

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
            isRateLimit: isRateReason || isRateStatus
        )
    }
}
