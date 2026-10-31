---
id: t-c1861bba
title: 0.3.0: GmailRetryPolicy + ambiguous-delivery classifier
status: done
added: 2026-10-24
priority: high
---

## Description

Request from Assistant (general need for every consumer).
A) GmailAPIError.isAmbiguousDelivery(_:) static classifier, with README text.
B) GmailRetryPolicy (maxAttempts, maxElapsed covering meter parks, retryOnRateLimit). Set it per client, or override it per task with a task-local. New .deadlineExceeded error, thrown before sleeping past the deadline. Add Task.checkCancellation in the retry loop. Default keeps today's behavior.

## Plan



## Artifacts

Commit cd78ab8, tag 0.3.0 pushed, 150 tests. Assistant notified.

