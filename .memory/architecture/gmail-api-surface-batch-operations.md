---
title: Gmail API Surface & Batch Operations
type: note
permalink: swift-gmail/architecture/gmail-api-surface-batch-operations
tags: [gmail-api, batching, resilience]
source_paths: [README.md]
source_paths_inferred: false
source_sha: 4e5da43fa44ec796e4b67e751ba1e59bfb4793d4
created: 2026-10-23
updated: 2026-10-23
reviewed: 2026-10-23
reviewed_by: audit:claude-haiku-4-5
---

## Observations
- [api_surface] `users.*` operations: messages (list, get, modify, trash, untrash, delete, send), threads, labels, history, drafts, attachments, profile #api
- [batch_protocol] `GmailBatchProtocol` / `/batch` multipart endpoint: multiple `get`s in single request with per-part 404 tolerance, per-part 429/5xx re-issue, and envelope retry; falls back to per-id if batch endpoint refuses envelope #batch
- [partial_results_typed] `BatchFetchOutcome` makes partial results explicit: returns fetched items AND ids that did not (categorized as transient/failed/not-found/auth-rejected); caller cannot mistake partial array for complete #type-safety

## Relations
- depends_on [[Token Management Pattern]]
- relates_to [[Quota & Rate Management]]
