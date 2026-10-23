---
created: 2026-10-23
updated: 2026-10-23
---

# API Conventions

SwiftGmail's API follows consistent patterns, with a few gotchas you'll encounter when working with Gmail's REST API directly.

## Entry point flavors

All operations come in two flavors: [[swift-gmail/conventions/api-conventions-known-gotchas]]

### One-shot (take a string token)

For simple queries where you know the token is fresh:

```swift
public func getMessage(
    accessToken: String,
    messageId: String,
    format: GetMessageFormat = .full,
    metadataHeaders: [String]? = nil,
    quotaKey: String
) async throws -> Message
```

You pass the token directly and the client handles the request. If a 401 is returned, the error is thrown immediately (no automatic refresh).

### Batched or long-lived (take a GmailTokenSource)

For operations that might need a refresh or that operate on many items:

```swift
public func getMessagesOutcome(
    tokenSource: GmailTokenSource,
    messageIds: [String],
    format: GetMessageFormat = .full,
    metadataHeaders: [String]? = nil,
    quotaKey: String
) async throws -> BatchFetchOutcome<Message>
```

You provide a token source (a closure); the client calls it before the request and again if a 401 arrives. Batch operations automatically retry transient errors and return `BatchFetchOutcome` with results and leftovers.

## Known gotchas in Gmail's API

### Plus sign in queries must be escaped

Gmail query syntax treats `+` as a space. If you search for an email address like `from:sender+tag@example.com`, you must URL-encode the `+` as `%2B`:

```swift
let query = "from:sender%2Btag@example.com"
let page = try await client.listMessages(accessToken: token, query: query, quotaKey: key)
```

SwiftGmail's URL construction handles this, but if you build your own query strings, beware.

### in:spam without includeSpamTrash returns nothing

By default, Gmail excludes spam and trash from search results. To search in spam, you must set `includeSpamTrash: true`:

```swift
let page = try await client.listMessages(
    accessToken: token,
    query: "in:spam from:sender@example.com",
    includeSpamTrash: true,
    quotaKey: key
)
```

### 403 means rate-limited OR forbidden—check the body

Gmail uses 403 Forbidden for two different errors:

1. **Rate-limited** — You've exceeded the per-minute request limit. The error body contains `rateLimitExceeded` or `userRateLimitExceeded`. The request should be retried after waiting.
2. **Forbidden** — You don't have permission (e.g., a suspended account, invalid scopes). The error body contains `forbidden` or `insufficientPermissions`. Retrying won't help.

SwiftGmail's quota bucket detects rate-limit 403s and backs off automatically. Other 403s are surfaced as errors.

### messages.send is not idempotent

Sending a message twice with the same request body creates two messages. There is no request deduplication key. If a send request times out, you must:

1. Check if the message was actually sent (via `listMessages` or `getMessage`).
2. Only retry if it was not sent.

SwiftGmail does not automatically retry `send` requests on timeout; you must handle this in your app.

### Draft IDs are not stable

If you modify a draft, its ID may change. Always re-fetch the draft list after modifying; don't cache IDs across writes.

### Profile information is read-only

The `getProfile()` method returns metadata about the account (quota usage, message/thread counts). You cannot modify it directly. To change profile settings (vacation responder, signature), use the Settings API (not included in SwiftGmail).

### Labels are case-sensitive

```swift
let labels = try await client.listLabels(accessToken: token, quotaKey: key)
// names are exactly as shown in Gmail: "Important", "All Mail", etc.
// "important" and "Important" are different labels
```

### Attachment IDs include the message ID

When you fetch attachments, the `attachmentId` is specific to the message:

```swift
let message = try await client.getMessage(
    accessToken: token,
    messageId: "msg123",
    format: .full,
    quotaKey: key
)

for part in message.payload?.parts ?? [] {
    if let attachmentId = part.filename {
        // To fetch this attachment later, you need both messageId and attachmentId
        let attachment = try await client.getAttachment(
            accessToken: token,
            messageId: "msg123",
            attachmentId: attachmentId,
            quotaKey: key
        )
    }
}
```

---

_Last updated: 2026-10-23 — content_