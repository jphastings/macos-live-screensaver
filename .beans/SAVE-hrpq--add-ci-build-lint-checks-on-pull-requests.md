---
# SAVE-hrpq
title: Add CI build & lint checks on pull requests
status: todo
type: task
priority: high
created_at: 2026-08-26T07:06:13Z
updated_at: 2026-08-26T07:06:13Z
parent: SAVE-58vg
---

The only workflow in the repo (`.github/workflows/release.yml`) both builds *and* publishes, and only runs on pushes to `main`. Nothing verifies a pull request, and a broken merge to `main` immediately overwrites the `latest` release that users download.

Split verification from publication: a `ci.yml` that builds (and later, tests) on every pull request and on `main`, leaving `release.yml` to do nothing but package and publish.

## Tasks

- [ ] Add `.github/workflows/ci.yml` running on `pull_request` and `push` to `main`
- [ ] Build the screensaver and assert the bundle structure is intact (binary, Info.plist, thumbnail)
- [ ] Add a `swift-format --lint` check with a checked-in `.swift-format` config
- [ ] Add a `make lint` / `make check` target so the same checks run locally
- [ ] Concurrency group so superseded PR runs are cancelled
