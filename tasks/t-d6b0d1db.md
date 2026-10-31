---
id: t-d6b0d1db
title: 0.2.0 slice 1: configurable quota profile + opt-in persistence
status: done
added: 2026-10-24
priority: high
---

## Description

Audit must-fix #2 and #3 (documents/audits/2026-10-24-multi-consumer-audit.md).
- GmailQuotaBucket.init gains `profile: GmailQuotaProfile = .current`; the client meters with its bucket's profile, not the static `GmailQuotaProfile.active` (remove `active`).
- `GmailQuotaBucket.shared` becomes memory-only by default. Add a one-time `GmailQuotaBucket.configureShared(profile:stateStore:)`, called before first use, matching the GmailLogging.configure pattern (a late call is ignored and logged as a fault).
- Remove the test-process sniffing in GmailQuotaStateStore.
- Assistant migration: call configureShared(stateStore: UserDefaultsGmailQuotaStateStore()) at launch to keep today's behavior.

## Plan



## Artifacts

Commit 659af3a. 118 tests. Fresh-eyes audit fixed: profile-scaled rate floor, shared-routing test, README test-target note.

