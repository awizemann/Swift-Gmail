---
id: t-d07bdb03
title: 1.0: unify rate-limit 429 into .rateLimitExceeded
status: ideas
added: 2026-10-24
---

## Description

Today a 429 whose retries run out surfaces as .httpError(429, _), while a rate 403 surfaces as .rateLimitExceeded. isRateLimit(_:) (0.3.2) papers over the difference. Unify the two at the next breaking release. Assistant matches on httpError(429) in its tests.

## Plan



## Artifacts



