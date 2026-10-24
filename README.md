# SwiftGmail

A Gmail REST API client for Swift 6, built for mail clients that sync whole
mailboxes rather than send one message.

It is the transport layer of [Assistant](https://poxt.com), a native macOS and
iOS email client, lifted out as a package. Foundation and `os` only: no
SwiftData, no AppKit or UIKit, no OAuth library. Your app owns the sign-in
flow and hands the client a token source.

## What it does

- **The `users.*` surface**: messages (list, get, modify, trash, untrash,
  delete, send), threads, labels, history, drafts, attachments, profile.
- **`/batch` multipart** (`GmailBatchProtocol`): many `get`s in one request,
  with per-part 404 tolerance, per-part 429/5xx re-issue, and envelope retry.
  Falls back to per-id requests if the batch endpoint refuses the envelope.
- **Partial results are typed** (`BatchFetchOutcome`): a batched fetch
  returns what came back AND the ids that did not, split into transient,
  failed, not-found and auth-rejected. A caller cannot mistake a partial
  array for the whole answer.
- **Quota metering** (`GmailQuotaBucket`, `GmailUnitCost`): every call is
  debited its documented unit cost against a per-user token bucket. The
  bucket adapts (AIMD) to the server's 429 and rate-reason 403 signals, keeps
  an interactive lane ahead of bulk backfill, and survives relaunch.
- **Per-request tokens** (`GmailTokenSource`): the bearer is resolved right
  before each request goes out, after any quota wait, and a 401 earns exactly
  one single-flighted refresh per call.
- **Swift 6 strict concurrency** throughout. 110+ tests, none of which touch
  the network.

Encoded gotchas you would otherwise rediscover: `+` in a query must be
`%2B` or Gmail reads it as a space (`rfc822msgid:` searches); `in:spam`
returns nothing without `includeSpamTrash`; 403 means rate-limited OR
forbidden and only the body tells you which; `messages.send` is not
idempotent so client-side timeouts must not retry.

## Usage

```swift
import SwiftGmail

let tokens = GmailTokenSource { rejected in
    // rejected == nil: hand back the current access token (refresh if near expiry)
    // rejected != nil: Gmail returned 401 to that token; refresh and return a new one
    try await myOAuth.accessToken(refreshingIfRejected: rejected)
}

let client = GmailAPIClient()

let page = try await client.listMessages(
    accessToken: try await tokens.current(),   // one-shot entry points take a string
    query: "newer_than:7d",
    quotaKey: "me@example.com"
)

// Batched gets, with the leftovers made explicit.
let outcome = try await client.getMessagesOutcome(
    tokenSource: tokens,
    messageIds: page.messages?.map(\.id) ?? [],
    format: .metadata,
    quotaKey: "me@example.com"
)
ingest(outcome.fetched)
retryLater(outcome.leftover)
```

`quotaKey` is the Gmail user the spend is metered against. Gmail's ceiling is
per user, and one client serves every account, so the key, not the instance,
separates the buckets.

### Bulk versus interactive

Wrap backfill work in `GmailQuotaLane.withBulkLane { ... }`. Everything else
runs on the interactive lane, which is paced ahead of bulk and never parked
behind a backfill's cooldown.

### Quota

Every client debits a `GmailQuotaBucket`, which paces calls against a
`GmailQuotaProfile`: the per-device rate ceiling plus the unit cost of each
method. `.current` (the default) is for Cloud projects created on or after
2026-05-01; `.legacy` is for older ones. A bucket you build yourself takes the
profile directly:

```swift
let client = GmailAPIClient(quotaBucket: GmailQuotaBucket(profile: .legacy))
```

`GmailAPIClient()` uses the process-wide `GmailQuotaBucket.shared`. It is
memory-only by default, so nothing is written to disk unless you ask. To pick
its profile or persist its backoff state across launches, call
`configureShared` once at launch, before the first client exists:

```swift
GmailQuotaBucket.configureShared(
    profile: .current,
    stateStore: UserDefaultsGmailQuotaStateStore()
)
```

A second call, or one after `shared` was first used, is ignored and logged as
a fault.

The package no longer detects test processes. If your app makes this call
with the UserDefaults store at launch, your own test target will write to
`UserDefaults.standard` too, so skip the call when running under tests.

### Credential errors

If your token source throws its own error type for a dead credential, tell the
client so the batch paths report it as a credential failure rather than a
per-id failure:

```swift
let tokens = GmailTokenSource(
    credentialErrors: GmailCredentialErrors(
        isCredentialFailure: { $0 is MyAuthError },
        rejectedRefreshedToken: { MyAuthError.signInAgain($0) }
    )
) { rejected in ... }
```

### Logging

Loggers use the `SwiftGmail` subsystem. To fold them into your app's, call
`GmailLogging.configure(subsystem:)` once at launch, before the first client
exists. A later call is ignored and logged as a fault.

## Upgrading from 0.1.0

`GmailQuotaBucket.shared` no longer persists to `UserDefaults` on its own, and
`GmailQuotaProfile.active` is gone (use `.current`, or the bucket's
`profile`). An app that relied on the old persistence, such as an
Assistant-style mail app, calls this at launch to keep it:

```swift
GmailQuotaBucket.configureShared(stateStore: UserDefaultsGmailQuotaStateStore())
```

## Requirements

macOS 15, iOS 18, Swift 6.2.

## License

MIT. See LICENSE.
