---
title: Quota & Rate Management
type: note
permalink: swift-gmail/architecture/quota-rate-management
tags: [quota, rate-limiting, concurrency]
source_paths: [README.md]
source_paths_inferred: false
source_sha: 4e5da43fa44ec796e4b67e751ba1e59bfb4793d4
created: 2026-10-23
updated: 2026-10-23
reviewed: 2026-10-23
reviewed_by: audit:claude-haiku-4-5
---

## Observations
- [quota_metering] Every request debited its documented unit cost (`GmailUnitCost`) against per-user `GmailQuotaBucket`; Gmail's ceiling is per-user so `quotaKey` (typically user email) separates buckets, not the client instance #quota
- [aimd_adaptation] Bucket adapts via AIMD to server's 429 (throttled) and rate-reason 403 (rate-limited) signals; survives process relaunch #adaptation #resilience
- [interactive_vs_bulk_lanes] Bulk backfill work wrapped in `GmailQuotaLane.withBulkLane { ... }`; interactive lane paced ahead of bulk and never parked behind backfill cooldown. Prevents background sync from starving foreground operations. #priority #user-experience

## Relations
- describes_system [[Gmail API Surface & Batch Operations]]
