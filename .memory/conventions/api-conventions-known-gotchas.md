---
title: API Conventions & Known Gotchas
type: note
permalink: swift-gmail/conventions/api-conventions-known-gotchas
tags: [api-patterns, edge-cases]
source_paths: [README.md]
source_paths_inferred: false
source_sha: 4e5da43fa44ec796e4b67e751ba1e59bfb4793d4
created: 2026-10-23
updated: 2026-10-24
reviewed: 2026-10-23
reviewed_by: audit:claude-haiku-4-5
---

## Observations
- [entry_point_patterns] One-shot entry points take string token directly (e.g. `listMessages(accessToken: String, …)`); batched paths take `GmailTokenSource` for refresh capability (e.g. `getMessagesOutcome(tokenSource: GmailTokenSource, …)`) #api-patterns
- [plus_encoding_gotcha] `+` in query string must be `%2B` or Gmail reads it as space; affects `rfc822msgid:` searches and other operators. URL encoding alone is insufficient. #search #encoding
- [spam_search_gotcha] `in:spam` returns nothing without `includeSpamTrash` parameter. Default behavior is confusing and easy to miss. #search
- [403_ambiguity] 403 response means rate-limited OR forbidden; only response body tells you which (presence of rate-reason header vs permission denial). Affects retry logic. #error-handling
- [send_not_idempotent] `messages.send` is not idempotent. Client-side timeouts must not retry or risk duplicate sends. #send #idempotence

- [convention] Retry rules (0.2.0): every endpoint goes through one classifier (checkedResponse/gmailError). sendMessage and createDraft retry only 429 or a rate 403, never 5xx or a timeout. Only `dailyLimitExceeded` is terminal (.quotaExceeded); `quotaExceeded`/RESOURCE_EXHAUSTED are retryable rate signals. deleteMessage treats a 404 on a retry as success #retry #send
- [convention] Change policy: requests from consumer projects are designed for every consumer, not only the one asking; breaking changes are batched into a minor bump with an "Upgrading" README section, while the package is 0.x #compat

- [convention] 0.3.0: GmailRetryPolicy deadlines cover quota parks, backoff, bulk yield and batch rounds. A refused quota wait books nothing and throws .deadlineExceeded(retryAfter:); a backoff cut off by the deadline rethrows the last real error. isAmbiguousDelivery returns true for anything that might have reached Gmail, including all cancellation and unknown errors. A shared token refresh ignores the caller's budget #retry #deadline

## Relations
- refines [[Gmail API Surface & Batch Operations]]
