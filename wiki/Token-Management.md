---
created: 2026-10-23
updated: 2026-10-23
source_sha: 93db6131588ac2ca387290d081599f3cd4718560
source_paths: Sources/SwiftGmail
source_paths_inferred: false
---

# Token Management

Gmail uses OAuth 2.0 bearer tokens for authentication. SwiftGmail doesn't handle OAuth itself—your app owns the sign-in flow and credential storage—but it does handle token refresh on 401, which is the hard part.

## Design: you own the OAuth flow

[[swift-gmail/architecture/token-management-pattern]] — SwiftGmail is a transport layer, not an auth library. Your app:

- Implements OAuth sign-in (using a Google SDK or a third-party auth service).
- Stores the access token and refresh token securely (Keychain, secure enclave, etc.).
- Provides tokens to SwiftGmail via a `GmailTokenSource`.

This separation means:

- SwiftGmail works with any OAuth implementation (AppKit/UIKit, SwiftUI, web-based, third-party auth).
- Your app retains full control of credentials (no leaky abstractions or surprise network calls).
- Token lifetime, refresh timing, and error handling are yours to decide.

## GmailTokenSource

`GmailTokenSource` is a closure that the client calls at two points:

1. **Before each request** (to get the current token).
2. **If a request returns 401** (to refresh and get a new token).

```swift
public struct GmailTokenSource: Sendable {
    public init(
        credentialErrors: GmailCredentialErrors? = nil,
        resolve: @Sendable (String?) async throws -> String
    )
}
```

The closure's parameter is the rejected token (or `nil` on the first call):

```swift
let tokens = GmailTokenSource { rejected in
    if rejected == nil {
        // First call: return the current token
        return try await myOAuth.currentAccessToken()
    } else {
        // 401: the passed token was rejected; refresh and return a new one
        return try await myOAuth.refresh(rejected: rejected)
    }
}
```

## 401 handling

When a request returns 401 Unauthorized:

1. The client calls the token source with the rejected token.
2. The source refreshes (via the OAuth endpoint) and returns a new token.
3. The client rebuilds the request and retries exactly once.
4. If the retry succeeds, the result is returned. If it fails with 401 again, the error is surfaced to the caller.

This happens automatically; the caller sees only success or a final error.

```swift
let message = try await client.getMessage(
    tokenSource: tokens,
    messageId: "id",
    quotaKey: "user@example.com"
)
// If 401 was encountered, the client refreshed, retried, and is returning the message.
// If the token is still invalid after refresh, the 401 error is thrown here.
```

## Batched operations and token refresh

Batch operations are especially sensitive to token expiry because they can take seconds to complete. If the token expires mid-batch, SwiftGmail:

1. Detects the 401 in the batch response.
2. Calls the token source to refresh.
3. Re-issues the entire batch with the new token.

This keeps the batch atomic: from the caller's perspective, either the whole batch succeeded or it failed.

## Credential error types

If your token source throws a custom error type (e.g., `MyAuthError.signInAgain`), tell the client so it can report credential failures distinctly in batch results:

```swift
let tokens = GmailTokenSource(
    credentialErrors: GmailCredentialErrors(
        isCredentialFailure: { error in
            error is MyAuthError
        },
        rejectedRefreshedToken: { rejected in
            MyAuthError.signInAgain(rejected)
        }
    )
) { rejected in
    try await myOAuth.accessToken(refreshingIfRejected: rejected)
}
```

With this configuration, if a batch operation fails because the token source threw `MyAuthError`, the outcome's `leftover.authRejected` list includes those IDs, and the caller knows to prompt the user to sign in again.

Without this configuration, credential errors are treated as other errors and included in `leftover.failed`.

## Single-flighting

If multiple concurrent requests encounter the same 401, the token source is called only once, and all requests wait for the result and retry. This prevents thundering-herd refreshes and multiple OAuth round-trips.

## Token lifecycle and expiry

SwiftGmail does **not** preemptively refresh tokens (e.g., 5 minutes before expiry). Instead:

- Your app periodically checks token expiry and refreshes as needed.
- SwiftGmail reacts to 401 responses and refreshes on-demand.

This keeps the responsibility clear: your OAuth handler decides when to refresh.

```swift
// Example: refresh before expiry
let tokens = GmailTokenSource { rejected in
    if rejected != nil {
        return try await myOAuth.refresh(rejected: rejected)
    }
    
    // Check expiry; refresh if near end-of-life
    let current = try await myOAuth.currentAccessToken()
    let isNearExpiry = try await myOAuth.timeToExpiry() < 60  // less than 1 minute
    if isNearExpiry {
        return try await myOAuth.refresh(rejected: nil)
    }
    return current
}
```

---

_Last updated: 2026-10-23 — content_