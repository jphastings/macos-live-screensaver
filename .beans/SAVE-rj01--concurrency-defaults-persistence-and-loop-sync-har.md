---
# SAVE-rj01
title: Concurrency, defaults persistence and loop-sync hardening
status: todo
type: bug
priority: normal
created_at: 2026-08-26T07:08:35Z
updated_at: 2026-08-26T07:08:35Z
parent: SAVE-5ucd
---

A collection of smaller correctness issues in `SharedPlayerManager`, none fatal alone but all capable of producing confusing behaviour.

## 1. `ScreenSaverDefaults` writes without `synchronize()`

`synchronizePlayback()` and `handlePlaybackFailure()` both mutate defaults:

```swift
defaults.set(newStartTime, forKey: StreamStartTimeKey)
defaults.removeObject(forKey: StreamStartTimeKey)
```

Neither calls `synchronize()`. `ScreenSaverDefaults` requires an explicit synchronise for writes to persist — the config sheet's `okClicked()` gets this right, these two do not. The stream start time can silently fail to persist, so multi-monitor sync and the retry reset both misbehave.

## 2. Looped playback drifts out of sync between monitors

`playerDidFinishPlaying` restarts a finished item with a plain seek to zero:

```swift
player?.seek(to: .zero)
player?.play()
```

This bypasses `synchronizePlayback()`, so the position-from-`StreamStartTime` calculation that keeps displays aligned is applied only on the *first* load. After one loop, the sync is gone.

## 3. The extraction lock is check-then-create, not atomic

```swift
if FileManager.default.fileExists(atPath: lockFile) { ... }
try "".write(toFile: lockFile, atomically: true, encoding: .utf8)
```

Two processes can both pass the existence check and both spawn `yt-dlp`. Use `O_CREAT|O_EXCL` (`open` with exclusive create) so the lock is acquired atomically. The lock is also not released if `findYtDlpPath()` fails after it is taken — that path does remove it, but the ordering is fragile and worth restructuring with `defer`.

## 4. Shared mutable state crosses queues without synchronisation

`isSettingUp`, `retryCount`, `viewCount`, `currentSourceURL` and `stallDetectionTime` are read and written from the main queue (`checkStall`, KVO callbacks, `registerView`) *and* from background queues (the extraction blocks in `setupPlayer`). There is no lock or queue confinement, so these are data races.

`registerView()`/`unregisterView()` are also called from view lifecycle on the main thread while `viewCount` is decremented in `deinit`, which is not guaranteed to be on the main thread.

Confine all manager state to a single serial queue, or make the whole manager `@MainActor` and hop explicitly for the blocking work.

## Tasks

- [ ] Add `synchronize()` after every defaults write, or centralise writes in one helper
- [ ] Route loop restarts through `synchronizePlayback()`
- [ ] Make the extraction lock atomic with `O_CREAT|O_EXCL` and release it with `defer`
- [ ] Confine manager state to one queue / actor and document the threading contract
- [ ] Audit `deinit` for main-thread assumptions
