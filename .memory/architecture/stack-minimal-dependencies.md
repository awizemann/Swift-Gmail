---
title: Stack & Minimal Dependencies
type: note
permalink: swift-gmail/architecture/stack-minimal-dependencies
tags: [dependencies, platforms]
source_paths: [README.md, Package.swift]
source_paths_inferred: false
source_sha: 4e5da43fa44ec796e4b67e751ba1e59bfb4793d4
created: 2026-10-23
updated: 2026-10-23
reviewed: 2026-10-23
reviewed_by: audit:claude-haiku-4-5
---

## Observations
- [dependencies] Foundation and `os` only; no SwiftData, AppKit, UIKit, or OAuth library. Client is portable transport layer; host app provides OAuth, UI, persistence. #dependencies
- [platforms] macOS 15.0+, iOS 18.0+, Swift 6.2. Swift 6 strict concurrency enforced throughout (`Sendable`, actor isolation). #platforms #concurrency

## Relations
- enables [[Token Management Pattern]]
