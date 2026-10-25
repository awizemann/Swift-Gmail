//
//  GmailRetryPolicy.swift
//  SwiftGmail
//
//  How hard a call tries before it gives up: attempt cap, wall-clock budget,
//  and whether a rate limit is worth waiting out.
//

import Foundation

/// How hard `GmailAPIClient` retries a call.
///
/// Set one per client (`GmailAPIClient(retryPolicy:)`) or per task tree
/// (`GmailRetryPolicy.with(_:operation:)`); the task-local one wins. The
/// default reproduces the pre-0.3.0 behavior exactly.
///
/// `maxElapsed` bounds the whole call, quota waits included: a backoff or a
/// quota park that would end past the deadline is not started. See
/// `GmailAPIError.deadlineExceeded` for what is thrown then.
public struct GmailRetryPolicy: Sendable, Equatable {
    /// Attempts per call, the first one included. Values below 1 count as 1.
    public var maxAttempts: Int
    /// Wall-clock budget for the whole call (quota waits and backoffs
    /// included), measured on the quota bucket's clock. nil = unbounded.
    public var maxElapsed: TimeInterval?
    /// Retry a 429 / rate-reason 403. Off, the first rate signal is thrown.
    public var retryOnRateLimit: Bool

    public init(maxAttempts: Int = 4, maxElapsed: TimeInterval? = nil, retryOnRateLimit: Bool = true) {
        self.maxAttempts = maxAttempts
        self.maxElapsed = maxElapsed
        self.retryOnRateLimit = retryOnRateLimit
    }

    /// Four attempts, no deadline, rate limits retried — the 0.2.0 behavior.
    public static let `default` = GmailRetryPolicy()

    /// For a host with a budget (background refresh, a quick sync): give up
    /// within `seconds` rather than wait out a quota park, and never sit out
    /// a rate limit.
    public static func failFast(within seconds: TimeInterval) -> GmailRetryPolicy {
        GmailRetryPolicy(maxElapsed: seconds, retryOnRateLimit: false)
    }

    /// The policy overriding every client's in this task tree, if any. An
    /// optional so "unset" (use the client's) differs from "set to .default".
    @TaskLocal static var override: GmailRetryPolicy?

    /// The deadline of the outermost bounded call in flight in this task
    /// tree. Set by `GmailAPIClient.withDeadlineScope`; read by
    /// `GmailQuotaBucket.consume` so a quota park never outlives it.
    @TaskLocal static var activeDeadline: Date?

    /// Run `operation` with every Gmail call in its task tree using `policy`,
    /// whatever its client was built with. Child tasks inherit it;
    /// `Task.detached` does not. Modelled on `GmailQuotaLane.withBulkLane`.
    nonisolated(nonsending)
    public static func with<T>(
        _ policy: GmailRetryPolicy,
        operation: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        try await $override.withValue(policy, operation: operation)
    }
}
