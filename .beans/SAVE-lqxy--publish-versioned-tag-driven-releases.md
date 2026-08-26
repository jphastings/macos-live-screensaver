---
# SAVE-lqxy
title: Publish versioned, tag-driven releases
status: todo
type: task
priority: high
created_at: 2026-08-26T07:07:16Z
updated_at: 2026-08-26T07:09:32Z
parent: SAVE-58vg
blocked_by:
    - SAVE-xo6l
    - SAVE-rycg
---

`release.yml` triggers on every push to `main` and force-overwrites a single moving tag called `latest`:

```yaml
tag_name: latest
name: Latest Build
```

Consequences:

- There is no version history. A user cannot say "it broke in 1.3" and there is nothing to roll back to.
- Every merge to `main`, including a docs typo fix, republishes the binary users download.
- A broken merge instantly becomes the artefact everyone gets, with no gate in between.

## Fix

Publish on tag pushes (`v*`), not on every `main` push. The tag is the version: strip the leading `v` and stamp it into `CFBundleShortVersionString` at build time, with the build number from the run number or commit count.

## Tasks

- [ ] Change the release trigger to `push: tags: ['v*']`
- [ ] Derive `VERSION` from the tag and pass it into `make build`
- [ ] Generate release notes from commits since the previous tag
- [ ] Name the artefact with its version (`LiveScreensaver-1.2.0.zip`)
- [ ] Decide whether to keep a rolling `latest` pointer for convenience, or drop it
- [ ] Document the release process (tag, push, done) in the README

## Depends on

Version stamping needs the `VERSION` plumbing from the bundle-metadata bean, and a signed release needs the signing bean.
