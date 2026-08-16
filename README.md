# GitSync.md

**Markdown notes synced with Git** — a native iOS & iPadOS app that turns any GitHub repository into a synced markdown vault.

[English](README.md) | [简体中文](README_ZH.md)


## What It Does

GitSync.md clones GitHub repos directly to your iPhone or iPad using [libgit2](https://libgit2.org), giving you a real `.git` directory on the device filesystem. Edit markdown files with any app — [Obsidian](https://obsidian.md), ia Writer, or the built-in Files app — then pull and push changes back to GitHub.

**Key features:**

- **Real git** — Clone, pull, rebase, stage, commit, push, switch branches, manage stashes and tags, and resolve conflicts via libgit2.
- **Multiple repos** — Manage several GitHub repositories at once.
- **Custom save locations** — Store repos anywhere accessible via the Files app.
- **Obsidian integration** — Works with Obsidian vaults via `x-callback-url` for automated sync.
- **GitHub OAuth & PAT** — Sign in with GitHub OAuth or paste a Personal Access Token.
- **Private repo support** — Works with both public and private repositories.
- **iPad support** — Optimized layouts for iPad.
- **Hugo article workflow** — Create leaf bundles from `archetypes`, edit Front Matter, and manage each article's `images/` directory in the app.
- **Safer publishing** — Draft recovery, article-scoped staging, pre-push validation, and protection against losing local content when Git or authentication fails.
- **Built-in diagnostics** — Searchable live logs with GitHub/OAuth timing and status details, automatic rotation, export, and credential redaction.

## Hugo Writing Workflow

This fork includes a native workflow for Hugo repositories. It creates posts as leaf bundles such as:

```text
content/posts/my-article/
├── index.md
└── images/
```

Choose an archetype such as `archetypes/default.md` or `archetypes/moments.md`, select the target content directory, and enter an English directory name. The article title is stored in the generated `index.md` Front Matter and does not need to match the directory name.

The article manager displays titles, dates, draft state, and cover fields. The editor supports Markdown formatting, undo/redo, local image preview, image insertion and management, and recoverable local drafts. **Save, Commit & Push** stages only the current article bundle and validates missing image references and unusually large images before publishing.

## How It Works

1. **Sign in** with GitHub (OAuth or Personal Access Token)
2. **Pick a repository** from your GitHub account (or add one manually)
3. **Clone** it to your device — files appear in the iOS Files app
4. **Edit** with any markdown editor
5. **Pull** to fetch remote changes, **Push** to commit and upload yours

Files live under `On My iPhone › GitSync.md` by default, or in a custom location you choose.

## Architecture

```
GitSync.md/
├── Sync.md/                    # iOS app source
│   ├── Sync_mdApp.swift        # App entry point
│   ├── ContentView.swift       # Root view router
│   ├── Models/
│   │   ├── AppState.swift      # Observable app state (repos, auth, sync)
│   │   ├── RepoConfig.swift    # Repository configuration model
│   │   └── GitState.swift      # Git state persistence
│   ├── Views/
│   │   ├── SetupView.swift     # Onboarding & sign-in
│   │   ├── RepoListView.swift  # Home screen — repo cards
│   │   ├── VaultView.swift     # Single repo — pull/push/status
│   │   ├── AddRepoView.swift   # Add new repository flow
│   │   ├── RepoPickerView.swift # GitHub repo browser
│   │   ├── SettingsView.swift  # Per-repo settings
│   │   ├── GitControlSheet.swift  # Staging, commit, and push workflow
│   │   ├── FileEditorView.swift    # Markdown and Front Matter editor
│   │   ├── HugoArticleListView.swift # Hugo article browser
│   │   ├── HugoNewContentView.swift  # Archetype-based article creation
│   │   └── DebugLogView.swift      # Searchable diagnostic log
│   └── Services/
│       ├── LocalGitService.swift    # libgit2 Git operations
│       ├── GitHubService.swift      # GitHub REST API client
│       ├── OAuthService.swift       # GitHub Device Flow
│       ├── HugoContentService.swift # Hugo bundles and Front Matter
│       ├── FileEditorDraftStore.swift # Recoverable local drafts
│       ├── DebugLogger.swift        # Redacted rotating diagnostics
│       ├── KeychainService.swift    # Secure token storage
│       └── CallbackURLHandler.swift # x-callback-url integration
├── Packages/
│   └── Clibgit2/               # Swift package wrapping the libgit2 C library
└── libgit2.xcframework/        # Pre-built libgit2 binary for iOS
```

### Git Implementation

All git operations use **libgit2** directly via C interop — no shelling out, no REST API tree manipulation. The `LocalGitService` wraps libgit2 to provide:

- **Clone** — `git_clone` with HTTPS credential callback
- **Pull** — Fetch with fast-forward or rebase workflows
- **Stage, Commit & Push** — Per-file, all-file, or Hugo article-bundle staging
- **Branches & conflicts** — Create, switch, merge, and resolve conflicted files
- **History, stashes & tags** — Inspect and manage local repository history
- **Status & Git LFS** — Track worktree/index changes and handle large assets

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

Linux cannot run Xcode locally. This fork includes a manually triggered GitHub Actions workflow that builds an unsigned IPA on a macOS runner for SideStore:

1. Push the repository to GitHub.
2. Open **Actions → Build SideStore IPA**.
3. Choose **Run workflow**.
4. Download the `GitSync-md-SideStore-*` artifact after the job succeeds.
5. Extract it and open `GitSync-md-SideStore.ipa` with SideStore.

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

### GitHub authentication

GitHub sign-in uses the native Device Flow and talks directly to GitHub. No OAuth proxy or client secret is required.

Tokens are stored in the iOS Keychain. Debug logs never intentionally include authorization headers, request bodies, tokens, or article contents; exported logs apply an additional redaction pass.

## Current Development Status

Core clone, pull, edit, stage, commit, and push flows are implemented, together with the Hugo writing workflow described above. The current priority is real-device regression testing through SideStore, especially draft recovery and failure handling. Planned work is tracked in [TODO.md](TODO.md).

## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.

Some areas where help would be appreciated:

- Conflict resolution UI (currently only fast-forward merges)
- Branch switching
- Selective file staging
- Background sync / scheduled pulls
- macOS support

### Editor Setup

If you use a SourceKit-LSP-based editor (Neovim, VS Code + Swift extension, Helix, Zed), generate a `buildServer.json` once so the LSP can resolve cross-file symbols:

```bash
brew install xcode-build-server
xcode-build-server config -project Sync.md.xcodeproj -scheme Sync.md
```

The generated `buildServer.json` is gitignored. Build in Xcode once afterwards so the LSP picks up the compiler index.

## License

[MIT](LICENSE) — Cody Bontecou
