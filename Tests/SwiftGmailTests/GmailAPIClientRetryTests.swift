import Foundation
import Testing
@testable import SwiftGmail

/// The retry contract for the NON-idempotent `messages.send` (t-babda0ef): a
/// client-side timeout must NOT trigger a re-POST (the server may have accepted
/// the first attempt → double-send), and neither may a 5xx (Gmail can answer
/// one after accepting); only a rate rejection stays retryable. Exercises `GmailAPIClient.withRetry` directly with a
/// counting operation.
@Suite("GmailAPIClient.withRetry — messages.send non-idempotent retry contract")
struct GmailAPIClientRetryTests {

    /// Sequential invocation counter (withRetry awaits each attempt before the
    /// next, so there's no real concurrency — @unchecked is safe).
    private final class Counter: @unchecked Sendable {
        var value = 0
        func bump() { value += 1 }
    }

    /// The ambiguous client-transport failure a non-idempotent send must not retry.
    private static var clientTimeout: Error { URLError(.timedOut) }

    @Test("send contract: a CLIENT timeout does NOT retry (retryClientErrors=false) — exactly one attempt")
    func timeoutNotRetriedForSend() async throws {
        let client = GmailAPIClient(quotaBucket: GmailQuotaBucket())
        let attempts = Counter()
        await #expect(throws: (any Error).self) {
            try await client.withRetry(maxRetries: 3, baseDelay: 0, retryClientErrors: false) {
                attempts.bump()
                throw Self.clientTimeout
            }
        }
        #expect(attempts.value == 1)   // no re-POST — the double-send guard
    }

    @Test("GET contract: a CLIENT timeout DOES retry (retryClientErrors=true) — maxRetries+1 attempts")
    func timeoutRetriedForIdempotentGets() async throws {
        let client = GmailAPIClient(quotaBucket: GmailQuotaBucket())
        let attempts = Counter()
        await #expect(throws: (any Error).self) {
            try await client.withRetry(maxRetries: 2, baseDelay: 0, retryClientErrors: true) {
                attempts.bump()
                throw Self.clientTimeout
            }
        }
        #expect(attempts.value == 3)   // 1 + 2 retries
    }

    @Test("send contract: a 5xx does NOT retry with retryServerErrors=false — exactly one attempt")
    func serverErrorNotRetriedForSend() async throws {
        let client = GmailAPIClient(quotaBucket: GmailQuotaBucket())
        let attempts = Counter()
        await #expect(throws: (any Error).self) {
            try await client.withRetry(maxRetries: 2, baseDelay: 0, retryClientErrors: false, retryServerErrors: false) {
                attempts.bump()
                throw GmailAPIError.httpError(statusCode: 503)
            }
        }
        #expect(attempts.value == 1)   // a 5xx may follow acceptance → no re-POST
    }

    @Test("GET contract: a 5xx retries by default — maxRetries+1 attempts")
    func serverErrorRetriedForIdempotentCalls() async throws {
        let client = GmailAPIClient(quotaBucket: GmailQuotaBucket())
        let attempts = Counter()
        await #expect(throws: (any Error).self) {
            try await client.withRetry(maxRetries: 2, baseDelay: 0) {
                attempts.bump()
                throw GmailAPIError.httpError(statusCode: 503)
            }
        }
        #expect(attempts.value == 3)
    }

    @Test("send contract: a 4xx (400 malformed) fails fast — exactly one attempt")
    func clientHTTPErrorFailsFast() async throws {
        let client = GmailAPIClient(quotaBucket: GmailQuotaBucket())
        let attempts = Counter()
        await #expect(throws: (any Error).self) {
            try await client.withRetry(maxRetries: 3, baseDelay: 0, retryClientErrors: false) {
                attempts.bump()
                throw GmailAPIError.httpError(statusCode: 400)
            }
        }
        #expect(attempts.value == 1)
    }
}
