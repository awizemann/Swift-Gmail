# SwiftGmail

A Gmail REST API client for Swift 6, built for mail clients that sync whole
mailboxes rather than send one message.

It is the transport layer of [Assistant](https://poxt.com), a native macOS and
iOS email client, lifted out as a package. Foundation and `os` only: no
SwiftData, no AppKit or UIKit, no OAuth library. Your app owns the sign-in
flow and hands the client a token source.

## What it does

- **The `users.*` surface**: messages (list, get, modify, batchModify,
  trash, untrash, delete, send), threads (list, get), labels (list, create),
  history, drafts (list, get, create, update, delete, send), attachments,
  profile.
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
- **Swift 6 strict concurrency** throughout. 180+ tests, none of which touch
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

### Errors and retries

Every call throws `GmailAPIError`. A non-2xx response is classified once, the
same way for every endpoint:

- **401, 404, 5xx, a refusal 403** → `.httpError(statusCode:detail:)`. `detail`
  is a `GmailErrorDetail` parsed from Gmail's error body: `reason`
  (`error.errors[0].reason`, else `error.status`), `message`, and `retryAfter`
  (the `Retry-After` header, seconds form). It is nil when the body held none
  of these (empty, or a proxy's HTML page).
- **429, or a 403 with a rate reason** (`userRateLimitExceeded`,
  `rateLimitExceeded`, `quotaExceeded`, status `RESOURCE_EXHAUSTED`) → retried
  with backoff; if retries run out, a 429 surfaces as
  `.httpError(statusCode: 429, …)` and a 403 as `.rateLimitExceeded`.
  `quotaExceeded` is retried because Google APIs use it for per-minute and
  concurrency quotas.
- **403 or 429 with `dailyLimitExceeded`** → `.quotaExceeded`, never retried:
  the day's quota will not come back within a backoff. This is the only
  terminal reason.
- `history.list`'s 404 is `.historyIdExpired` (run a full sync), and deleting a
  draft that is already gone (404/410) succeeds.

Reads, label changes, trash/untrash/delete, `drafts.update` and `drafts.delete`
are idempotent and retry 5xx, 429, rate-limit 403s and transient network errors
(timeout, connection lost), up to three times.

How hard a call retries is a `GmailRetryPolicy`: `maxAttempts` (first try
included, default 4), `maxElapsed` (a wall-clock budget for the whole call,
quota waits included; default none) and `retryOnRateLimit` (default true).
Set it per client, or per task tree, where it wins over the client's:

```swift
let client = GmailAPIClient(quotaBucket: bucket, retryPolicy: .failFast(within: 10))

try await GmailRetryPolicy.with(.failFast(within: 10)) {
    try await refreshInbox()   // every call in here gives up within 10 s
}
```

Under `.default` there is no time bound. Each attempt first waits for the
quota bucket, and a rate signal parks the account for 60 s, or up to the
`Retry-After` the server sent, capped at 10 minutes. Four attempts plus their
backoffs can therefore take tens of minutes on a throttled account. A host
with a budget (background refresh, a quick sync) should use
`.failFast(within:)` or `GmailRetryPolicy.with(...)`. Under a deadline, a
quota wait that would pass it is not started (nothing is debited) and throws
`.deadlineExceeded(retryAfter:)`, the time until the account is free again.
A backoff that would pass it is not slept either: the last attempt's own error
is thrown, since that is the one worth acting on. A batch fetch whose re-issue
round runs out of time returns the remaining ids as leftovers.

`maxElapsed` applies per call: each call starts its own budget. To give a
multi-call pass (a sync of several pages, a refresh touching several
endpoints) one shared budget, set `deadline`, an absolute `Date` on the quota
bucket's clock, or use `.failFast(until:)`:

```swift
let cutoff = Date().addingTimeInterval(20)
try await GmailRetryPolicy.with(.failFast(until: cutoff)) {
    try await syncLabels()     // if this takes 15 s...
    try await syncMessages()   // ...this has 5 s left, not a fresh 20 s
}
```

A call's deadline is the earliest of now + `maxElapsed`, the policy's
`deadline`, and that of any bounded call it is nested in, so nesting never
extends a budget. `with(...)` itself REPLACES the outer override rather than
intersecting with it: inside `with(.default)` an outer `with`'s deadline no
longer applies. That is the way to run spawned work with no budget of its
own (and why a helper that wraps its own `with` can widen its caller's).

A rate limit surfaces as `.rateLimitExceeded` (rate-reason 403) or as
`.httpError(429, _)` once a 429's retries run out; match both with
`GmailAPIError.isRateLimit(error)`. `GmailRetryPolicy.current` returns the override set by
`with(...)`, or nil outside one; `client.effectiveRetryPolicy` is the policy
a call on that client would use right now (the override if set, otherwise
the client's own).

`sendMessage`, `sendDraft` and `createDraft` are not idempotent. They retry only a 429 or a
rate-limit 403, which Gmail returns before accepting the request. A 5xx or a
timeout fails after one attempt, because Gmail may already have accepted the
message (or created the draft) and a retry would send it twice.

To decide whether a failed send may have gone out, use
`GmailAPIError.isAmbiguousDelivery(error)`, and auto-retry a send only when it
returns false. It is true for a 5xx, a timeout or lost connection, and any
error it does not recognise. `URLError.cancelled` and `CancellationError`
always return true: a cancellation during the pre-send quota wait looks the
same as one with the request in flight. It is false for a 4xx (429 and 401
included), rate and quota refusals, `.deadlineExceeded`, and connection
failures that never reached Gmail. It cannot recognise your own auth error
(the one your `GmailCredentialErrors` reports), so check for that first: a
dead credential means nothing was sent.

### Endpoints and parameters

- `getMessage(…, metadataHeaders:)` sends repeated `metadataHeaders` items,
  only when `format` is `.metadata` (the only format Gmail applies them to).
- `listHistory(…, historyTypes:, maxResults:)` on both the `accessToken:` and
  `tokenSource:` variants; `historyTypes` is sent as repeated items.
  `HistoryRecord.MessageRef.labelIds` carries the labels Gmail reports.
- `listMessages(…, labelIds:)` sends repeated `labelIds` items (Gmail ANDs them).
- `getDraft(accessToken:draftId:format:)` (`drafts.get`, 5 units) returns
  the draft with its message at that format: `DraftMessage` now has optional
  `snippet`, `historyId`, `internalDate`, `sizeEstimate`, `payload` and `raw`.
  It retries like any read.
- `createLabel(accessToken:name:labelListVisibility:messageListVisibility:)`
  (`labels.create`, 5 units). A label name is unique, so a create that 5xx'd
  or timed out may already exist: it retries only a 429 or rate-limit 403,
  never a 5xx or timeout.
- `sendDraft(accessToken:draftId:)` (`drafts.send`, 100 units) follows the
  send rules below: one attempt on a 5xx or timeout, retried only on a rate
  refusal, metered on the unparkable interactive path. Decide whether a failed
  `sendDraft` may have gone out with `GmailAPIError.isAmbiguousDelivery(_:)`.
- `tokenSource:` variants of `getMessage`, `getThread`, `getAttachment`,
  `sendMessage`, `createDraft` and `getDraft`: the token is resolved after the
  quota wait, and a 401 earns one refresh and one re-send. That is safe even
  for `sendMessage` and `createDraft`, because a 401 means Gmail rejected the
  request; a 5xx or timeout still fails after one attempt, with no refresh.

### Base URL and ids

`GmailAPIClient(…, baseURL:)` points the client at another root (a proxy, a
test server). REST calls go to `<root>/gmail/v1/users/me/…` and batch
envelopes to `<root>/batch/gmail/v1`; the batch sub-requests keep Gmail's
origin-relative `/gmail/v1/users/me/…` targets. The default is
`https://gmail.googleapis.com`. The root may carry a path prefix but not a
query or fragment: the init stops with a precondition failure on one.

Every id placed in a URL path (message, draft, thread, attachment, and the
batch sub-requests) is percent-encoded as one segment: everything outside
`A-Z a-z 0-9 - . _ ~` is escaped, and an id of `.` or `..` is sent as
`%2E` / `%2E%2E`, so no id can add a segment, start a query or resolve as a
dot-segment. Gmail's hex ids are unchanged.

`GmailMessage.snippet` decodes as `""` and `MessagePayload.Body.size` as `0`
when Gmail omits them.

## 0.3.5

Additive and source-compatible: `sendDraft`, `createLabel`, `getDraft`;
`metadataHeaders` on `getMessage`, `historyTypes`/`maxResults` on
`listHistory`, `labelIds` on `listMessages`; public `tokenSource:` variants of
`getMessage`, `getThread`, `getAttachment`, `sendMessage`, `createDraft` and
`getDraft`; a `baseURL` init parameter; one-segment path encoding of every
id; lenient `snippet` / `Body.size` decoding; optional message fields on
`DraftMessage` and `labelIds` on `HistoryRecord.MessageRef`; new
`GmailUnitCost` entries `draftsGet` (5), `draftsSend` (100) and `labelsCreate` (5).

Behaviour change to check: ids in URL paths are now percent-encoded by the
client. A caller that percent-encoded ids itself must stop, or its `%`
reaches Gmail as `%25` and the id no longer matches.

## 0.3.4

Additive only: `listDrafts` takes an optional `query` (Gmail search syntax,
e.g. `rfc822msgid:<id>`) and `includeSpamTrash`, so a host can find the
draft holding a Message-ID in one call.

## 0.3.3

Additive only: `GmailAPIError.isRateLimit(_:)` also recognises an `.httpError`
whose `detail.reason` is a rate token (not the daily limit), so hosts need no
copy of the reason list.

## 0.3.2

Additive only: `GmailAPIError.isRateLimit(_:)`, and documentation that a
nested `GmailRetryPolicy.with` replaces (not intersects) the outer policy.

## 0.3.1

Additive only; nothing to change when upgrading from 0.3.0.
`GmailRetryPolicy` gains `deadline` (a defaulted last init parameter) and
`failFast(until:)`; `GmailRetryPolicy.current` and
`GmailAPIClient.effectiveRetryPolicy` are now public.

## Upgrading from 0.2.0

- `GmailAPIError` has a new case, `deadlineExceeded(retryAfter:)`. An
  exhaustive `switch` over it needs to handle it. It is only thrown when a
  `GmailRetryPolicy` sets `maxElapsed`.
- The defaults are unchanged: `GmailRetryPolicy.default` gives the same
  attempts, backoffs and rate-limit retries as 0.2.0.
- A call made from a task that is already cancelled now throws
  `CancellationError` before it meters or sends anything.

## Upgrading from 0.1.0

`GmailQuotaBucket.shared` no longer persists to `UserDefaults` on its own, and
`GmailQuotaProfile.active` is gone (use `.current`, or the bucket's
`profile`). An app that relied on the old persistence, such as an
Assistant-style mail app, calls this at launch to keep it:

```swift
GmailQuotaBucket.configureShared(stateStore: UserDefaultsGmailQuotaStateStore())
```

`GmailAPIError.httpError` now carries a `detail`, so code that matches on it
needs one more pattern slot:

- `case .httpError(let code)` becomes `case .httpError(let code, _)`.
- `catch GmailAPIError.httpError(statusCode: 404)` becomes
  `catch GmailAPIError.httpError(statusCode: 404, _)`.
- `catch GmailAPIError.httpError(let code) where code == 404` becomes
  `catch GmailAPIError.httpError(let code, _) where code == 404`.

Constructing one is unchanged (`GmailAPIError.httpError(statusCode: 500)`
still compiles). Behavior changes:

- The list and read endpoints (`listMessages`, `listDrafts`, `getProfile`,
  `listLabels`, `listHistory`, `listThreads`) now retry like the other reads.
  A rate limit adds backoff and quota waits before the error surfaces (see
  "Errors and retries" for the bound).
- Each attempt is metered against the quota bucket, retries included.
- `sendMessage` and `createDraft` are no longer retried after a 5xx (or a
  timeout).
- A `dailyLimitExceeded` 403 or 429 throws `.quotaExceeded` (it used to be
  `.rateLimitExceeded` on some endpoints and a bare 403 on others).
- `deleteMessage` treats a 404 on a retry as success, since the earlier
  attempt that failed with a 5xx may already have deleted the message.

## Requirements

macOS 15, iOS 18, Swift 6.2.

## License

MIT. See LICENSE.
