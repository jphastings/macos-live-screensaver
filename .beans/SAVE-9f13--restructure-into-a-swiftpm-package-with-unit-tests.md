---
# SAVE-9f13
title: Restructure into a SwiftPM package with unit tests
status: todo
type: task
priority: high
created_at: 2026-08-26T07:09:14Z
updated_at: 2026-08-26T07:09:14Z
parent: SAVE-61nt
---

`screensaver.swift` is a single 1,100-line file containing the player manager, the view, the configuration window controller, a custom tracking view, and the URL helpers. There are no tests, and the Makefile drives `swiftc` directly so there is no test target to run.

This matters most because a good chunk of the logic is **pure and cheaply testable**, and currently a regression in any of it would ship silently:

- `needsYtDlpExtraction(_:)` — decides whether to shell out to yt-dlp at all
- `isStreamPlaceURL(_:)` — host matching, including the `.stream.place` suffix rule
- `getStreamPlaceHLSURL(_:)` — path parsing and the `embed/` prefix strip
- `extractExpirationTimestamp(from:)` — the `expire/([0-9]+)` regex
- cache expiry logic — expiry-in-URL vs. file mtime fallback

## Plan

Convert to a SwiftPM package with two targets:

- `LiveScreensaverCore` — pure logic, no ScreenSaver/AppKit dependency, fully unit tested
- the `.saver` bundle — thin AppKit/ScreenSaver layer that imports Core

Split the remaining AppKit code by type: `SharedPlayerManager.swift`, `LiveScreensaverView.swift`, `ConfigureWindowController.swift`, `ErrorNoticeLayer.swift`.

The Makefile keeps working as the bundle-assembly entry point; `swift test` runs Core's tests and joins the CI checks.

## Tasks

- [ ] Add `Package.swift` with a `LiveScreensaverCore` library and a test target
- [ ] Move the pure URL/cache helpers into Core
- [ ] Write unit tests for each helper, including the awkward cases (embed URLs, trailing slashes, missing expiry, malformed timestamps)
- [ ] Split the AppKit code into one file per type
- [ ] Update the Makefile to compile Core + bundle sources
- [ ] Add `swift test` to CI

## Sequencing

Deliberately scheduled **last** among the code changes: it moves every line in the file, so landing it before the bug fixes would make each of those diffs unreviewable.
