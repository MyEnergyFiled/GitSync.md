# Git Real-Device Regression Matrix

Use this matrix for release-candidate IPA validation on a physical iPhone or iPad. Automated XCTest coverage remains the merge gate; rows marked **Device** exercise credentials, network transports, Files integration, and SideStore-installed builds that the simulator cannot reproduce faithfully.

## Test environment record

Create one record per run without including credentials, repository contents, private remote URLs, or SSH key material.

| Field | Value |
|---|---|
| Date and tester | |
| GitSync.md version and commit | |
| IPA workflow run | |
| Device and iOS/iPadOS version | |
| Network type | Wi-Fi / cellular / VPN |
| Git providers | GitHub / self-hosted / local |
| Result | Pass / Fail / Blocked |
| Sanitized debug-log attachment | |

## Repository fixtures

Use disposable repositories. Never test destructive operations against a production vault.

| Fixture | Required setup | Secrets |
|---|---|---|
| Public HTTPS | Public repository with `main` and a second branch | None |
| Private HTTPS | Private repository accessible by OAuth or a repository-scoped PAT | Keychain only |
| Private SSH | Private repository, dedicated test key, known host fingerprint | Keychain only |
| Git LFS | Public or private repository tracking a small image and a file over 10 MB | Same as transport |
| Conflict | Two clones with edits to the same lines plus a rename/rename case | Same as transport |

Delete remote fixtures and revoke test credentials after the release cycle when they are no longer needed.

## Transport and synchronization matrix

| ID | Scope | Procedure | Pass criteria | Gate |
|---|---|---|---|---|
| T01 | Public HTTPS clone | Clone without signing in, reopen the app, pull | Clone finishes, files remain accessible, pull reports up to date | Device |
| T02 | Private HTTPS clone | Sign in or enter PAT, clone, terminate and reopen, pull | Credential remains in Keychain; no credential appears in exported logs | Device |
| T03 | Private HTTPS push | Edit, select changes, commit, push, then inspect remote | Exactly one commit reaches the expected branch and worktree becomes clean | Device |
| T04 | Private SSH clone | Add key, verify first-use host fingerprint, clone | Trust prompt precedes clone; accepted fingerprint is reused | Device |
| T05 | SSH host-key change | Substitute a disposable endpoint with a changed key | Operation stops with changed-key warning; no automatic trust | Device |
| T06 | Offline pull/push | Start operation in airplane mode, then restore network and retry | Error is classified as network interruption; retry does not duplicate commits | Device |
| T07 | Remote advanced | Create a remote commit before pushing local commit | Push is rejected with pull/rebase guidance; local commit remains intact | Device + XCTest |
| T08 | Public/private parity | Repeat status, pull, and push where allowed | Public flow requests no credential; private flow uses only configured credential | Device |

## Git feature matrix

| ID | Scope | Procedure | Pass criteria | Gate |
|---|---|---|---|---|
| G01 | Branch inventory | Create branch, switch, commit, return to `main`, delete branch | Current-branch marker and commit IDs stay accurate | Device + XCTest |
| G02 | Fast-forward pull | Push from a second clone, pull on device | HEAD fast-forwards with no merge commit | Device + XCTest |
| G03 | Rebase pull | Create local and remote commits, choose rebase | Local commit is replayed; branch is ahead and can push | Device + XCTest |
| G04 | Stash lifecycle | Save dirty files, apply, pop, save again, drop | Contents and stash count match each operation | Device + XCTest |
| G05 | Tags | Create lightweight and annotated tags, push/delete where supported | Local and remote lists update without affecting branches | Device + XCTest |
| G06 | Text conflict | Pull divergent edits to the same lines and resolve ours/theirs/manual | Conflict session clears only after every path is resolved | Device + XCTest |
| G07 | Rename conflict | Rename the same file differently in two clones | Chosen path remains; discarded path is removed and commit succeeds | Device + XCTest |
| G08 | Revert | Revert a normal commit and a conflicting commit | Normal revert commits; conflict opens the resolver without data loss | Device + XCTest |

## Git LFS matrix

| ID | Scope | Procedure | Pass criteria | Gate |
|---|---|---|---|---|
| L01 | HTTPS hydrate | Clone fixture containing LFS pointers | Worktree contains hydrated files; Git index retains canonical pointers | Device + XCTest |
| L02 | SSH authenticate | Clone/pull the LFS fixture over SSH | LFS authenticate uses the SSH identity and verified host | Device + XCTest |
| L03 | Upload | Modify tracked LFS file, commit, push, clone elsewhere | Remote object exists and second clone hydrates identical bytes | Device + XCTest |
| L04 | Auto-track prompt | Add an untracked file above the threshold | App requests confirmation before changing `.gitattributes` | Device + XCTest |
| L05 | Lock verification | Attempt to push a file locked by another identity | Push stops before upload and identifies the locked path safely | Device + XCTest |
| L06 | LFS outage | Make LFS endpoint unavailable during clone/pull | Git result remains usable where safe and warning offers retry | Device + XCTest |

## Cancellation and recovery matrix

| ID | Scope | Procedure | Pass criteria |
|---|---|---|---|
| R01 | Cancel clone | Cancel during object transfer | Partial destination is identified and can be retried safely without deleting unrelated files |
| R02 | Cancel pull | Cancel during fetch before worktree update | Existing HEAD and files remain unchanged; retry starts from a valid repository |
| R03 | Cancel push | Cancel before/during upload | Local commit remains; retry pushes it without creating a duplicate commit |
| R04 | App suspension | Background the app during a long operation | UI reports interruption or completion accurately after returning; no false success |
| R05 | Protected data | Reboot device without unlocking and run automation | Sync refuses safely until protected data and Keychain credentials are available |

## Evidence and triage

For every failed or blocked row, record the matrix ID, sanitized operation ID, expected result, actual result, and whether retry changed repository state. Export logs only after reviewing the redaction preview. Never attach tokens, private keys, authorization bodies, article contents, or private remote URLs.

A release candidate passes the Git gate when all applicable **Device** rows pass on at least one supported physical device, the XCTest workflow succeeds for the same commit, and any intentionally skipped provider-specific row is recorded as **Blocked** with a reason rather than silently treated as passed.
