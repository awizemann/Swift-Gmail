---
title: Release Authority for Consumer Requests
type: note
permalink: swift-gmail/decisions/release-authority-for-consumer-requests
created: 2026-10-24
updated: 2026-10-24
---

## Observations
- [decision] As of 2026-10-24 Alan authorized the Swift-Gmail session to push main and create/push release tags without asking, when working consumer requests with other sessions (e.g. Assistant) #release #authority
- [convention] Consumer sessions request changes by cross-session message; the Swift-Gmail session designs them for all consumers, replies with final signatures, and sends the tag once released #compat

## Relations
- relates_to [[API Conventions & Known Gotchas]]
