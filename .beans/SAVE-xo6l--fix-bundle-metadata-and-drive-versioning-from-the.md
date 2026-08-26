---
# SAVE-xo6l
title: Fix bundle metadata and drive versioning from the build
status: todo
type: task
priority: high
created_at: 2026-08-26T07:06:13Z
updated_at: 2026-08-26T07:06:13Z
parent: SAVE-58vg
---

`Info.plist` still carries scaffold values that will block an App Store submission and make support impossible.

Current state:

- `CFBundleIdentifier` is `com.livescreensaver.app` — a generic, collision-prone ID that is not tied to a Developer ID/Team. App Store Connect requires an identifier registered to the team.
- `CFBundleShortVersionString` is pinned at `1.0` and `CFBundleVersion` at `1`, so every release ever published claims to be the same version. Users cannot report "broken in X" and there is nothing to roll back to.
- No `LSMinimumSystemVersion`, so macOS has no idea which releases it can load.
- `NSHumanReadableCopyright` is the placeholder `Copyright © 2025. All rights reserved.`

## Tasks

- [ ] Change bundle identifier to a reverse-DNS ID owned by the author
- [ ] Add `LSMinimumSystemVersion` matching the deployment target
- [ ] Set a real copyright string
- [ ] Drive `CFBundleShortVersionString` / `CFBundleVersion` from the build (git tag / `VERSION` variable) rather than hardcoding
- [ ] Add `NSHighResolutionCapable` and confirm no other keys are required for a `.saver` bundle
