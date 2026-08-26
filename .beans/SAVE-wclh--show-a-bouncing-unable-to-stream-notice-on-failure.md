---
# SAVE-wclh
title: Show a bouncing 'Unable to stream' notice on failure
status: todo
type: feature
priority: high
created_at: 2026-08-26T07:08:01Z
updated_at: 2026-08-26T07:09:32Z
parent: SAVE-5ucd
blocked_by:
    - SAVE-9ndi
---

When a stream fails or a required tool is missing, the user currently gets a black screen and no explanation. `handlePlaybackFailure()` gives up silently after `maxRetries`, and if `yt-dlp` is not installed, `findYtDlpPath()` returns nil and nothing is ever surfaced.

The configuration sheet has good, specific error messages — but they only appear while typing a URL. A stream that dies later, or a `yt-dlp` uninstalled after setup, fails invisibly.

## Design

A notice that bounces around the screen like the DVD logo:

- **"Unable to stream"** in bold
- A user-friendly reason underneath, not bold
- Text wraps so the notice stays near a **16:9 aspect ratio**
- The whole block drifts across the screen, reflecting off the edges

Screensaver-appropriate: no static burn-in, readable at a glance, and the motion makes it obvious the machine is alive rather than crashed.

## Reasons to surface

| Condition | Message underneath |
| --- | --- |
| yt-dlp not found | `YouTube support needs yt-dlp. Install it with: brew install yt-dlp` |
| Stream offline / 404 | `The stream is offline or has ended.` |
| Network unreachable | `No internet connection.` |
| Retries exhausted | `The stream kept dropping out. It may be having problems.` |
| Extraction failed | `Couldn't read the stream address for this URL.` |
| Bad configured URL | `That URL doesn't look like a stream. Check it in Options.` |

## Tasks

- [ ] `StreamError` enum with a user-facing reason per case
- [ ] `ErrorNoticeLayer`: bold title + regular body, wrapped to ~16:9
- [ ] Bounce animation driven from `animateOneFrame`, reflecting off bounds
- [ ] Recompute position/scale on resolution change, keep it on-screen on every display
- [ ] Route every failure path to a `StreamError` instead of returning silently
- [ ] Clear the notice if a retry later succeeds
- [ ] Suppress in preview mode
