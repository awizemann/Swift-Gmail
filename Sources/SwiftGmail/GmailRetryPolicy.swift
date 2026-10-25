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
/// `maxElapsed` bounds each call, quota waits included; `deadline` is one
/// absolute cutoff shared by every call under the policy (on a client's own
/// policy it fails every call once it passes). The earliest wins, and a
/// backoff or quota park that would end past it is not started. See
/// `GmailAPIError.deadlineExceeded` for what is thrown then.
public struct GmailRetryPolicy: Sendable, Equatable {
    /// Attempts per call, the first one included. Values below 1 count as 1.
    public var maxAttempts: Int
    /// Wall-clock budget for the whole call (quota waits and backoffs
    /// included), measured on the quota bucket's clock. nil = unbounded.
    public var maxElapsed: TimeInterval?
    /// Retry a 429 / rate-reason 403. Off, the first rate signal is thrown.
    public var retryOnRateLimit: Bool
    /// An absolute cutoff shared by every call made under this policy, on
    /// the quota bucket's clock (tests on a virtual clock pass virtual
    /// dates). Unlike `maxElapsed`, which restarts with each call, this gives
    /// a multi-call pass one budget. The earliest of the two, and of any
    /// outer bounded call's, wins. nil = none.
    public var deadline: Date?

    public init(
        maxAttempts: Int = 4,
        maxElapsed: TimeInterval? = nil,
        retryOnRateLimit: Bool = true,
        deadline: Date? = nil
    ) {
        self.maxAttempts = maxAttempts
        self.maxElapsed = maxElapsed
        self.retryOnRateLimit = retryOnRateLimit
        self.deadline = deadline
    }

    /// Four attempts, no deadline, rate limits retried — the 0.2.0 behavior.
    public static let `default` = GmailRetryPolicy()

    /// For a host with a budget (background refresh, a quick sync): give up
    /// within `seconds` rather than wait out a quota park, and never sit out
    /// a rate limit.
    public static func failFast(within seconds: TimeInterval) -> GmailRetryPolicy {
        GmailRetryPolicy(maxElapsed: seconds, retryOnRateLimit: false)
    }

    /// Like `failFast(within:)`, but with one absolute cutoff shared by every
    /// call under the policy: a pass of several calls ends by `deadline`.
    public static func failFast(until deadline: Date) -> GmailRetryPolicy {
        GmailRetryPolicy(retryOnRateLimit: false, deadline: deadline)
    }

    /// The task-local override set by `with(_:operation:)`, or nil when none
    /// is set (calls then use their client's policy).
    public static var current: GmailRetryPolicy? { override }

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
