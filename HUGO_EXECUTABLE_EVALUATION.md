# Controlled Hugo Executable Evaluation

## Decision

Do not embed or execute the Hugo command-line binary in the iOS/iPadOS app.
The real-preview implementation instead uses a separately built Hugo
`v0.134.3` Standard library façade and a gomobile-generated XCFramework. The
library is called directly from signed app code; it does not launch a process,
download executable code, or use a remote preview service.

The native library route remains gated by the Phase 0 fixture, simulator, and
real-device checks in
`docs/HugoRealThemePreviewImplementationPlan.md`. Until those checks pass,
the app must fail closed rather than label the approximation as a real Hugo
preview.

## Evidence

The P4 reference snapshot used the official Hugo v0.164.0 standard Linux amd64 release. The downloaded archive was 20,723,069 bytes and the extracted executable was 60,809,378 bytes. The archive SHA-256 matched the checksum published with the [official release](https://github.com/gohugoio/hugo/releases/tag/v0.164.0).

Hugo publishes desktop/server command-line builds, not an iOS executable. The current app also cannot treat a downloaded or bundled desktop CLI as data and launch it: Apple requires executable code on iOS and iPadOS to participate in the platform code-signing chain. See Apple’s [app code-signing security documentation](https://support.apple.com/guide/security/sec7c917bf14/web).

Hugo itself uses the Apache-2.0 license, which is compatible with distribution, but embedding a release would still require a complete dependency and notice audit. The upstream project exposes a large Go dependency graph and different standard, extended, deploy, and extended/deploy editions; see the [official Hugo repository](https://github.com/gohugoio/hugo).

## Gate results

| Gate | Requirement | Current result |
| --- | --- | --- |
| Platform | Runs as signed iOS code without spawning an unsupported child process | Pass for the embedded Go façade; device and simulator XCFrameworks build in CI |
| App size | Acceptable download/install increase with architecture slicing | Release artifact is architecture-sliced; final product-size acceptance remains a release check |
| Sandbox | Reads only the selected repository and cannot write outside a disposable output directory | Pass in Go fixture tests; output/resource/cache are external to the repository |
| Security | No downloaded executable code, JIT, unsigned plug-ins, or unrestricted network access | Pass for the runtime path; WebView is loopback-only with tokenized output URLs |
| Licensing | Apache-2.0 text, notices, source attribution, and all transitive dependencies reviewed | Inventory recorded in `THIRD_PARTY_NOTICES.md`; release packaging must retain module inventory |
| Signing | Works in App Store and SideStore distributions without special private entitlements | Unsigned IPA built successfully; SideStore installation on a physical device remains pending |
| Fidelity | Produces deterministic output for supported sites within bounded time and memory | Pass for the real Hugo fixture; PaperMod-PE/Cloudflare visual acceptance remains pending |

## Acceptable approaches

1. A separately installed macOS companion may run a user-installed Hugo binary through Foundation `Process`, with explicit folder access and no hidden upload.
2. An opt-in GitHub Actions preview may build a repository already hosted on GitHub and return a static artifact, provided private-repository disclosure, retention, workflow permissions, and artifact cleanup are explicit.
3. A compiled-in Go library façade is the selected implementation. It must
   expose library calls rather than spawn or download executables, and must
   pass the repository's runtime, size, dependency, memory, cancellation,
   sandbox, and device checks.

The direct CLI approach remains disabled. The Swift fallback remains available
only as “Quick Preview”; the “Hugo Theme” path is fail-closed when the native
runtime artifact is not linked. Compatibility limits for unsupported themes
are documented in [HUGO_THEME_PREVIEW_COMPATIBILITY.md](HUGO_THEME_PREVIEW_COMPATIBILITY.md).
