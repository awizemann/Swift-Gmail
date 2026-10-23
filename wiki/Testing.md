---
created: 2026-10-23
updated: 2026-10-23
source_sha: 93db6131588ac2ca387290d081599f3cd4718560
source_paths: Tests/SwiftGmailTests
source_paths_inferred: false
---

# Testing

SwiftGmail includes 110+ tests covering all logic, batch retries, quota adaptation, token refresh, and error cases. None of them touch the network. [[swift-gmail/conventions/testing-strategy]]

## Philosophy: no network

Tests are deterministic and fast because they:

- Mock HTTP responses using a custom `URLProtocol` that doesn't make real requests.
- Verify logic locally (batch multipart encoding, quota AIMD, per-part error handling).
- Avoid flakiness from network timeouts, DNS failures, or API changes during test runs.

This also means you can run the full test suite in seconds, making it safe to run before every commit.

## Running tests

```bash
swift test
```

Or in Xcode:

```bash
xcodebuild test
```

To run a specific test:

```bash
swift test --filter GmailAPIClientBatchTests
```

To see verbose output (including any `os_log` statements):

```bash
swift test --verbose
```

## Test structure

Tests are organized by component:

- `GmailAPIClientURLTests` — Correct URL construction for each endpoint.
- `GmailAPIClientBatchTests` — Batch multipart encoding, per-part error handling, retry logic.
- `GmailQuotaBucketTests` — Quota metering, AIMD adaptation, interactive/bulk lanes.
- `GmailAPIClientRetryTests` — Token refresh on 401, single-flighting.
- `AbandonOnCancelWaitTests` — Cancellation semantics.

Each test is a standalone `struct` with `@Test` methods (using Swift's native testing framework).

## Mocking responses

Tests use a `BatchStubURLProtocol` (defined in `GmailAPIClientBatchTests.swift:21`) to intercept `URLRequest`s and return canned responses:

```swift
struct GmailAPIClientBatchTests {
    @Test
    func batchSucceedsWithAllMessages() async throws {
        let stub = BatchStubURLProtocol()
        stub.register(request: batchRequest, response: batchResponse)
        
        let client = GmailAPIClient(transport: stub.transport)
        let outcome = try await client.getMessagesOutcome(
            tokenSource: tokens,
            messageIds: ["id1", "id2"],
            quotaKey: "user@example.com"
        )
        
        #expect(outcome.fetched.count == 2)
    }
}
```

The stub:

1. Matches incoming `URLRequest`s by URL and method.
2. Returns the registered response (raw HTTP data).
3. Allows you to inspect the request that was made (for assertion).

## Testing batch error cases

Batch tests cover:

- **All 2xx** — Success path; all messages fetched.
- **Per-part 404** — One message not found; others succeed.
- **Per-part 429** — One message rate-limited; retried and succeeds.
- **Per-part 401** — Token rejected; refreshed; batch re-issued.
- **Batch 414** — Envelope too large; falls back to per-id requests.
- **Batch 401** — Token rejected; re-issued with new token; succeeds.

## Testing quota adaptation

Quota tests verify:

- **AIMD on 429** — Bucket capacity halved when 429 is received.
- **AIMD on success** — Bucket capacity increases slowly after successful requests.
- **Interactive lane** — High priority; requests proceed normally.
- **Bulk lane** — Parked behind interactive; resumed after cooldown.
- **Persistence** — Bucket state written to disk; survives app restart.

## Testing token refresh

Token refresh tests verify:

- **On-demand refresh** — 401 → token source called → token refreshed → request retried.
- **Single-flighting** — Concurrent 401s call token source once.
- **Credential errors** — Custom error types reported as auth failures in batch outcomes.
- **Retry count** — Exactly one retry per request (no infinite loops).

## Adding a test

Add a new test to the appropriate `struct` in `Tests/SwiftGmailTests/`. Use the native Swift testing framework:

```swift
struct MyNewTests {
    @Test
    func myNewTest() async throws {
        let client = GmailAPIClient()
        
        // Arrange
        let stub = BatchStubURLProtocol()
        stub.register(request: myRequest, response: myResponse)
        
        // Act
        let result = try await client.getMessage(
            accessToken: "token",
            messageId: "id",
            quotaKey: "user@example.com"
        )
        
        // Assert
        #expect(result.id == "id")
    }
}
```

Run the test:

```bash
swift test --filter MyNewTests/myNewTest
```

---

_Last updated: 2026-10-23 — content_