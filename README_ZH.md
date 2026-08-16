# GitSync.md

**通过 Git 同步 Markdown 笔记**——一款原生 iOS 与 iPadOS 应用，可将 Git 仓库变成同步的 Markdown 知识库与 Hugo 写作空间。

[English](README.md) | [简体中文](README_ZH.md)

> [!NOTE]
> 这是 [CodyBontecou/GitSync.md](https://github.com/CodyBontecou/GitSync.md) 的独立维护分支，由 [MyEnergyFiled](https://github.com/MyEnergyFiled) 维护，并在上游项目基础上增加了高级 Git 操作、Git LFS 与 SSH 支持以及 Hugo 写作工作流。本项目不是上游官方发行版。

## 功能简介

GitSync.md 使用 [libgit2](https://libgit2.org) 将 Git 仓库直接克隆到 iPhone 或 iPad，并在设备文件系统中保留真正的 `.git` 目录。你可以在应用内编辑 Markdown，也可以使用 [Obsidian](https://obsidian.md)、iA Writer 或系统“文件”应用，再从 GitHub 或其他 Git 服务器拉取更新并推送更改。

**主要功能：**

- **完整的 Git 工作区**——通过 libgit2 完成克隆、获取、快进或变基、差异查看、选择性暂存或丢弃、提交与推送。
- **分支与恢复工具**——创建、切换、合并和删除分支，解决冲突，浏览历史并还原提交，以及管理储藏与标签。
- **Git LFS**——下载和上传 LFS 对象、检测大文件、提示自动跟踪，并支持通过 HTTPS 和 SSH 使用 LFS。
- **灵活的身份验证**——支持 GitHub OAuth 多账户或 PAT、通用 HTTPS 凭据、带主机密钥验证的 SSH 私钥、公开远程仓库和本地仓库。
- **多个仓库**——在同一应用中管理来自 GitHub、自托管 Git 服务和本地位置的仓库。
- **自定义存储位置**——将仓库存放在“文件”应用可访问的任意位置。
- **内置文件编辑**——浏览和重命名文件、新建 Markdown 文档、使用语法高亮与 Front Matter 控件编辑，并预览本地图片。
- **自动化**——通过 `x-callback-url` 触发同步，或使用“快捷指令”拉取单个或全部仓库。
- **Obsidian 与 iPad 支持**——将仓库用作 Obsidian 知识库，并使用针对 iPad 优化的布局。
- **Hugo 文章工作流**——从 `archetypes` 创建叶子包、搜索和筛选文章、编辑 Front Matter，并管理每篇文章的 `images/` 目录。
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

文章管理器会显示封面、标题、日期和草稿状态，支持搜索、筛选，按标题、目录、发布日期、修改时间或草稿状态排序，直接切换草稿/发布状态，以及安全地移动或重命名文章目录。移动文章时会保留文章包内的图片链接，并重新计算指向包外图片的相对路径。每个仓库都能在 `.gitsync-hugo.json` 中配置额外的顶层文本、布尔和数字 Front Matter 字段；未配置字段保持原样。编辑器会在所有 Markdown 模式中持续显示并允许修改当前发布状态，提供保留常见 Hugo 格式与时区的发布日期选择，并支持 Markdown 格式化、语法高亮、撤销/重做，实时原生预览标题、发布信息、标签、封面、相对图片与链接、代码块、表格、短代码占位和正文，图片插入与管理，以及可恢复的本地草稿。分屏模式会在 iPad 并排布局和紧凑的上下布局之间自动适配，并明确标记尚未保存的预览内容。**保存、提交并推送**只会暂存当前文章包，并在一个发布前摘要中汇总 Front Matter、缺失图片引用、异常大图片和未保存的编辑内容。推送失败后会保留本地内容和发布选择，并根据失败阶段复用暂存文件或已有本地提交进行重试。

原生预览采用易读的纸张式画布，并为衬线标题、引用、分隔线、代码面板和表格提供统一样式。感知 Hugo 主题的渲染仍保留为后期独立路线。

## 工作原理

1. 使用 GitHub 登录；使用其他 Git 远程或本地仓库时，也可跳过账户登录。
2. 从 GitHub 账户中选择仓库，或手动添加仓库 URL。
3. 将仓库克隆到设备，文件会出现在 iOS“文件”应用中。
4. 使用任意 Markdown 编辑器进行编辑。
5. 通过**拉取**获取远程更改，再选择性暂存、提交并**推送**本地更改。

默认情况下，文件位于“我的 iPhone › GitSync.md”中，也可以存放到你选择的自定义位置。

## 架构

```text
GitSync.md/
├── Sync.md/                    # iOS 应用源码
│   ├── Sync_mdApp.swift        # 应用入口
│   ├── ContentView.swift       # 根视图路由
│   ├── Models/                 # 应用、仓库、Git 操作与界面状态
│   ├── Views/                  # 仓库、Git、文件、Hugo 与诊断界面
│   ├── Services/               # libgit2、Git LFS、GitHub、OAuth、Hugo 与钥匙串
│   └── Shortcuts/              # 用于拉取仓库的 App Intents
├── Packages/
│   └── Clibgit2/               # libgit2 C 库的 Swift Package 封装
└── libgit2.xcframework/        # 预编译的 iOS libgit2 二进制文件
```

### Git 实现

所有 Git 操作均通过 C 互操作直接使用 **libgit2**，不会调用 shell，也不会通过 REST API 操作文件树。`LocalGitService` 封装了以下能力：

- **远程访问**——通过 HTTPS、SSH、公开或本地传输克隆和获取仓库。
- **拉取**——先分析分歧状态，再执行快进或变基。
- **更改管理**——显示状态与统一差异，并可暂存、取消暂存或丢弃单个文件及全部更改。
- **提交与推送**——推送当前分支、所选更改或仅当前 Hugo 文章包。
- **分支与冲突**——创建、切换、合并和删除分支，继续或中止合并/变基，并在应用内解决冲突文件。
- **历史、储藏与标签**——浏览提交详情、还原提交，并按需创建、应用、弹出、删除或推送 Git 对象。
- **Git LFS**——转换、下载、缓存、校验并上传 LFS 对象。

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

### 快捷指令

GitSync.md 提供**拉取仓库**和**拉取所有仓库**两个 App Intent，可在“快捷指令”应用中使用，也可以加入“打开 GitSync.md 时运行”的个人自动化。

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

候选版本的实机测试遵循 [REAL_DEVICE_REGRESSION.md](REAL_DEVICE_REGRESSION.md)。该矩阵会区分适合模拟器 XCTest 的覆盖，以及必须使用真机和一次性远程仓库验证的凭据、传输、LFS、取消与数据保护场景。

### GitHub 身份验证

GitHub 登录使用原生 Device Flow 并直接与 GitHub 通信，无需 OAuth 代理或客户端密钥。

令牌保存在 iOS 钥匙串中。调试日志不会有意记录授权标头、请求正文、令牌或文章内容；导出的日志还会再次执行脱敏。

## 开发状态与路线图

上述 Git 工作区、Git LFS 传输、身份验证方式、文件编辑器、自动化入口与 Hugo 写作流程均已实现。当前工作重点包括：

- 改进长任务进度、取消与重试提示，并扩大 Git 传输回归矩阵
- 在 iOS 执行与数据保护限制内评估后台同步和自动化
- 后期实现感知 Hugo 主题的预览

详细且按优先级排列的清单继续保存在 [TODO.md](TODO.md) 中。这样可以避免在项目概览中重复容易快速变化的实现细节。

## 参与贡献

欢迎贡献！你可以提交 Issue 或 Pull Request。[TODO.md](TODO.md) 中的未完成任务是了解当前优先事项的最佳入口。

### 编辑器配置

如果使用基于 SourceKit-LSP 的编辑器（Neovim、VS Code + Swift 扩展、Helix、Zed），请生成一次 `buildServer.json`，让 LSP 能解析跨文件符号：

```bash
brew install xcode-build-server
xcode-build-server config -project Sync.md.xcodeproj -scheme Sync.md
```

生成的 `buildServer.json` 已被 Git 忽略。随后在 Xcode 中构建一次，以便 LSP 获取编译器索引。

## 许可证

[MIT](LICENSE)。原项目版权 © 2025–2026 Cody Bontecou；本分支修改版权 © 2026 [MyEnergyFiled](https://github.com/MyEnergyFiled)。来源与署名见 [NOTICE.md](NOTICE.md)，随附依赖的许可证信息见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
