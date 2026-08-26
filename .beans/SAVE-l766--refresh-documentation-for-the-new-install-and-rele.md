---
# SAVE-l766
title: Refresh documentation for the new install and release story
status: todo
type: task
priority: normal
created_at: 2026-08-26T07:09:14Z
updated_at: 2026-08-26T07:09:32Z
parent: SAVE-61nt
blocked_by:
    - SAVE-rycg
    - SAVE-uz0y
---

The README describes a build-it-yourself project. Once releases are signed, notarised and versioned, the installation story changes completely and the docs need to catch up.

Gaps today:

- No mention of installing from a GitHub release — only `make install` from source.
- No Gatekeeper guidance (moot once notarisation lands, which is the point).
- "Tested exclusively on macOS Tahoe on an M2 MacBook" — replace with the real supported range once the deployment target is set and CI proves it.
- No troubleshooting entry for collecting logs.
- No documentation of the CI secrets or the release process for the maintainer.
- The known System Settings preview bug is described as unexplained; once fixed, that note should go.

## Tasks

- [ ] Install-from-release section as the primary path, build-from-source secondary
- [ ] State the supported macOS versions and architectures
- [ ] Troubleshooting: how to collect logs from Console.app
- [ ] Maintainer section: required secrets, how to cut a release
- [ ] Remove the preview-bug note once its bean is done
- [ ] Add a CONTRIBUTING note covering `make check` before opening a PR
