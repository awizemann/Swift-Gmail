---
created: 2026-10-23
updated: 2026-10-23
source_sha: 93db6131588ac2ca387290d081599f3cd4718560
source_paths: Sources/SwiftGmail/GmailAPIClient+Batch.swift, Sources/SwiftGmail/BatchFetchOutcome.swift
source_paths_inferred: false
---

# Batch Operations

Batch operations fetch or act on many messages in a single HTTP request. This is essential for mail sync: fetching 100 message metadata in one request instead of 100 sequential requests cuts latency and bandwidth dramatically.

## Why batch?

Gmail's `/batch` endpoint accepts many `GET`, `POST`, `PATCH`, or `DELETE` operations packaged as multipart MIME. A single request:

- Reduces round-trip latency by ~99x for 100 messages.
- Reduces connection overhead and TLS handshakes.
- Preserves quota budget (one multipart request uses fewer quota units than 100 individual requests).

SwiftGmail handles the complexity: multipart encoding, per-part error handling, automatic retry of transient failures, and fallback to per-id requests if the server rejects the batch envelope.

## BatchFetchOutcome

A batched fetch returns `BatchFetchOutcome<Message>` (from `Sources/SwiftGmail/BatchFetchOutcome.swift:29`), not a simple array. This makes partial success explicit:

```swift
public struct BatchFetchOutcome<Element: Sendable>: Sendable {
    public let fetched: [Element]
    public let leftover: BatchLeftover<Element.ID>
}
```

The `leftover` struct holds four separate lists:

- **Transient** — 429 (rate-limited) or 5xx (server error); retry later.
- **Failed** — Other non-auth errors (e.g., malformed ID); these will not succeed on retry.
- **NotFound** — 404; the message does not exist or was deleted.
- **AuthRejected** — 401; the token is invalid or expired.

```swift
public struct BatchLeftover<ID: Hashable & Sendable>: Sendable {
    public let transient: [ID]
    public let failed: [ID]
    public let notFound: [ID]
    public let authRejected: [ID]
}
```

A caller cannot mistake a partial array for the whole answer. If you wanted all 100 messages and got 73, `outcome.leftover.transient`, `outcome.leftover.notFound`, and `outcome.leftover.authRejected` tell you exactly what happened.

## Per-part retry

SwiftGmail retries transient errors (429, 5xx) at the part level:

1. Send the batch.
2. Collect results. For each part:
   - 2xx → include in `fetched`.
   - 401 → try to refresh the token and re-issue that single part.
   - 429/5xx → re-issue that part individually after waiting (respecting quota).
   - Other errors → include in `leftover.failed`.

If a 401 is detected and the token is refreshed, the entire batch is re-issued with the new token before falling back to per-id retries.

## Fallback to per-id

If the batch endpoint returns an error for the entire request (e.g., 414 URI Too Long, 413 Payload Too Large), SwiftGmail automatically switches to issuing the IDs one at a time.

From the caller's perspective, this is transparent; `BatchFetchOutcome` is still the result type.

## Usage

### Fetch messages in one batch

```swift
let outcome = try await client.getMessagesOutcome(
    tokenSource: tokens,
    messageIds: ["id1", "id2", "id3"],
    format: .metadata,
    quotaKey: "user@example.com"
)

ingest(outcome.fetched)  // 1–3 messages, depending on errors
retryLater(outcome.leftover.transient)  // 429/5xx; try again soon
logNotFound(outcome.leftover.notFound)  // these were deleted
logAuthError(outcome.leftover.authRejected)  // token invalid; refresh
```

### Other batch operations

- `modifyMessagesOutcome(...)` — Modify labels, marking as read, etc., for many messages.
- `trashMessagesOutcome(...)` — Trash many messages in one batch.
- `deleteMessagesOutcome(...)` — Permanently delete many messages.

All return `BatchFetchOutcome` (or `BatchOutcome` for operations without a result payload) with the same four-way split.

## Quota and batching

Each call to a batch endpoint costs one or more quota units, depending on the operation and the result mix:

- Successful GET costs 1 unit per message.
- Successful PATCH/DELETE costs 1 unit per message.
- 404 (not found) costs 1 unit.
- Retried (429/5xx re-issued) costs 1 additional unit per retry.

The quota bucket debits as follows:

1. Before the batch is sent, the client estimates the cost (number of IDs × unit cost for the operation) and waits if needed.
2. After the batch, if transient errors were retried, the bucket is debited for the additional retries.

Batch is more quota-efficient than per-id in most cases because the batch envelope overhead is lower.

---

_Last updated: 2026-10-23 — content_