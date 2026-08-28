# HugoRuntime bridge

This package is the only native boundary between Hugo `v0.134.3` Standard and
the iOS app. It is compiled into an XCFramework by
`scripts/build-hugo-ios.sh` on a macOS runner; the app never launches the Hugo
CLI or another process.

The public gomobile surface is deliberately limited to JSON strings, byte
arrays, integer session handles, and errors:

- `RuntimeVersion`
- `OpenSession`
- `Build`
- `ReadOutput`
- `ListOutput`
- `Invalidate`
- `CloseSession`

`Build` constructs a Hugo site from a read-only overlay of the selected
repository and the unsaved files in the preview cache. Hugo publishes only to
the disposable output directory. The overlay, resource, file-cache, and
output paths are supplied by Swift and validated again in Go.

The generated artifact is intentionally not checked into Git. The
`Hugo Runtime` workflow builds and tests it for pull requests and uploads it as
an artifact. The SideStore workflow builds the same artifact before producing
an unsigned IPA.
