# GitSync.md

**通过 Git 同步 Markdown 笔记**——一款原生 iOS 与 iPadOS 应用，可将任意 GitHub 仓库变成同步的 Markdown 知识库。

[English](README.md) | [简体中文](README_ZH.md)

## 功能简介

GitSync.md 使用 [libgit2](https://libgit2.org) 将 GitHub 仓库直接克隆到 iPhone 或 iPad，并在设备文件系统中保留真正的 `.git` 目录。你可以使用 [Obsidian](https://obsidian.md)、iA Writer、系统“文件”应用或其他编辑器修改 Markdown 文件，再从 GitHub 拉取更新或将更改推送回去。

**主要功能：**

- **真正的 Git**——通过 libgit2 完成克隆、拉取、变基、暂存、提交、推送、分支切换、储藏与标签管理以及冲突解决。
- **多个仓库**——同时管理多个 GitHub 仓库。
- **自定义存储位置**——将仓库存放在“文件”应用可访问的任意位置。
- **Obsidian 集成**——通过 `x-callback-url` 与 Obsidian 知识库配合，实现自动同步。
- **GitHub OAuth 与 PAT**——使用 GitHub OAuth 登录或粘贴个人访问令牌。
- **私有仓库支持**——同时支持公开和私有仓库。
- **iPad 支持**——针对 iPad 优化的界面布局。
- **Hugo 文章工作流**——从 `archetypes` 创建叶子包、编辑 Front Matter，并在应用中管理每篇文章的 `images/` 目录。
- **更安全的发布**——支持草稿恢复、仅暂存当前文章、推送前校验，并在 Git 或身份验证失败时保护本地内容。
- **内置诊断工具**——可搜索的实时日志，包含 GitHub/OAuth 耗时和状态详情，并支持自动轮转、导出与凭据脱敏。

## Hugo 写作工作流

此分支为 Hugo 仓库提供原生写作流程，可创建如下叶子包：

```text
content/posts/my-article/
├── index.md
└── images/
```

选择 `archetypes/default.md`、`archetypes/moments.md` 等原型，指定目标内容目录，并输入英文目录名。文章标题会写入生成的 `index.md` Front Matter，无需与目录名相同。

文章管理器会显示标题、日期、草稿状态和封面字段。编辑器支持 Markdown 格式化、撤销/重做、本地图片预览、图片插入与管理，以及可恢复的本地草稿。**保存、提交并推送**只会暂存当前文章包，并在发布前检查缺失的图片引用和异常大的图片。

## 工作原理

1. 使用 GitHub 登录（OAuth 或个人访问令牌）。
2. 从 GitHub 账户中选择仓库，也可手动添加。
3. 将仓库克隆到设备，文件会出现在 iOS“文件”应用中。
4. 使用任意 Markdown 编辑器进行编辑。
5. 通过**拉取**获取远程更改，通过**推送**提交并上传本地更改。

默认情况下，文件位于“我的 iPhone › GitSync.md”中，也可以存放到你选择的自定义位置。

## 架构

```text
GitSync.md/
├── Sync.md/                    # iOS 应用源码
│   ├── Sync_mdApp.swift        # 应用入口
│   ├── ContentView.swift       # 根视图路由
│   ├── Models/                 # 仓库、身份验证与同步状态
│   ├── Views/                  # SwiftUI 页面与编辑器
│   └── Services/               # Git、GitHub、OAuth、Hugo 与钥匙串服务
├── Packages/
│   └── Clibgit2/               # libgit2 C 库的 Swift Package 封装
└── libgit2.xcframework/        # 预编译的 iOS libgit2 二进制文件
```

### Git 实现

所有 Git 操作均通过 C 互操作直接使用 **libgit2**，不会调用 shell，也不会通过 REST API 操作文件树。`LocalGitService` 封装了以下能力：

- **克隆**——使用带 HTTPS 凭据回调的 `git_clone`。
- **拉取**——支持快进或变基流程的 Fetch。
- **暂存、提交与推送**——可按文件、全部文件或 Hugo 文章包暂存。
- **分支与冲突**——创建、切换、合并分支并解决冲突文件。
- **历史、储藏与标签**——检查并管理本地仓库历史。
- **状态与 Git LFS**——跟踪工作区/索引变化并处理大型资源。

生成的是标准 `.git` 目录，因此仓库也兼容 [Obsidian Git](https://github.com/Vinzent03/obsidian-git) 等其他 Git 工具。

### x-callback-url API

外部应用可通过 URL Scheme 触发同步操作：

```text
syncmd://x-callback-url/<action>?repo=<folder-name>&x-success=<url>&x-error=<url>
```

| 操作 | 说明 |
|---|---|
| `pull` | 获取并快进 |
| `push` | 暂存全部文件、提交并推送 |
| `sync` | 先拉取再推送 |
| `status` | 返回分支、SHA 和更改数量 |

## 构建

### 要求

- **Xcode 16+**
- **iOS 17.0+** 部署目标
- 配备 Apple Silicon 的 Mac（Intel Mac 需使用 Rosetta）

### 步骤

1. 克隆仓库：

   ```bash
   git clone https://github.com/MyEnergyFiled/GitSync.md.git
   cd GitSync.md
   ```

2. 在 Xcode 中打开：

   ```bash
   open Sync.md.xcodeproj
   ```

3. 选择目标设备或模拟器并构建（`⌘B`）。

仓库已包含预编译的 `libgit2.xcframework`，无需额外配置依赖项。

## 在 Linux 上构建 IPA

Linux 无法在本地运行 Xcode。此分支提供一个手动触发的 GitHub Actions 工作流，可在 macOS Runner 上为 SideStore 构建未签名 IPA：

1. 将仓库推送到 GitHub。
2. 打开 **Actions → Build SideStore IPA**。
3. 选择 **Run workflow**。
4. 任务成功后下载 `GitSync-md-SideStore-*` 构建产物。
5. 解压后使用 SideStore 打开 `GitSync-md-SideStore.ipa`。

GitHub 中不保存 Apple 证书；SideStore 会在安装时对 IPA 签名。

## 测试

在本地运行单元 XCTest：

```bash
xcodebuild test \
  -project Sync.md.xcodeproj \
  -scheme Sync.md \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SyncMDTests \
  -parallel-testing-enabled YES \
  -maximum-parallel-testing-workers 2
```

如果没有 `iPhone 17` 模拟器，可用 `xcrun simctl list devices available` 中的任意可用 iPhone 模拟器替换目标设备。

本地 Git 测试会在 `FileManager.default.temporaryDirectory` 中创建以 UUID 命名的隔离临时仓库，并使用 `defer` 清理，因此 XCTest 可安全地并行运行测试类。CI 将并行任务限制为两个，以避免模拟器内存压力。除非测试明确涉及推送，否则测试夹具应使用仅本地提交（`SyncMDTests` 中的 `commitLocalFixtureChanges`），避免依赖没有 `origin` 远程仓库时预期发生的推送失败。

同一单元测试门禁会通过 `.github/workflows/xctest.yml` 在拉取请求和推送到 `main` 时运行。

### GitHub 身份验证

GitHub 登录使用原生 Device Flow 并直接与 GitHub 通信，无需 OAuth 代理或客户端密钥。

令牌保存在 iOS 钥匙串中。调试日志不会有意记录授权标头、请求正文、令牌或文章内容；导出的日志还会再次执行脱敏。

## 当前开发状态

克隆、拉取、编辑、暂存、提交和推送等核心流程以及上述 Hugo 写作工作流均已实现。目前重点是通过 SideStore 进行真机回归测试，尤其是草稿恢复和失败处理。计划中的工作记录在 [TODO.md](TODO.md) 中。

## 参与贡献

欢迎贡献！你可以提交 Issue 或 Pull Request。

特别欢迎协助以下方向：

- 冲突解决界面（目前仅支持快进合并）
- 分支切换
- 选择性文件暂存
- 后台同步/定时拉取
- macOS 支持

### 编辑器配置

如果使用基于 SourceKit-LSP 的编辑器（Neovim、VS Code + Swift 扩展、Helix、Zed），请生成一次 `buildServer.json`，让 LSP 能解析跨文件符号：

```bash
brew install xcode-build-server
xcode-build-server config -project Sync.md.xcodeproj -scheme Sync.md
```

生成的 `buildServer.json` 已被 Git 忽略。随后在 Xcode 中构建一次，以便 LSP 获取编译器索引。

## 许可证

[MIT](LICENSE) — Cody Bontecou
