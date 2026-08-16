# Third-Party Notices

GitSync.md includes or links against third-party open-source software. Each
component remains subject to its own license; the project's MIT License does
not replace those terms.

The versions below are taken from the checked-in build script and Swift Package
lockfile. When dependencies are updated, this inventory must be updated too.

## Native libraries bundled in `libgit2.xcframework`

| Component | Version | License | Source |
|---|---:|---|---|
| libgit2 | 1.9.2 | GPL-2.0-only with a linking exception, plus bundled component notices | https://github.com/libgit2/libgit2 |
| libssh2 | 1.11.1 | BSD 3-Clause | https://github.com/libssh2/libssh2 |
| OpenSSL | 3.3.2 | Apache License 2.0 | https://github.com/openssl/openssl |

libgit2's linking exception permits linking the library with independently
licensed software. Modifications to libgit2 itself remain governed by
libgit2's license and corresponding-source requirements. The complete libgit2
license and bundled notices are published in its `COPYING` file:
https://github.com/libgit2/libgit2/blob/v1.9.2/COPYING

The build inputs and pinned versions are documented in
`scripts/build-libgit2-ios-ssh.sh`.

## Swift Package dependencies

| Component | Version | License | Source |
|---|---:|---|---|
| BigInt | 5.7.0 | MIT | https://github.com/attaswift/BigInt |
| Citadel | 0.12.1 | MIT | https://github.com/orlandos-nl/Citadel |
| Swift ASN.1 | 1.7.0 | Apache License 2.0 | https://github.com/apple/swift-asn1 |
| Swift Atomics | 1.3.0 | Apache License 2.0 | https://github.com/apple/swift-atomics |
| Swift Collections | 1.5.0 | Apache License 2.0 | https://github.com/apple/swift-collections |
| Swift Crypto | 3.15.1 | Apache License 2.0 | https://github.com/apple/swift-crypto |
| Swift Log | 1.12.0 | Apache License 2.0 | https://github.com/apple/swift-log |
| SwiftNIO | 2.99.0 | Apache License 2.0 | https://github.com/apple/swift-nio |
| SwiftNIO SSH | 0.3.6 | Apache License 2.0 | https://github.com/Wellz26/swift-nio-ssh |
| Swift System | 1.6.4 | Apache License 2.0 | https://github.com/apple/swift-system |

Exact revisions are recorded in
`Sync.md.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Full license texts and copyright notices are available in each pinned source
package and must accompany redistributed binaries wherever the applicable
license requires them.
