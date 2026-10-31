---
id: t-4af69f4a
title: 0.3.1: absolute retry deadline + readable effective policy
status: done
added: 2026-10-24
---

## Description

Assistant request (general). Add GmailRetryPolicy.deadline: Date? and .failFast(until:); effective deadline = min(now+maxElapsed, deadline, outer). Public GmailRetryPolicy.current (override or nil) and GmailAPIClient.effectiveRetryPolicy.

## Plan



## Artifacts

Commit ec19cd8, tag 0.3.1 pushed, 154 tests. Assistant notified.

