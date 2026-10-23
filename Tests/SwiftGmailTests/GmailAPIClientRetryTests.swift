import Foundation
import Testing
@testable import SwiftGmail

/// The retry contract for the NON-idempotent `messages.send` (t-babda0ef): a
/// client-side timeout must NOT trigger a re-POST (the server may have accepted
/// the first attempt → double-send), while server-side rejections (5xx/429)
/// stay retryable. Exercises `GmailAPIClient.withRetry` directly with a
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

    @Test("send contract: a 5xx still retries even with retryClientErrors=false (server rejected → no double-send)")
    func serverErrorRetriedRegardless() async throws {
        let client = GmailAPIClient(quotaBucket: GmailQuotaBucket())
        let attempts = Counter()
        await #expect(throws: (any Error).self) {
            try await client.withRetry(maxRetries: 2, baseDelay: 0, retryClientErrors: false) {
                attempts.bump()
                throw GmailAPIError.httpError(statusCode: 503)
            }
        }
        #expect(attempts.value == 3)   // 5xx is a server-side rejection → safe to retry
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
