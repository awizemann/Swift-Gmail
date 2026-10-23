---
created: 2026-10-23
updated: 2026-10-23
source_sha: 93db6131588ac2ca387290d081599f3cd4718560
source_paths: Sources/SwiftGmail
source_paths_inferred: false
---

# Quota & Rate Management

Gmail's REST API has per-user daily quotas and per-user rate limits. SwiftGmail meters every request against a per-user quota bucket and adapts to server signals to stay within limits.

## Why quota matters

Gmail quotas are per-user and rescan daily:

- **Typical user**: 100 million quota units per day (enough for ~100k full-message reads or 1 million metadata queries).
- **Advanced users**: quota bumped via request to Google.
- **Once exceeded**: 403 Forbidden with `dailyLimitExceeded` in the error body; the account is locked for 24 hours.

A naive mail sync—fetching every message's full content without metering—can exhaust quota in seconds. SwiftGmail prevents this by:

1. Assigning a documented unit cost to every operation (`GmailUnitCost`).
2. Debiting each call against a per-user quota bucket.
3. Waiting or parking bulk work if the bucket is exhausted.
4. Adapting the bucket's refill rate to server 429 and 403 signals.

## Unit costs

`GmailUnitCost` is the documented cost of an operation:

```swift
GmailUnitCost.messages.list  // 1 unit
GmailUnitCost.messages.get(format: .full)  // 15 units (full message with headers)
GmailUnitCost.messages.get(format: .metadata)  // 1 unit
GmailUnitCost.messages.modify  // 1 unit
```

These come directly from [Google's quota documentation](https://developers.google.com/gmail/api/reference/quota) and are baked into the client. When you call `client.getMessage(format: .full, ...)`, the client knows it costs 15 units.

## Quota bucket

`GmailQuotaBucket` (from [[swift-gmail/architecture/quota-rate-management]]) is a per-user token bucket:

```swift
let bucket = GmailQuotaBucket(quotaKey: "user@example.com")

// Before each request:
let remaining = try await bucket.debit(
    operation: .messages.get(format: .full),  // 15 units
    wait: .interactive  // interactive or bulk
)
```

The bucket:

- Tracks current capacity (initially a fraction of the daily quota).
- Refills over time at a server-determined rate.
- Waits if a debit would exhaust capacity.
- Adapts its refill rate based on server 429 (too many requests) and 403 (rate-limited) responses.

### AIMD adaptation

The bucket uses **AIMD** (Additive Increase, Multiplicative Decrease):

- **On 429 or rate-limit 403**: Multiply the bucket capacity by 0.5 (back off).
- **On each successful request**: Slowly increase the capacity (catch up to the actual quota).

This prevents throttling and quota exhaustion: the bucket self-adjusts to the server's tolerance and the app's usage pattern.

## Interactive versus bulk lanes

SwiftGmail maintains two logical lanes:

- **Interactive lane** — User-facing operations (fetch a message for display, refresh the mailbox). Paced at a normal rate.
- **Bulk lane** — Background backfill (sync 10 years of mail history). Parked behind interactive to avoid starving the UI.

```swift
// Fetch 3 messages for the user—interactive lane
let msg = try await client.getMessage(accessToken: token, ...)

// Backfill 10,000 messages—bulk lane, parked if interactive work is pending
try await GmailQuotaLane.withBulkLane {
    for id in messageIds {
        let msg = try await client.getMessage(accessToken: token, ...)
    }
}
```

The bulk lane suspends when interactive work is detected, resuming after a cooldown (typically a few seconds). This ensures the UI stays responsive even during large syncs.

## Server signals

Gmail returns specific errors when you approach limits:

- **429 Too Many Requests** — Rate-limited. The bucket backs off and re-issues the request after waiting.
- **403 Forbidden with `dailyLimitExceeded`** — Daily quota exhausted. The bucket stops accepting new requests until midnight UTC.
- **403 Forbidden with `userRateLimitExceeded` or `rateLimitExceeded`** — Rate-limited (per-minute or per-second). The bucket backs off.

SwiftGmail detects these in the response body and adapts. See [API Conventions](API-Conventions) for more on 403 ambiguity. [[swift-gmail/conventions/api-conventions-known-gotchas]]

## Usage

You don't directly create or manage a quota bucket. The `GmailAPIClient` does it for you:

```swift
// Client creates a bucket for "user@example.com" on first use
let message = try await client.getMessage(
    accessToken: token,
    messageId: "id",
    quotaKey: "user@example.com"  // Creates or reuses bucket for this key
)
```

Buckets are cached per `GmailAPIClient` instance. If you create a new client, old buckets are discarded.

### Persisting quota across restarts

The quota bucket state (current capacity, refill rate) is saved to disk so it survives an app restart. This prevents a cold-start from resetting rate-limit adaptation.

### Multiple accounts

If your app syncs multiple Gmail accounts, each gets its own bucket:

```swift
let message1 = try await client.getMessage(..., quotaKey: "alice@example.com")
let message2 = try await client.getMessage(..., quotaKey: "bob@example.com")
// Two separate buckets, two separate refill rates, two separate daily limits
```

---

_Last updated: 2026-10-23 — content_