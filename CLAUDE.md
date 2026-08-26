# macOS Live Screensaver

A macOS screensaver (`.saver` bundle) that plays live HLS video streams, with support for
YouTube live streams (via `yt-dlp`) and stream.place.

## Issue tracking

**IMPORTANT**: before you do anything else, run the `beans prime` command and heed its output.

Work is tracked with [beans](https://github.com/hmans/beans) in the `.beans/` directory.
Bean IDs are prefixed `SAVE-`. Use `beans list --ready` to find actionable work.

## Layout

- `screensaver.swift` — the entire implementation (player manager, view, config sheet)
- `Makefile` — builds and assembles the `.saver` bundle; `make install` copies it into
  `~/Library/Screen Savers`
- `Info.plist` — bundle metadata; `NSPrincipalClass` must stay `LiveScreensaverView`
- `.github/workflows/` — CI and release automation

## Building

Requires macOS with Xcode Command Line Tools. `make build` compiles with `swiftc` directly —
there is no Xcode project.

```bash
make build     # assemble build/LiveScreensaver.saver
make install   # build, then install to ~/Library/Screen Savers
make start     # launch the screensaver engine to test
```

## Notes for agents

- A screensaver cannot be debugged interactively — it exits on input. Prefer logging
  (`os.Logger`, subsystem `me.byjp.livescreensaver`) over breakpoints.
- The same view class runs in the System Settings **preview** thumbnail. Always check
  `isPreview` before starting playback or reacting to user input.
- `SharedPlayerManager` is a singleton so that N monitors stream the video once, not N times.
