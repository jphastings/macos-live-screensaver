---
# SAVE-xncv
title: Screensaver kills the System Settings preview with exit(0)
status: todo
type: bug
priority: critical
created_at: 2026-08-26T07:08:01Z
updated_at: 2026-08-26T07:08:01Z
parent: SAVE-5ucd
---

`animateOneFrame()` calls `exit(0)` when it detects user activity:

```swift
override func animateOneFrame() {
    if Date().timeIntervalSince(startTime) > 2.0 {
        let idleTime = getSystemIdleTime()
        let screenLocked = isScreenLocked()
        if idleTime < 1.0 && !screenLocked {
            exit(0)
        }
    }
    ...
}
```

Two problems, one of which is almost certainly a bug users are hitting today.

## 1. The preview instance runs this code

`init(frame:isPreview:)` stores nothing about `isPreview`, and none of the playback or idle-detection logic checks it. The same view runs inside the small preview thumbnail in System Settings → Screen Saver — where the user is, by definition, moving the mouse.

Two seconds after the preview appears, `idleTime < 1.0` is true and the view calls `exit(0)`, killing the process that hosts the settings preview (`legacyScreenSaver.appex`).

This matches the symptom already documented in the README:

> **Note**: macOS screensaver UI can be buggy. If the Options button is unresponsive, try closing and reopening System Settings. PRs welcome for anyone who can figure out why.

This bean is that PR.

## 2. `exit(0)` is the wrong tool regardless

On modern macOS the saver is loaded into a shared host process. Calling `exit()` terminates the host, not just this view — it skips `deinit`, so `unregisterView()` never runs and the shared `AVPlayer` is never torn down cleanly.

## Fix

- Store `isPreview` and gate both the idle-exit check and network playback behind it. The preview should render something cheap and static rather than opening a live stream (a second stream for a thumbnail nobody is watching is also a waste of bandwidth).
- Replace `exit(0)` with a clean stop path; keep `exit(0)` only as a last resort on the real screensaver instance, never in preview.

## Tasks

- [ ] Store `isPreview` from the initialiser
- [ ] Skip idle-detection / exit entirely when `isPreview` is true
- [ ] Skip live playback in preview; render a static placeholder instead
- [ ] Verify the Options button stays responsive in System Settings
