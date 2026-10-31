# SwiftGmail multi-consumer readiness audit — 2026-10-24

Baseline: tag 0.1.0, 112 tests passing. Top items checked by hand in the code.

## Must fix before more consumers (breaking changes are still cheap)
1. sendMessage retries on 5xx (GmailAPIClient.swift:903, :932). A 5xx can come back after Gmail already accepted the message, so a retry can send it twice. Only 429 should be retried.
2. Quota profile is hardcoded: `GmailQuotaProfile.active` is a static let set to Assistant's measured 50 u/s (GmailQuotaBucket.swift:103). `GmailQuotaBucket.init` has no profile parameter, so other consumers can't change the rate.
3. The default `GmailAPIClient()` uses `GmailQuotaBucket.shared`, which saves to UserDefaults.standard. A CLI or server consumer would get state carried between runs without asking for it.
4. `GmailAPIError.httpError` carries only the status code. There's no Gmail reason, no body and no Retry-After. Adding them later breaks the API. `quotaExceeded` is never thrown, but retry logic still treats it as transient.
5. Retry and 403 handling are inconsistent. The list calls, getProfile, listLabels and listHistory don't retry; batchModifyMessages doesn't classify 403.

## API shape (do it before 1.0)
- Pick one auth style: the tokenSource variants exist only on history, the get calls and the batch calls. Send, modify and drafts have no refresh-on-401.
- Models: public memberwise inits plus Equatable/Hashable, so consumers can build fixtures in tests.
- Replace String fields with enums that keep unknown values (label type and visibility). Decide what type internalDate should be.
- Silent task-local defaults: GmailQuotaScope.current falls back to "gmail.default". Multi-user hosts risk sharing one bucket by accident.

## Gaps (add when a consumer asks, built generally)
- Labels create/update/delete; drafts get/send; threads modify/trash/untrash/delete; import/insert; watch/stop; settings.
- listThreads has no includeSpamTrash and its fields mask is hardcoded.
- No Linux support (os, OSAllocatedUnfairLock, UserDefaults). Only matters if a server consumer shows up.

## Tests
- No transport tests for send (including a check that send is not retried), drafts, attachments, trash/untrash/delete, labels, profile or listThreads.

## Hygiene
- About 25 comments point to Assistant tickets and incidents; README names Assistant. Fine as history, but worth trimming.
- IDs go into URL paths without percent-encoding (low risk).
