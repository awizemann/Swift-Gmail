---
created: 2026-10-23
updated: 2026-10-23
---

# Getting Started

## Requirements

- Swift 6.2 or later
- macOS 15 or iOS 18 minimum

SwiftGmail is a pure Transport layer — Foundation and `os` only. No SwiftData, AppKit, UIKit, or OAuth library dependencies [[swift-gmail/architecture/stack-minimal-dependencies]].

## Installation

Add SwiftGmail to your `Package.swift` as a dependency:

```swift
.package(url: "https://github.com/...", .branch("main"))
```

Then add it to your target:

```swift
.target(
    name: "YourApp",
    dependencies: ["SwiftGmail"]
)
```

Or in Xcode, use File → Add Packages.

## Your first request

A single-message GET requires a token string and a quota key:

```swift
import SwiftGmail

let client = GmailAPIClient()

let message = try await client.getMessage(
    accessToken: "ya29.a0AfH...",
    messageId: "18c1b1c...",
    quotaKey: "user@example.com"
)
```

The quota key is the Gmail user whose quota budget is spent. Gmail's ceiling is per-user, and one client instance serves every account, so the key (not the instance) separates the buckets.

## Setting up a token source

For any operation that might need a refresh (batch fetches, in particular), provide a `GmailTokenSource` — a closure that returns the current token, or refreshes and returns a new one if the provided token was rejected:

```swift
let tokens = GmailTokenSource { rejected in
    // rejected == nil: return the current access token (refresh if near expiry)
    // rejected != nil: that token was just rejected; refresh and return the new one
    try await myOAuth.accessToken(refreshingIfRejected: rejected)
}

let outcome = try await client.getMessagesOutcome(
    tokenSource: tokens,
    messageIds: ["id1", "id2"],
    format: .metadata,
    quotaKey: "user@example.com"
)
```

[[swift-gmail/architecture/token-management-pattern]]

## Handling credential errors

If your token source throws its own error type for a dead credential, tell the client so batched operations report credential failures distinctly:

```swift
let tokens = GmailTokenSource(
    credentialErrors: GmailCredentialErrors(
        isCredentialFailure: { $0 is MyAuthError },
        rejectedRefreshedToken: { MyAuthError.signInAgain($0) }
    )
) { rejected in
    try await myOAuth.accessToken(refreshingIfRejected: rejected)
}
```

## Logging

SwiftGmail logs to the `SwiftGmail` subsystem. To fold it into your app's logger, call this once at launch, before the first client is created:

```swift
import SwiftGmail

@main
struct App {
    init() {
        GmailLogging.configure(subsystem: "com.example.MyApp")
    }
}
```

A later call is ignored and logged as a fault.

## Running tests

```bash
swift test
```

110+ tests verify all logic locally; none touch the network. See [Testing](Testing) for how they work.

---

_Last updated: 2026-10-23 — content_