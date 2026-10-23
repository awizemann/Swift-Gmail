//
//  GmailTokenSource.swift
//  SwiftGmail
//
//  Where a Gmail request gets its bearer token, and the one-shot refresh a
//  401 earns.
//
//  WHY A SOURCE, NOT A STRING. The client used to be handed one access token
//  per call, resolved before the quota bucket's wait and reused by every
//  chunk and retry round after it. A pass that stalled long enough — an iOS
//  app frozen overnight mid-batch is the logged case (2026-10-05) — woke up
//  and sent a `/batch` carrying a token that had expired hours earlier; every
//  sub-response came back 401 and the batch path dropped them all. A source
//  is asked RIGHT BEFORE each HTTP request instead (after the bucket's wait),
//  so the host's refresh-if-near-expiry logic decides freshness at send
//  time. The host's token store is the only cache; nothing here caches.
//

import Foundation

/// Resolves the bearer token for each Gmail request.
public struct GmailTokenSource: Sendable {

    /// `rejected == nil` → the current token (refreshed by the backing store
    /// only if it is near expiry). `rejected != nil` → Gmail answered 401 to
    /// that token: refresh it, unless the store already holds a newer one.
    private let resolve: @Sendable (_ rejected: String?) async throws -> String

    /// False for `fixed(_:)`: re-sending the same string after a 401 cannot
    /// help, so the batch path reports those ids straight away.
    let canRefresh: Bool

    /// How this source's own failures surface — see `GmailCredentialErrors`.
    let credentialErrors: GmailCredentialErrors

    /// - Parameters:
    ///   - credentialErrors: how the host's token errors are recognised and
    ///     how a rejected refreshed token is reported. The default recognises
    ///     only `GmailAPIError.authenticationFailed`; a host whose OAuth layer
    ///     throws its own error type passes a bridge so the batch paths count
    ///     those as credential failures (not as per-id failures).
    ///   - resolve: `rejected == nil` → the current token; otherwise Gmail
    ///     answered 401 to that token — hand back a newer one or throw.
    public init(
        credentialErrors: GmailCredentialErrors = .default,
        _ resolve: @escaping @Sendable (_ rejected: String?) async throws -> String
    ) {
        self.resolve = resolve
        self.canRefresh = true
        self.credentialErrors = credentialErrors
    }

    private init(fixed token: String) {
        self.resolve = { _ in token }
        self.canRefresh = false
        self.credentialErrors = .default
    }

    /// A token that cannot be refreshed — the shape of the legacy
    /// `accessToken:` entry points (and of tests that only need a string).
    public static func fixed(_ token: String) -> GmailTokenSource {
        GmailTokenSource(fixed: token)
    }

    /// The token for the next request (refreshed by the host only if it is
    /// near expiry).
    public func current() async throws -> String {
        try await resolve(nil)
    }

    /// Gmail answered 401 to `token`: a newer one, or a throw if the host
    /// cannot refresh.
    public func refreshed(rejecting token: String) async throws -> String {
        try await resolve(token)
    }
}

/// One forced refresh per batch call, shared by its concurrent chunks.
///
/// A stale token fails every chunk in flight at once; without the gate each
/// would refresh on its own. The first 401 starts the refresh, later ones
/// await the same task, and a refresh that THROWS (a revoked refresh token,
/// surfaced by the host's token source as its own credential error)
/// propagates to every chunk that asked. (Across calls and accounts the host
/// is expected to single-flight the refresh per mailbox as well.)
///
/// Every wait here ABANDONS on cancellation (`awaitAbandoningOnCancel`): the
/// shared refresh is unstructured, and a cancelled pass — the iOS
/// background-expiry case — must not stay parked on it.
actor GmailTokenRefreshGate {
    private let source: GmailTokenSource
    private var refresh: Task<String, Error>?

    init(source: GmailTokenSource) {
        self.source = source
    }

    /// The token for the next request. Waits out a refresh another chunk has
    /// in flight so this one does not go out with the token being replaced.
    /// The token for the next request (refreshed by the host only if it is
    /// near expiry).
    public func current() async throws -> String {
        if let refresh { _ = try? await awaitAbandoningOnCancel(refresh) }
        try Task.checkCancellation()
        return try await source.current()
    }

    /// Refresh after Gmail rejected `token`. Returns false when a re-send
    /// cannot help: the source cannot refresh at all
    /// (`GmailTokenSource.fixed`), or `token` IS what this call's refresh
    /// already produced — Gmail refused the fresh token too.
    ///
    /// A chunk rejected with some OTHER token (sent before the shared refresh
    /// landed, or with a token since replaced again) does not get a blind
    /// re-send: it asks the source about ITS token — which hands back the
    /// stored replacement, or refreshes if the store still holds the rejected
    /// one (the host's `rejected != nil` path, single-flighted per
    /// mailbox) — and re-sends only if that yields something new.
    func refreshOnce(rejecting token: String) async throws -> Bool {
        guard source.canRefresh else { return false }
        if let refresh {
            let fresh = try await awaitAbandoningOnCancel(refresh)
            guard fresh != token else { return false }
            let source = self.source
            let confirmed = try await awaitAbandoningOnCancel(Task { try await source.refreshed(rejecting: token) })
            return confirmed != token
        }
        let source = self.source
        let task = Task { try await source.refreshed(rejecting: token) }
        refresh = task
        return try await awaitAbandoningOnCancel(task) != token
    }
}

