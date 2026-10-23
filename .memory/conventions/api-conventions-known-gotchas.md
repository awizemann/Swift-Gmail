---
title: API Conventions & Known Gotchas
type: note
permalink: swift-gmail/conventions/api-conventions-known-gotchas
tags: [api-patterns, edge-cases]
source_paths: [README.md]
source_paths_inferred: false
source_sha: 4e5da43fa44ec796e4b67e751ba1e59bfb4793d4
created: 2026-10-23
updated: 2026-10-23
reviewed: 2026-10-23
reviewed_by: audit:claude-haiku-4-5
---

## Observations
- [entry_point_patterns] One-shot entry points take string token directly (e.g. `listMessages(accessToken: String, …)`); batched paths take `GmailTokenSource` for refresh capability (e.g. `getMessagesOutcome(tokenSource: GmailTokenSource, …)`) #api-patterns
- [plus_encoding_gotcha] `+` in query string must be `%2B` or Gmail reads it as space; affects `rfc822msgid:` searches and other operators. URL encoding alone is insufficient. #search #encoding
- [spam_search_gotcha] `in:spam` returns nothing without `includeSpamTrash` parameter. Default behavior is confusing and easy to miss. #search
- [403_ambiguity] 403 response means rate-limited OR forbidden; only response body tells you which (presence of rate-reason header vs permission denial). Affects retry logic. #error-handling
- [send_not_idempotent] `messages.send` is not idempotent. Client-side timeouts must not retry or risk duplicate sends. #send #idempotence

## Relations
- refines [[Gmail API Surface & Batch Operations]]
