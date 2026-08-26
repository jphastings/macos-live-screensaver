# MacOS Live Screensaver

A macOS screensaver that plays live video streams. Supports YouTube videos, [stream.place](https://stream.place) videos, and direct HLS streams.

> **Also available:** [Android TV Live Screensaver](https://github.com/hauxir/androidtv-live-screensaver)

## Why?

Turn any live stream into your screensaver/lockscreen. Some examples:

### [Namib Desert Wildlife](https://www.youtube.com/watch?v=ydYDqZQpim8)
<img width="640" height="360" alt="Image" src="https://github.com/user-attachments/assets/19b39408-8d67-4699-87c9-bb218198190d" />

### [Times Square](https://www.youtube.com/watch?v=rnXIjl_Rzy4)
<img width="640" height="360" alt="Image" src="https://github.com/user-attachments/assets/5db52a77-24a2-4bd1-9698-d3f2258b4890" />

### [The News](https://www.youtube.com/watch?v=iipR5yUp36o)

<img width="640" height="360" alt="Image" src="https://github.com/user-attachments/assets/1d528a72-3d1b-4151-8e9c-347cdfe8d94c" />

## Requirements

- macOS
- Swift compiler (Xcode Command Line Tools)
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) (optional, for YouTube support)
- [ffmpeg](https://ffmpeg.org/) (optional, required alongside yt-dlp for YouTube support)

**Disclaimer**: This project was entirely vibe-coded. I've never written Swift before in my life.

**Note**: This was tested exclusively on macOS Tahoe on an M2 MacBook. Your mileage may vary on other versions/hardware.

## Installation

### Install yt-dlp and ffmpeg (for YouTube support)

Using Homebrew:
```bash
brew install yt-dlp ffmpeg
```

Or install yt-dlp using pip:
```bash
pip install yt-dlp
brew install ffmpeg
```

### Build and Install

Build and install:
```bash
make install
```

Or step by step:
```bash
make build
open build/LiveScreensaver.saver
```

Other commands:
```bash
make clean      # Remove build directory
make uninstall  # Remove screensaver from ~/Library/Screen Savers/
make start      # Trigger screensaver immediately
```

## Usage

1. Open **System Preferences** → **Screen Saver**
2. Select **Live Screensaver**
3. Click **Options** to configure
4. Enter a video URL:
   - YouTube: `https://www.youtube.com/watch?v=VIDEO_ID` **(live streams only)**
   - HLS stream: `https://example.com/stream.m3u8`
   - stream.place: `https://stream.place/byjp.me`

**Note**: URLs must be `https://`. macOS App Transport Security blocks plain `http://`
connections, so an `http://` stream could never play even though older versions accepted
it in the settings sheet.

**Note**: Only live YouTube videos are supported. Regular (non-live) YouTube videos will not work.

<img width="526" height="587" alt="Image" src="https://github.com/user-attachments/assets/67d314ff-e17e-43bc-baed-df20c9ece80b" />

**Note**: older versions could make System Settings' Options button stop responding. The
preview instance was quitting its host process a couple of seconds after appearing; it no
longer runs the screensaver's idle-detection logic. If you still see it, please open an issue.
## Maintainer: release signing

Releases are signed with a **Developer ID Application** certificate and notarised by
Apple, so the screensaver opens without a Gatekeeper warning on machines that have
never seen it. This needs an [Apple Developer Program](https://developer.apple.com/programs/)
membership (99 USD/year).

Signing engages only when the secrets below are present. A fork, or this repo before
the secrets are added, still builds — it just produces an ad-hoc bundle that Gatekeeper
will reject, and the workflow logs a warning saying so.

### Required repository secrets

Add these under **Settings → Secrets and variables → Actions → New repository secret**.

| Secret | What it is | How to get it |
| --- | --- | --- |
| `MACOS_CERTIFICATE` | Base64 of the Developer ID Application `.p12` | Xcode → Settings → Accounts → Manage Certificates → right-click the Developer ID Application cert → Export. Then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PWD` | The password you set when exporting that `.p12` | Chosen at export time |
| `MACOS_SIGNING_IDENTITY` | The full identity name, e.g. `Developer ID Application: Jane Doe (AB12CD34EF)` | `security find-identity -v -p codesigning` |
| `KEYCHAIN_PASSWORD` | Any random string | `openssl rand -base64 24` — used only for the throwaway keychain CI creates and deletes |
| `APPLE_API_KEY_ID` | App Store Connect API key ID | App Store Connect → Users and Access → Integrations → Keys → generate a key with the **Developer** role |
| `APPLE_API_ISSUER_ID` | Issuer ID | Shown at the top of that same Keys page |
| `APPLE_API_KEY_P8` | Base64 of the downloaded `AuthKey_XXXXXXXX.p8` | `base64 -i AuthKey_XXXXXXXX.p8 \| pbcopy` — **Apple only lets you download this once** |

The API-key route is used rather than an Apple ID with an app-specific password: it is
not tied to a personal account, does not break when 2FA settings change, and can be
revoked independently.

### Signing a build locally

```bash
make build SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"

export APPLE_API_KEY_PATH=~/private_keys/AuthKey_XXXXXXXX.p8
export APPLE_API_KEY_ID=XXXXXXXX
export APPLE_API_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
make notarize
make assess     # what Gatekeeper will decide on a user's machine
```

`make build` on its own ad-hoc signs, which is all you need for local testing.

### Cutting a release

Releases are triggered by pushing a tag, not by merging to `main`. The tag *is* the
version — it is stamped into `CFBundleShortVersionString`, so a user can always tell
you exactly which build they are running.

```bash
git tag v1.2.0
git push origin v1.2.0
```

The workflow validates the tag is `vX.Y.Z`, builds and signs it, notarises, and
publishes a release with generated notes and a versioned artefact
(`LiveScreensaver-1.2.0.zip`).

`workflow_dispatch` is available as an escape hatch to re-run a release without moving
a tag — useful if notarisation fails for a transient reason.

### Why not the Mac App Store?

A `.saver` bundle cannot be distributed through the Mac App Store. The store ships
sandboxed `.app` bundles only, and a screensaver is a plug-in loaded by a system
process — there is no route for it through App Store Connect. Even repackaged as an
app, App Sandbox forbids what this screensaver does: spawning `yt-dlp` as a
subprocess, and reading executables out of `/opt/homebrew/bin`.

Developer ID plus notarisation gives the same practical outcome — a double-clickable
install with no scary warnings — which is what the App Store was wanted for.

## Troubleshooting

**YouTube videos don't play**:
- Make sure yt-dlp and ffmpeg are installed and in your PATH
- Verify you're using a **live** YouTube stream - regular videos are not supported

**Black screen/constant loading spinner**: Wait a few seconds for loading, or try a different URL

### Collecting logs

A screensaver quits the moment you touch the machine, so it cannot be debugged
interactively. It logs to the unified logging system instead. To see what it did:

```bash
log show --predicate 'subsystem == "me.byjp.livescreensaver"' --last 30m --info
```

Or live, while reproducing the problem from another machine or an SSH session:

```bash
log stream --predicate 'subsystem == "me.byjp.livescreensaver"' --info --debug
```

In Console.app, search for `me.byjp.livescreensaver` and enable **Action → Include
Info Messages**.

Stream URLs are logged with their query strings redacted, since those often carry
signed tokens — the output is safe to paste into an issue.
