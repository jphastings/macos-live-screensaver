---
# SAVE-uz0y
title: Build a universal binary with an explicit deployment target
status: todo
type: task
priority: high
created_at: 2026-08-26T07:06:13Z
updated_at: 2026-08-26T07:06:13Z
parent: SAVE-58vg
---

`swiftc` is invoked in the Makefile with no `-target` flag, so the binary architecture and minimum OS are whatever the build machine happens to be.

In CI that machine is a `macos-latest` runner, which is Apple Silicon. The published artefact is therefore an **arm64-only** dylib with the runner's (very recent) macOS as its implicit deployment target:

- Intel Mac users get a screensaver that silently fails to load.
- Users on an older macOS than the runner may also fail to load it.
- The runner image changing bumps the minimum OS without anyone noticing.

Fix by building both slices explicitly and merging them with `lipo`.

## Tasks

- [ ] Add `ARCHS` / `MACOS_MIN` variables to the Makefile
- [ ] Compile `arm64-apple-macos<min>` and `x86_64-apple-macos<min>` slices
- [ ] `lipo -create` them into the bundle's executable
- [ ] Verify with `lipo -info` and `otool -l` in CI that both slices and the expected `LC_BUILD_VERSION` are present
- [ ] Pick and document the minimum supported macOS version

## Notes

The README currently says the project was tested only on macOS Tahoe / M2. A CI matrix over runner versions would let us make a real compatibility claim instead.
