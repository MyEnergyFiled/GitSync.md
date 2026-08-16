# Controlled Hugo Executable Evaluation

## Decision

Do not embed or execute the Hugo command-line binary in the current iOS/iPadOS app. HugoInk will keep the isolated native theme approximation as its on-device preview engine. “Exact preview” remains a future, opt-in capability only if it can meet every gate below without weakening the iOS security model.

## Evidence

The P4 reference snapshot used the official Hugo v0.164.0 standard Linux amd64 release. The downloaded archive was 20,723,069 bytes and the extracted executable was 60,809,378 bytes. The archive SHA-256 matched the checksum published with the [official release](https://github.com/gohugoio/hugo/releases/tag/v0.164.0).

Hugo publishes desktop/server command-line builds, not an iOS executable. The current app also cannot treat a downloaded or bundled desktop CLI as data and launch it: Apple requires executable code on iOS and iPadOS to participate in the platform code-signing chain. See Apple’s [app code-signing security documentation](https://support.apple.com/guide/security/sec7c917bf14/web).

Hugo itself uses the Apache-2.0 license, which is compatible with distribution, but embedding a release would still require a complete dependency and notice audit. The upstream project exposes a large Go dependency graph and different standard, extended, deploy, and extended/deploy editions; see the [official Hugo repository](https://github.com/gohugoio/hugo).

## Gate results

| Gate | Requirement | Current result |
| --- | --- | --- |
| Platform | Runs as signed iOS code without spawning an unsupported child process | Fails; no upstream iOS build or supported CLI execution path |
| App size | Acceptable download/install increase with architecture slicing | Fails; measured standard binary is about 58 MiB before app packaging |
| Sandbox | Reads only the selected repository and cannot write outside a disposable output directory | Unproven; full Hugo modules, caches, and asset pipelines need a dedicated port and audit |
| Security | No downloaded executable code, JIT, unsigned plug-ins, or unrestricted network access | Fails for a direct CLI approach |
| Licensing | Apache-2.0 text, notices, source attribution, and all transitive dependencies reviewed | Feasible but incomplete |
| Signing | Works in App Store and SideStore distributions without special private entitlements | Unproven and not acceptable for release |
| Fidelity | Produces deterministic output for supported sites within bounded time and memory | Desktop reference succeeds; no iOS implementation exists |

## Acceptable future approaches

1. A separately installed macOS companion may run a user-installed Hugo binary through Foundation `Process`, with explicit folder access and no hidden upload.
2. An opt-in GitHub Actions preview may build a repository already hosted on GitHub and return a static artifact, provided private-repository disclosure, retention, workflow permissions, and artifact cleanup are explicit.
3. A compiled-in Go library port may be reconsidered only after an upstream-supported iOS target exists or a maintained fork passes App Store review, size, dependency, memory, cancellation, and sandbox audits. It must expose library calls rather than spawn or download executables.

None of these approaches is enabled by P4. The current on-device theme preview is intentionally bounded, offline, script-free, and repository-scoped; its compatibility limits are documented in [HUGO_THEME_PREVIEW_COMPATIBILITY.md](HUGO_THEME_PREVIEW_COMPATIBILITY.md).
