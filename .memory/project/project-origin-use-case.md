---
title: Project Origin & Use Case
type: note
permalink: swift-gmail/project/project-origin-use-case
tags: [history, context]
source_paths: [README.md]
source_paths_inferred: false
source_sha: 4e5da43fa44ec796e4b67e751ba1e59bfb4793d4
created: 2026-10-23
updated: 2026-10-23
reviewed: 2026-10-23
reviewed_by: audit:claude-haiku-4-5
---

## Observations
- [origin] Transport layer of Assistant email client (poxt.com), lifted out as standalone package. Explains design priorities and feature set. #origin
- [use_case] Built for mail clients syncing whole mailboxes, not single-message send. Batch operations, quota management, and lane prioritization reflect this focus. #use-case

## Relations
- relates_to [[swift-gmail/architecture/gmail-api-surface-batch-operations]]
- relates_to [[swift-gmail/architecture/quota-rate-management]]
- relates_to [[swift-gmail/architecture/stack-minimal-dependencies]]
