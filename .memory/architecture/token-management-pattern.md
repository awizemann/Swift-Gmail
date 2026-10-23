---
title: Token Management Pattern
type: note
permalink: swift-gmail/architecture/token-management-pattern
tags: [authentication, oauth]
source_paths: [README.md]
source_paths_inferred: false
source_sha: 4e5da43fa44ec796e4b67e751ba1e59bfb4793d4
created: 2026-10-23
updated: 2026-10-23
reviewed: 2026-10-23
reviewed_by: audit:claude-haiku-4-5
---

## Observations
- [host_owns_oauth] Host app owns OAuth flow entirely; client takes `GmailTokenSource` (a closure that returns current token, or refreshes and returns new token if one is rejected). Bearer is resolved right before each request, after quota wait. #oauth #decoupling
- [single_flighted_refresh] 401 response earns exactly one single-flighted refresh per call (not per-batch-part). Prevents refresh loops and thundering herd on auth failure. #resilience
- [credential_errors] Optional `GmailCredentialErrors` struct lets token source define its own error types; includes `isCredentialFailure` predicate and optional `rejectedRefreshedToken` transform. Batch paths then report as credential failure rather than per-id failure. #error-handling #extensibility

## Relations
- required_by [[Gmail API Surface & Batch Operations]]
