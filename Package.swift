// swift-tools-version: 6.0
//
// SwiftGmail — a Gmail REST API client for Swift 6.
//
// Foundation + os only: no SwiftData, no AppKit/UIKit, no OAuth library. The
// host app owns the OAuth flow and hands the client a `GmailTokenSource`.

import PackageDescription

let package = Package(
    name: "SwiftGmail",
    platforms: [
        .macOS("15.0"),
        .iOS("18.0")
    ],
    products: [
        .library(name: "SwiftGmail", targets: ["SwiftGmail"])
    ],
    targets: [
        .target(
            name: "SwiftGmail",
            path: "Sources/SwiftGmail"
        ),
        .testTarget(
            name: "SwiftGmailTests",
            dependencies: ["SwiftGmail"],
            path: "Tests/SwiftGmailTests"
        )
    ]
)
