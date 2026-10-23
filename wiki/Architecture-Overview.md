---
created: 2026-10-23
updated: 2026-10-23
source_sha: 93db6131588ac2ca387290d081599f3cd4718560
source_paths: Sources/SwiftGmail
source_paths_inferred: false
---

# Architecture Overview

## Design philosophy

SwiftGmail is a **portable transport layer** for Gmail's REST API, not a mail client itself. It solves three hard problems:

1. **Quota metering** — Every call spends a known unit cost; the client adapts to server rate signals and keeps interactive work paced ahead of bulk backfill. [[swift-gmail/architecture/quota-rate-management]]
2. **Batch efficiency** — Fetch many messages in one request with per-part error tolerance, automatic retry of transient failures, and fallback to per-id requests if the server refuses the batch envelope.
3. **Token refresh on demand** — 401s are handled by the client; only the token source knows how to obtain a new credential. [[swift-gmail/architecture/token-management-pattern]]

Design priorities:

- **No external dependencies** [[swift-gmail/architecture/stack-minimal-dependencies]] — Foundation and `os` only. Your app owns the OAuth flow, persistence, and UI; the client is just the wire layer.
- **Swift 6 strict concurrency throughout** — Every public type is `Sendable`. Safe to call from any actor, safe to use in structured concurrency.
- **Offline by default** — All logic is verified locally; tests never touch the network. [[swift-gmail/conventions/testing-strategy]]

## Core components

### GmailAPIClient

`class GmailAPIClient` (in `Sources/SwiftGmail/GmailAPIClient.swift:15`) is the main entry point. It holds no state—all durable state lives in the quota bucket and the token source.

Methods come in two flavors:

- **One-shot** — Take a string token directly (e.g., `listMessages(accessToken:...)`) for quick operations where you know the token is fresh.
- **Batched or long-lived** — Take a `GmailTokenSource` (e.g., `getMessagesOutcome(tokenSource:...)`) so the client can refresh if a 401 arrives.

See [API Conventions](API-Conventions) for which methods are which. [[swift-gmail/conventions/api-conventions-known-gotchas]]

### Transport

`GmailAPIClient` is transport-agnostic. The default uses `URLSession`, but you can inject your own:

```swift
public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

let client = GmailAPIClient(transport: myTransport)
```

This enables testing (stub responses), request mutation (add headers), and protocol switching (HTTP/2 push, proxies).

### Quota bucket

`GmailQuotaBucket` (from [[swift-gmail/architecture/quota-rate-management]]) meters every request against a per-user budget. The bucket:

- Tracks the documented unit cost (`GmailUnitCost`) of each operation.
- Adapts to server 429 (too many requests) and 403 (rate-limited) signals using AIMD (additive-increase, multiplicative-decrease).
- Maintains two lanes: interactive (paced normally) and bulk (parked behind interactive, resuming after a cooldown).
- Survives relaunch; persists its state to the filesystem.

### Batch operations

`GmailBatchProtocol` and `BatchFetchOutcome` (in `Sources/SwiftGmail/GmailAPIClient+Batch.swift:44` and `Sources/SwiftGmail/BatchFetchOutcome.swift:29`) handle multi-message fetches. A batch request:

- Packs many `GET` requests into one multipart HTTP body.
- Handles per-part 404 (not found), 429/5xx (retry), and 401 (refresh and retry).
- Falls back to per-id requests if the server rejects the batch envelope.
- Returns `BatchFetchOutcome<Message>`, which splits results into `.fetched` and `.leftover` (with reason: transient, failed, not-found, auth-rejected).

See [Batch Operations](Batch-Operations) for details.

### Token source

`GmailTokenSource` is a closure that the client calls before each request:

```swift
public struct GmailTokenSource: Sendable {
    public var current: () async throws -> String
}
```

If a request returns 401, the client calls the source with the rejected token and expects a new one (or an error). The client retries exactly once with the new token. [[swift-gmail/architecture/token-management-pattern]]

## Data flow

1. **Caller** → constructs request parameters (message ID, query, etc.) and hands them to the client.
2. **GmailAPIClient** → builds a `URLRequest`, checks the quota bucket, and waits if needed.
3. **Quota bucket** → waits if bucket is exhausted or if bulk lane is parked; debits the operation's unit cost.
4. **Transport** → sends the HTTP request (default: `URLSession`; you can inject your own).
5. **Response** → decoded into domain types (`Message`, `Label`, `Thread`, etc.) or `BatchFetchOutcome` for batch ops.
6. **401 handling** — If the response is 401, the client calls the token source with the rejected token, gets a new one, rebuilds the request, and retries. Other errors are surfaced to the caller.

## Concurrency model

All public APIs are `async`. No callbacks, no `DispatchQueue`. Everything is based on structured concurrency:

```swift
async let message = client.getMessage(...)
async let labels = client.listLabels(...)
let (m, l) = try await (message, labels)  // both in parallel
```

Cancellation propagates; if the caller's task is cancelled, outstanding requests abort.

---

_Last updated: 2026-10-23 — content_