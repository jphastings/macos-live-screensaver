---
# SAVE-5e1q
title: Network and subprocess hardening (ATS, HLS check, yt-dlp)
status: todo
type: task
priority: normal
created_at: 2026-08-26T07:08:35Z
updated_at: 2026-08-26T07:08:35Z
parent: SAVE-5ucd
---

Two hardening items around network and subprocess handling.

## 1. `http://` URLs are accepted but will not play

Config validation explicitly allows plain HTTP:

```swift
guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
```

App Transport Security blocks cleartext HTTP by default, so an `http://` URL passes validation with a green tick and then fails silently at playback — the worst possible outcome, because the user has been told it is fine.

Pick one and be deliberate:

- **Preferred:** require `https://` in validation, with a clear message explaining why.
- Or declare a narrow ATS exception in `Info.plist` and document it. A blanket `NSAllowsArbitraryLoads` should be avoided; it weakens every connection the bundle makes and invites review scrutiny.

Validation is also more permissive than playback in a second way: it accepts any URL that returns 2xx to a ranged GET, without checking the response looks like an HLS manifest. Checking for `#EXTM3U` in the first bytes would catch a URL that serves an HTML error page with a 200.

## 2. yt-dlp discovery and execution

```swift
private let ytdlpPaths = [
    "/opt/homebrew/bin/yt-dlp",
    "/usr/local/bin/yt-dlp",
    "/opt/local/bin/yt-dlp",
    (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/yt-dlp"),
]
```

Executing the first match from a fixed list is the right shape — much better than searching `$PATH` — and arguments are passed as an array rather than through a shell, so there is no injection vector from the URL. Two improvements:

- `/usr/local/bin` is world-writable by default on some setups, and `~/.local/bin` is user-writable. A screensaver runs in a system context; verify the binary is owned by root or the current user and is not group/world-writable before executing it.
- Log which `yt-dlp` was selected, and its version, so support questions are answerable.

There is no timeout on the `waitUntilExit()` in `extractHLSURL` — the 15 s `extractionTimeoutSeconds` only governs lock staleness, not the process itself. A hung yt-dlp hangs the extraction thread indefinitely.

## Tasks

- [ ] Require HTTPS in validation, or add a documented, narrow ATS exception
- [ ] Verify the fetched manifest looks like HLS (`#EXTM3U`), not just 2xx
- [ ] Check ownership/permissions of the yt-dlp binary before executing
- [ ] Enforce a real timeout on the yt-dlp process and terminate it on expiry
- [ ] Log the selected yt-dlp path and version
