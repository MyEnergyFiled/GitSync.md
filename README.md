# HugoInk

**Write, preview, and publish Hugo content with Git** — a native iOS & iPadOS app that turns a Git repository into a synced Markdown vault and Hugo writing workspace.

[English](README.md) | [简体中文](README_ZH.md)

> [!NOTE]
> HugoInk is the product name of this independently maintained fork of [CodyBontecou/GitSync.md](https://github.com/CodyBontecou/GitSync.md), maintained by [MyEnergyFiled](https://github.com/MyEnergyFiled). The repository, Xcode project, bundle identifier, URL scheme, and Keychain service retain their legacy technical names for compatibility. This is not an official upstream release.

## What It Does

HugoInk clones Git repositories directly to your iPhone or iPad using [libgit2](https://libgit2.org), giving you a real `.git` directory on the device filesystem. Edit Markdown in the app or with tools such as [Obsidian](https://obsidian.md), iA Writer, and Files, then pull and push changes to GitHub or another Git server.

**Key features:**

- **Real Git workspace** — Clone, fetch, fast-forward or rebase, inspect diffs, selectively stage or discard files, commit, and push through libgit2, with staged progress, safe cancellation boundaries, and retryable push state.
- **Branches and recovery tools** — Create, switch, merge, and delete branches; resolve conflicts; browse history; revert commits; and manage stashes and tags.
- **Git LFS** — Hydrate and upload LFS objects, detect large files, offer automatic tracking, and support LFS over HTTPS and SSH.
- **Flexible authentication** — Use GitHub OAuth accounts or PATs, generic HTTPS credentials, SSH private keys with host-key verification, public remotes, and local repositories.
- **Multiple repos** — Manage repositories from GitHub, self-hosted Git services, and local locations in one app.
- **Custom save locations** — Store repos anywhere accessible via the Files app.
- **Built-in file editing** — Browse and rename files, create Markdown documents, edit with syntax highlighting and Front Matter controls, and preview local images.
- **Automation** — Trigger sync through `x-callback-url`, or use protected-data-aware Shortcuts actions to pull one repository or all repositories within [iOS background limits](AUTOMATION_AND_BACKGROUND_SYNC.md).
- **Obsidian and iPad support** — Use repositories as Obsidian vaults and work with layouts optimized for iPad.
- **Hugo article workflow** — Create leaf bundles from `archetypes`, search and filter articles, edit Front Matter, and manage each article's `images/` directory.
- **Safer publishing** — Draft recovery, article-scoped staging, pre-push validation, and protection against losing local content when Git or authentication fails.
- **Built-in diagnostics** — Searchable, redacted logs plus user-facing classification of authentication, network, remote rejection, and repository-corruption failures with safe recovery guidance.

## Hugo Writing Workflow

This fork includes a native workflow for Hugo repositories. It creates posts as leaf bundles such as:

```text
content/posts/my-article/
├── index.md
└── images/
```

Choose an archetype such as `archetypes/default.md` or `archetypes/moments.md`, select the target content directory, and enter an English directory name. The article title is stored in the generated `index.md` Front Matter and does not need to match the directory name.

The article manager displays covers, titles, dates, and draft state, with search, filtering, sorting by title, directory, publication date, modification time, or draft state, direct draft/published switching, and safe article directory moves or renames. Moving an article keeps bundle-local image links unchanged and recalculates relative image paths that point outside the bundle. Each repository can configure additional top-level text, boolean, and number Front Matter fields in `.gitsync-hugo.json`; unconfigured fields remain untouched. The editor keeps the current publication state visible and editable in every Markdown mode, provides publication-date selection that preserves common Hugo formats and time zones, and supports Markdown formatting, syntax highlighting, undo/redo, a live native preview of the title, publication metadata, tags, cover, relative images and links, code blocks, tables, shortcode placeholders, and body, image insertion and management, and recoverable local drafts. Split mode adapts between side-by-side iPad and stacked compact layouts and marks unsaved preview content explicitly. **Save, Commit & Push** stages only the current article bundle and presents one pre-publish summary for Front Matter, missing image references, unusually large images, and unsaved editor changes. Failed pushes keep the local content and publish selection and offer a retry that reuses either the staged files or the existing local commit.

The native preview remains a readable paper-style Quick Preview. The separate Hugo Theme mode embeds the pinned Hugo 0.134.3 Standard engine, builds the site through an isolated disposable workspace, and loads the generated output in a loopback WebView. It never labels the Swift Quick Preview as a real Hugo render.

## How It Works

1. **Sign in** with GitHub, or continue without an account for another Git remote or local repository
2. **Pick a repository** from a GitHub account or add its URL manually
3. **Clone** it to your device — files appear in the iOS Files app
4. **Edit** with any markdown editor
5. **Pull** to fetch remote changes, then selectively stage, commit, and **Push** yours

Files live under `On My iPhone › HugoInk` by default, or in a custom location you choose. Existing installations keep the same app container and repository data after the visible-name change.

## Architecture

```
GitSync.md/
├── Sync.md/                    # iOS app source
│   ├── Sync_mdApp.swift        # App entry point
│   ├── ContentView.swift       # Root view router
│   ├── Models/                  # App, repository, Git operation, and UI state
│   ├── Views/                   # Repository, Git, file, Hugo, and diagnostic UI
│   ├── Services/                # libgit2, Git LFS, GitHub, OAuth, Hugo, and Keychain
│   └── Shortcuts/               # App Intents for repository pulls
├── Packages/
│   └── Clibgit2/               # Swift package wrapping the libgit2 C library
└── libgit2.xcframework/        # Pre-built libgit2 binary for iOS
```

### Git Implementation

All git operations use **libgit2** directly via C interop — no shelling out, no REST API tree manipulation. The `LocalGitService` wraps libgit2 to provide:

- **Remotes** — Clone and fetch over HTTPS, SSH, public, or local transports
- **Pull** — Plan divergence handling, then fast-forward or rebase
- **Changes** — Show status and unified diffs; stage, unstage, or discard individual files or all changes
- **Commit & Push** — Push the current branch, selected changes, or only a Hugo article bundle
- **Branches & conflicts** — Create, switch, merge, and delete branches; continue or abort merges and rebases; resolve conflicted files in the app
- **History, stashes & tags** — Browse commit details, revert commits, and create, apply, pop, drop, or push Git objects as appropriate
- **Git LFS** — Clean, hydrate, cache, validate, download, and upload LFS objects

This produces a standard `.git` directory, making repos compatible with other git tools like the [Obsidian Git](https://github.com/Vinzent03/obsidian-git) plugin.

### x-callback-url API

External apps can trigger sync operations via URL scheme:

```
syncmd://x-callback-url/<action>?repo=<folder-name>&x-success=<url>&x-error=<url>
```

| Action   | Description |
|----------|-------------|
| `pull`   | Fetch and fast-forward |
| `push`   | Stage all, commit, and push |
| `sync`   | Pull then push |
| `status` | Return branch, SHA, and change count |

### Shortcuts

HugoInk provides App Intents for **Pull Repository** and **Pull All Repositories**. They can be used from the Shortcuts app, including in a personal automation that runs when HugoInk opens.

## Building

### Requirements

- **Xcode 16+**
- **iOS 17.0+** deployment target
- macOS with Apple Silicon (or Intel with Rosetta)

### Steps

1. Clone the repo:
   ```bash
   git clone https://github.com/MyEnergyFiled/GitSync.md.git
   cd GitSync.md
   ```

2. Open in Xcode:
   ```bash
   open Sync.md.xcodeproj
   ```

3. Select your target device or simulator and build (`⌘B`).

The pre-built `libgit2.xcframework` is included in the repo so no additional dependency setup is needed.

## Building an IPA from Linux

Linux cannot run Xcode locally. Stable SideStore builds and SHA-256 checksums are published on the [Releases page](https://github.com/MyEnergyFiled/GitSync.md/releases). Download `HugoInk-<version>-SideStore.ipa` and open it with SideStore.

For a development build, this fork also includes a manually triggered GitHub Actions workflow that builds an unsigned IPA on a macOS runner:

1. Push the repository to GitHub.
2. Open **Actions → Build SideStore IPA**.
3. Choose **Run workflow**.
4. Download the `HugoInk-SideStore-*` artifact after the job succeeds.
5. Extract it and open `HugoInk-run-*-SideStore.ipa` with SideStore.

No Apple certificate is stored in GitHub; SideStore signs the IPA during installation.

## Testing

Run the unit XCTest gate locally with:

```bash
xcodebuild test \
  -project Sync.md.xcodeproj \
  -scheme Sync.md \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SyncMDTests \
  -parallel-testing-enabled YES \
  -maximum-parallel-testing-workers 2
```

If your machine does not have an `iPhone 17` simulator, replace the destination with any available iPhone simulator from `xcrun simctl list devices available`.

The local git tests create isolated, UUID-named temporary repositories via `FileManager.default.temporaryDirectory` and clean them up with `defer`, so XCTest can safely run test classes in parallel. CI deliberately caps parallel execution at two workers to avoid simulator memory pressure. Fixture setup should use local-only commits (`commitLocalFixtureChanges` in `SyncMDTests`) unless the test is explicitly exercising push behavior; this avoids depending on expected push failures from repositories without an `origin` remote.

The same unit gate runs in GitHub Actions via `.github/workflows/xctest.yml` on pull requests and pushes to `main`.

Release-candidate device testing follows [REAL_DEVICE_REGRESSION.md](REAL_DEVICE_REGRESSION.md), which separates simulator-safe XCTest coverage from credential, transport, LFS, cancellation, and data-protection checks that require a physical device and disposable remotes.

### GitHub authentication

GitHub sign-in uses the native Device Flow and talks directly to GitHub. No OAuth proxy or client secret is required.

Tokens are stored in the iOS Keychain. Debug logs never intentionally include authorization headers, request bodies, tokens, or article contents; exported logs apply an additional redaction pass.

## Development Status and Roadmap

The core Git workspace, Git LFS transport, authentication methods, file editor, automation entry points, and Hugo writing workflow described above are implemented. P3 Git stability and automation evaluation and the automated portion of P4 isolated Hugo theme preview are complete. Physical-device acceptance and production/Cloudflare visual comparison remain release checks. The user-facing app brand is now HugoInk while compatibility-sensitive identifiers retain their legacy values. Current work is focused on:

- Maintaining the [real-device Git regression matrix](REAL_DEVICE_REGRESSION.md) for release candidates
- Maintaining Hugo configuration, real-theme fixture, and compatibility coverage

Theme preview scope and known differences from a full Hugo build are tracked in [HUGO_THEME_PREVIEW_COMPATIBILITY.md](HUGO_THEME_PREVIEW_COMPATIBILITY.md).
The executable size, signing, licensing, and sandbox decision is recorded in [HUGO_EXECUTABLE_EVALUATION.md](HUGO_EXECUTABLE_EVALUATION.md).

The detailed, prioritized checklist remains in [TODO.md](TODO.md). Keeping the full task list there avoids duplicating fast-changing implementation details in the project overview.

## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests. The open work in [TODO.md](TODO.md) is the best place to find current priorities.

### Editor Setup

If you use a SourceKit-LSP-based editor (Neovim, VS Code + Swift extension, Helix, Zed), generate a `buildServer.json` once so the LSP can resolve cross-file symbols:

```bash
brew install xcode-build-server
xcode-build-server config -project Sync.md.xcodeproj -scheme Sync.md
```

The generated `buildServer.json` is gitignored. Build in Xcode once afterwards so the LSP picks up the compiler index.

## License

[MIT](LICENSE). Original project copyright © 2025–2026 Cody Bontecou; fork modifications copyright © 2026 [MyEnergyFiled](https://github.com/MyEnergyFiled). See [NOTICE.md](NOTICE.md) for attribution and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled dependencies.
