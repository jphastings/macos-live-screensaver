---
# SAVE-1lr9
title: Replace NSLog with structured os.Logger logging
status: todo
type: task
priority: normal
created_at: 2026-08-26T07:09:14Z
updated_at: 2026-08-26T07:09:14Z
parent: SAVE-61nt
---

A screensaver is the single worst thing to debug interactively: it exits the moment you touch the machine, and it runs inside a system host process you did not launch. Good logging is not a nicety here, it is the only diagnostic channel.

Today there are exactly four `NSLog` calls, all on incidental failures (cache write, lock file attributes, lock file create, yt-dlp exec). Every interesting transition is silent: which URL was chosen, whether the cache hit, whether extraction succeeded, why a retry fired, when the manager gave up.

## Fix

Adopt `os.Logger` with a stable subsystem so a user can be asked for a Console.app excerpt:

```swift
import OSLog
private let log = Logger(subsystem: "me.byjp.livescreensaver", category: "player")
```

Categories: `player`, `extraction`, `config`, `view`.

Log at state transitions, not in `animateOneFrame` — anything on the 30 Hz path must be `.debug` at most, and preferably not there at all.

Use privacy annotations deliberately: stream URLs can contain signed tokens, so log the host and path but redact query strings.

## Tasks

- [ ] Replace `NSLog` with `os.Logger`, one logger per category
- [ ] Log: chosen source URL, cache hit/miss, extraction start/result/duration, yt-dlp path + version
- [ ] Log: player status transitions, each retry with its attempt number and delay, terminal failure
- [ ] Redact query strings from logged URLs
- [ ] Add a Troubleshooting section to the README telling users how to collect logs