extension GmailAPIClient {

    /// One request with its token resolved right before it goes out, and a
    /// 401 given one forced refresh and one re-send. `meter` runs before EACH
    /// send (the re-send costs quota like any request) and before the token is
    /// resolved, so a long bucket wait cannot age the token it then sends.
    /// Pass `meter: nil` when `request` meters itself. A 401 that survives the
    /// refresh throws `refreshedTokenRejected(_:)`.
    public func withTokenSource<T>(
        _ source: GmailTokenSource,
        meter: (() async throws -> Void)? = nil,
        _ request: (String) async throws -> T
    ) async throws -> T {
        try await meter?()
        let token = try await source.current()
        do {
            return try await request(token)
        } catch GmailAPIError.httpError(let statusCode) where statusCode == 401 && source.canRefresh {
            // Meter BEFORE resolving the replacement: a long bucket wait
            // must not age the token the re-send carries.
            try await meter?()
            let fresh = try await source.refreshed(rejecting: token)
            guard fresh != token else { throw Self.refreshedTokenRejected(source) }
            do {
                return try await request(fresh)
            } catch GmailAPIError.httpError(let statusCode) where statusCode == 401 {
                throw Self.refreshedTokenRejected(source)
            }
        }
    }

    /// What a 401 that survived a successful token refresh turns into: the
    /// credential-shaped error the source's bridge builds (by default
    /// `GmailAPIError.authenticationFailed`). The "status 401" wording is
    /// load-bearing for hosts that read a `status 4xx` detail as "sign in
    /// again" rather than as a transient hiccup.
    static func refreshedTokenRejected(_ source: GmailTokenSource) -> any Error {
        source.credentialErrors.rejectedRefreshedToken(
            "Gmail rejected a refreshed access token with status 401"
        )
    }
}

/// The bridge between the host's credential errors and this package.
///
/// Two things cross it: an error the host's token source THROWS (a revoked
/// grant, a refresh that failed) must be recognised as a credential failure
/// so the batch paths report it rather than filing the id as failed; and the
/// error this package throws when a refreshed token is still rejected must be
/// one the host already handles as "sign in again".
public struct GmailCredentialErrors: Sendable {
    /// True for an error the host's token source throws that means the
    /// credential is dead. `GmailAPIError.authenticationFailed` is always
    /// recognised, whatever this returns.
    public let isCredentialFailure: @Sendable (any Error) -> Bool
    /// Builds the error for a 401 that survived a successful refresh.
    public let rejectedRefreshedToken: @Sendable (_ detail: String) -> any Error

    public init(
        isCredentialFailure: @escaping @Sendable (any Error) -> Bool,
        rejectedRefreshedToken: @escaping @Sendable (_ detail: String) -> any Error
    ) {
        self.isCredentialFailure = isCredentialFailure
        self.rejectedRefreshedToken = rejectedRefreshedToken
    }

    public static let `default` = GmailCredentialErrors(
        isCredentialFailure: { _ in false },
        rejectedRefreshedToken: { GmailAPIError.authenticationFailed($0) }
    )

    func recognises(_ error: any Error) -> Bool {
        if case GmailAPIError.authenticationFailed = error { return true }
        return isCredentialFailure(error)
    }
}
