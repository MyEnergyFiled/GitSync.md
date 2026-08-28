# iOS/iPadOS 真实 Hugo 主题预览开发规格

> 文档状态：已确认方向，等待实现
> 目标项目：HugoInk（`Sync.md`）
> 目标平台：iOS / iPadOS 16+
> 固定 Hugo 版本：`0.134.3`
> 首个验收博客：`/home/hotbird/hugo-app/hotbitd`
> 首个验收主题：`PaperMod-PE`

## 1. 给后续开发对话的执行指令

本文件是实现依据，不是讨论草稿。后续开发对话开始后，应先完整阅读本文件和仓库根目录的 `AGENTS.md`，再检查当前工作树和相关源码。

必须遵守以下要求：

1. 使用真正的 Hugo `0.134.3` 源码和渲染引擎，不得继续扩展 Swift 近似模板解析器来冒充 Hugo。
2. 不建设远程预览服务器，不上传博客内容，不依赖开发者自托管服务。
3. 不复制完整博客仓库。仓库作为源文件使用，未保存内容通过覆盖层参与构建。
4. 不向博客仓库写入 `public/`、`.hugo_build.lock`、临时配置或预览缓存。
5. 一个博客可以发现和选择多个本地主题；切换主题不得改写博客的 Hugo 配置文件。
6. 单篇预览必须保留 Hugo 完整站点对象图，只限制渲染输出，不能只解析一份 Markdown。
7. 遇到 iOS 无法真实支持的 Hugo 功能，应给出明确错误，不得使用近似结果静默降级。
8. 实现必须分阶段进行。原生 Hugo 在真机上跑通之前，不要大规模删除现有预览代码。
9. Swift、工程配置或依赖发生变化后，必须按仓库指南通过 XCTest 工作流验证。
10. 所有新增用户可见字符串必须同步本地化 `zh-Hans` 与 `zh-Hant`。

## 2. 已确认的产品决策

### 2.1 最终方向

预览链路为：

```text
Git 博客仓库（只读源）
        +
未保存文章/临时配置（覆盖层）
        ↓
Hugo 0.134.3 原生引擎
        ↓
App Cache 或内存中的真实 Hugo 输出
        ↓
设备内临时 HTTP Origin
        ↓
WKWebView
```

### 2.2 明确不采用的方向

- Swift 自行实现 Go Template。
- Swift 自行实现 Hugo shortcode、partial 或资源管线。
- 仅使用 Markdown 渲染器并套用主题 CSS。
- 为每次预览复制一份完整仓库。
- 把预览任务发送到 Cloudflare、GitHub Actions 或自建服务器。
- 使用浮动的 `latest` Hugo。
- 为不兼容主题生成“看起来差不多”的替代页面。

### 2.3 版本约束

- App 内置并固定 Hugo `0.134.3`。
- Cloudflare Pages 继续固定 `HUGO_VERSION=0.134.3`。
- 必须从 Cloudflare 构建日志确认其构建类型是 Standard 还是 Extended。
- 当前 `hotbitd + PaperMod-PE` 已使用官方 Standard Hugo `0.134.3` 成功完整构建，因此首期优先 Standard。
- 主题声明的最低 Hugo 版本高于 `0.134.3` 时，App 显示不兼容，不自动换用其他 Hugo 版本。

## 3. “真实预览”的一致性契约

### 3.1 必须真实执行的能力

以下内容必须由 Hugo 自己处理：

- 项目和主题模板查找顺序。
- `baseof`、`define`、`block`、`partial`、`partialCached`。
- shortcode 和 render hook。
- front matter、cascade、语言和输出格式。
- `.Site`、`.Pages`、`.Site.RegularPages`、taxonomy、menu。
- 上一篇/下一篇、相关文章及页面集合排序。
- `resources.Get`、`resources.Match`、`resources.Concat`。
- `resources.Minify`、`fingerprint`、`js.Build`。
- 页面资源、项目资源、主题资源和 static 覆盖规则。
- Hugo 配置合并和项目 layouts 覆盖主题 layouts 的规则。

### 3.2 允许存在但必须说明的差异

编辑预览与 Cloudflare 生产构建允许存在这些明确差异：

- 编辑预览使用设备内本地 `baseURL`，生产验证使用博客真实 `baseURL`。
- 编辑预览可包含当前草稿和未保存内容。
- 构建时间、CPU 架构和操作系统不同。
- 远程 CDN 在离线状态下不可用。
- 依赖外部进程的主题在 iOS 上可能无法运行。

不得把“同一 Hugo 语义”描述成“所有文件跨平台逐字节完全相同”。对于当前不使用外部构建程序的 `hotbitd`，目标是模板结构、页面内容、资源管线和浏览器视觉一致。

### 3.3 两种预览模式

#### 编辑预览

用于编辑文章时快速查看：

```text
Hugo: 0.134.3
environment: production
buildDrafts: true
baseURL: 本地临时 HTTP Origin
renderSegments: 当前文章
content: 包含未保存覆盖内容
```

即使是编辑预览也使用 `production` 环境，因为主题可能通过 `hugo.IsProduction` 改变模板行为。

#### 生产验证

用于与 Cloudflare 对比：

```text
Hugo: 0.134.3
environment: production
baseURL: 博客真实 baseURL
theme: 仓库真实配置
draft/future/expired: 与 Cloudflare 构建参数一致
content: 仓库真实内容，不使用编辑覆盖
render: 完整站点
```

## 4. 当前代码审计结论

### 4.1 现有近似预览

当前存在：

- `Sync.md/Services/HugoThemePreviewService.swift`
- `Sync.md/Services/HugoTemplateCompatibilityService.swift`
- `Sync.md/Services/HugoThemeSnapshotService.swift`
- `Sync.md/Views/HugoThemeWebPreview.swift`
- `SyncMDTests/HugoThemePreviewFixture/`

这些代码不是实际 Hugo：

- Swift 手动解析 Markdown 和部分 front matter。
- 只识别少量模板表达式。
- 只模拟少数 shortcode。
- 不具备真实 `.Site` 对象图。
- 发现主题 CSS 后直接挂载，而不是运行 Hugo Pipes。
- 对未知表达式输出占位符。
- 删除主题脚本并在 WKWebView 中禁用 JavaScript。
- 所谓“官方 Hugo 快照”只比较正文文本和少量元素计数。

这套实现只能继续作为迁移期间的旧代码，不能作为新架构基础。

### 4.2 现有原生 Markdown 预览

`FileEditorView` 当前实际展示的是 `nativeMarkdownPreview`。该能力可继续保留，作为轻量、快速、无主题的阅读预览，但 UI 必须明确区分：

```text
快速预览：Swift 原生 Markdown
主题预览：真实 Hugo 0.134.3
```

不能再把快速预览标记为 Hugo 主题预览。

### 4.3 当前主题预览 UI 状态

`FileEditorView` 已定义 `previewStyle` 和 `themeWebPreview`，但 `markdownPreview` 当前固定返回 `nativeMarkdownPreview`。实现时需要重新接通模式选择，而不是假设现有主题模式已经投入使用。

### 4.4 可以复用的现有能力

- `HugoSiteConfigurationService` 的仓库配置发现思路。
- `RepositoryFileDestinationValidator` 的路径边界校验。
- `FileEditorDraftStore` 和 `pendingContent` 的未保存内容来源。
- `HugoPreviewDevice` 的设备宽度模型。
- `FileEditorView` 的 Preview/Split UI 入口。
- `HugoThemeWebPreview` 中非持久化 WKWebView 数据仓库的安全思路。
- 现有 Git 仓库访问、security-scoped bookmark 和 vault 路径能力。

配置的最终解释必须交给 Hugo。Swift 配置解析只适合主题列表展示和预检查，不能决定真实渲染行为。

### 4.5 `hotbitd` 已知基线

后续对话不必重新猜测首个博客结构，可先验证这些已检查事实是否仍成立：

- 根配置为 `hugo.yaml`，当前主题是 `PaperMod-PE`。
- 仓库包含 `PaperMod-PE`、`PaperMod`、`PaperModX` 三个实体主题目录，不是有效 Git submodule gitlink。
- 三个主题声明的最低 Hugo 版本分别不高于 `0.125.3`、`0.112.4`、`0.83.0`，均低于固定版本 `0.134.3`。
- 项目根 `layouts/partials/head.html` 覆盖主题同名 partial，并包含 PaperMod-PE 定制内容。
- PaperMod-PE 使用 `resources.Get`、`resources.Match`、Concat、Minify、Fingerprint 和 `js.Build`。
- 未发现 PostCSS、Tailwind、Node/npm、`resources.GetRemote` 或必须执行的外部构建命令。
- 主题页面运行时引用 MathJax/KaTeX、Font Awesome、jQuery/Fancybox 等 CDN；这是 WebView 运行时网络问题，不是 Hugo build-time 问题。
- 当前 Standard Hugo `0.134.3` 已能成功构建该仓库；Hugo `0.165.0` 会因主题旧模板路径失败，因此不得误升级。
- 当前 `.gitignore` 只忽略 `public` 和 `.idea`；不能据此判断 Hugo 输入或写入安全。
- 仓库已有 tracked `resources/_gen`，预览不得覆盖这些文件。

如果 `/home/hotbird/hugo-app/hotbitd` 在新环境中不存在，不要把它复制进 App 仓库作为单元测试依赖；使用真实 fixture 完成自动化测试，再让用户提供或重新 Clone 验收博客。

## 5. 目标模块划分

建议新增以下模块；名称可以根据相邻代码风格微调，但职责不得混合。

```text
Sync.md/
├── Models/
│   ├── HugoRuntimeModels.swift
│   └── HugoPreviewState.swift
├── Services/
│   ├── HugoRuntimeService.swift
│   ├── HugoPreviewBuildCoordinator.swift
│   ├── HugoPreviewWorkspace.swift
│   ├── HugoThemeDiscoveryService.swift
│   ├── HugoPreviewHTTPServer.swift
│   ├── HugoPreviewCache.swift
│   └── HugoPreviewCapabilityService.swift
├── Views/
│   ├── HugoRealPreviewView.swift
│   └── HugoPreviewControls.swift
└── Resources/（如桥接需要）

Packages/HugoRuntime/
├── Package.swift
└── Sources/HugoRuntime/
    └── HugoRuntime.swift 或公开头文件

HugoRuntime.xcframework

scripts/
└── build-hugo-ios.sh
```

Go 包装层建议单独放置：

```text
Native/HugoBridge/
├── go.mod
├── bridge.go
├── session.go
├── filesystem.go
├── build.go
├── errors.go
└── bridge_test.go
```

不要将 Go 构建逻辑塞入 Swift Services。

## 6. 第一技术闸门：Hugo 0.134.3 iOS 原生化

这是整个项目风险最高的步骤。未通过前，不应承诺 UI 完成日期，也不应删除旧代码。

### 6.1 固定源码

- 只使用 `gohugoio/hugo` 标签 `v0.134.3`。
- 构建脚本验证 tag/commit，不跟随 `master`。
- 记录 Hugo、Go、gomobile 和构建工具版本。
- 生成第三方许可证清单；Hugo 为 Apache-2.0，主题许可证独立处理。

### 6.2 推荐桥接方式

优先尝试：

1. 创建一个只暴露简单类型的 Go façade package。
2. façade 内部使用 Hugo `hugolib` 和其文件系统/配置组件。
3. 使用 `gomobile bind` 生成 iOS XCFramework。
4. 若 gomobile 无法处理 Hugo 依赖图，改用 Go `c-archive`，分别生成真机和模拟器产物，再组装 XCFramework。

不得尝试在 iOS 中启动 Hugo CLI 子进程；iOS 没有可依赖的通用 `Process`/shell 执行环境。

### 6.3 FFI 接口原则

跨 Swift/Go 边界只传简单值：

- UTF-8 JSON 字符串。
- `Data`/byte array。
- 整数 session handle。
- 明确的 error code 和 message。

不要跨边界暴露 Hugo 内部对象、Go map、复杂泛型或回调图。

推荐最小接口：

```text
RuntimeVersion() -> JSON
OpenSession(requestJSON) -> sessionHandle / error
Build(sessionHandle, requestJSON) -> responseJSON / error
ReadOutput(sessionHandle, path) -> bytes / error
ListOutput(sessionHandle) -> JSON / error
Invalidate(sessionHandle, requestJSON) -> error
CloseSession(sessionHandle) -> error
```

`RuntimeVersion` 必须返回：

```json
{
  "hugoVersion": "0.134.3",
  "extended": false,
  "goVersion": "...",
  "target": "ios/arm64"
}
```

### 6.4 P0 验收条件

以下条件全部满足才算通过：

- iOS Simulator 能加载 XCFramework。
- 真机 iPhone 或 iPad 能加载 XCFramework。
- 能在 App Sandbox 中读取测试 Hugo 项目。
- 能构建一个包含 base template、partial、shortcode 和资源管线的页面。
- 能返回生成的 HTML 和 CSS/JS。
- `RuntimeVersion` 精确返回 `0.134.3`。
- 构建前后源项目无变化。
- 不调用 shell、Node、系统 Hugo 可执行文件。

若 P0 失败，停止后续真实预览开发并报告具体阻塞。不得回退到 Swift 近似预览并宣称目标完成。

## 7. Swift 侧核心接口

建议先定义协议，便于单元测试和隔离 FFI：

```swift
protocol HugoRuntimeProviding: Sendable {
    func version() async throws -> HugoRuntimeVersion
    func openSession(_ request: HugoOpenSessionRequest) async throws -> HugoSessionID
    func build(_ request: HugoBuildRequest, in session: HugoSessionID) async throws -> HugoBuildResult
    func readOutput(path: String, in session: HugoSessionID) async throws -> Data
    func closeSession(_ session: HugoSessionID) async
}
```

核心模型建议：

```swift
struct HugoRuntimeVersion: Codable, Equatable, Sendable {
    let version: String
    let isExtended: Bool
    let goVersion: String
    let target: String
}

struct HugoThemeDescriptor: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let directoryName: String
    let displayName: String
    let minimumHugoVersion: String?
    let isCompatible: Bool
    let capabilityWarnings: [HugoCapabilityWarning]
}

struct HugoOverlayFile: Codable, Equatable, Sendable {
    let repositoryRelativePath: String
    let contents: Data
}

enum HugoBuildMode: String, Codable, Sendable {
    case editorPage
    case productionSite
}

struct HugoBuildRequest: Codable, Equatable, Sendable {
    let mode: HugoBuildMode
    let repositoryRoot: String
    let articleRepositoryRelativePath: String?
    let selectedTheme: String?
    let baseURL: String
    let environment: String
    let buildDrafts: Bool
    let buildFuture: Bool
    let buildExpired: Bool
    let overlayFiles: [HugoOverlayFile]
    let generation: UInt64
}

struct HugoBuildResult: Codable, Equatable, Sendable {
    let generation: UInt64
    let entryPath: String
    let renderedPaths: [String]
    let warnings: [HugoDiagnostic]
    let statistics: HugoBuildStatistics
    let cacheKey: String
}
```

桥接错误必须转换为结构化 Swift 错误，不能只返回一大段控制台文本。

## 8. 并发和生命周期

### 8.1 Build Coordinator

新增 `actor HugoPreviewBuildCoordinator`：

- 所有 Hugo session 生命周期由它管理。
- 每个仓库/主题最多一个活动构建。
- 不允许两个构建同时修改同一输出目录。
- 编辑输入 debounce 建议 350–500ms。
- 新 generation 到来后取消或废弃旧 generation 结果。
- UI 只接收最新 generation。
- Git pull、checkout、删除仓库等操作开始前关闭相关 Hugo session。
- App 进入后台后可保留轻量缓存，但应停止本地 HTTP listener。

### 8.2 Session Key

```text
repository ID
+ resolved repository root
+ Git HEAD（如存在）
+ dirty source signature
+ Hugo version/build flavor
+ selected theme or theme stack
+ effective config signature
```

未保存正文不进入 session identity，而进入 build generation；否则每次键入都会创建新 session。

### 8.3 失效规则

- 当前文章变化：只失效当前页面及其资源依赖。
- front matter 的 taxonomy/date/type/layout 变化：重建站点对象图。
- `hugo.*`、`config/**` 变化：关闭并重开 session。
- `layouts/**`、`themes/**`、`data/**`、`i18n/**` 变化：关闭并重开对应主题 session。
- `assets/**`、`static/**` 变化：失效资源缓存并重新构建。
- Git pull/checkout 完成：关闭仓库全部 session。

初期可以选择“配置或主题变化即重开 session”的保守策略，先保证正确性，再优化。

## 9. 文件系统设计：不复制完整仓库

### 9.1 四层文件系统

```text
Layer 1  Repository Source
         已 Clone 的真实博客仓库，只读访问

Layer 2  Overlay
         未保存 Markdown、临时主题选择、临时 Segment 配置

Layer 3  Hugo Output
         Hugo 生成的 public 内容，位于 App Cache 或内存

Layer 4  Hugo Resource Cache
         resources/_gen、文件缓存、图片和资源管线缓存
```

### 9.2 源仓库保护

Hugo 的所有写入必须重定向：

```text
publishDir   -> Library/Caches/HugoPreview/<repo>/<session>/public
resourceDir  -> Library/Caches/HugoPreview/<repo>/<session>/resources
cacheDir     -> Library/Caches/HugoPreview/<repo>/<session>/cache
build lock   -> 禁用，改由 Swift actor 串行化
```

不得依赖 `.gitignore` 保护源仓库。`public` 被 Git 忽略并不表示写入安全，因为 `git status` 看不到它。

### 9.3 Overlay 优先级

同路径文件优先级：

```text
未保存编辑内容
> 临时预览配置
> 仓库真实文件
> 主题真实文件（由 Hugo 自身挂载规则处理）
```

优先使用 Hugo/afero 支持的内存或 union 文件系统。若 `v0.134.3` 内部 API 无法直接注入 overlay，可在 App Cache 创建只包含变更文件的小型 shadow tree，并通过 Hugo mounts 叠加。允许复制单个被编辑文件和临时配置，不允许复制整个仓库。

### 9.4 生成输出不是仓库副本

Hugo 为预览生成 HTML/CSS/JS 和发布后的 static 文件是正常构建产物，可以放在可回收 Cache 中。这不等于复制博客源仓库。

首期以正确性为优先，允许 Hugo 将 static 发布到独立输出目录。后续可复用输出目录并按资源签名增量更新，避免每次重复写入字体等大文件。

### 9.5 安全路径规则

- 所有传入路径都必须是仓库相对路径。
- 拒绝绝对路径、`..`、NUL、URL scheme。
- 解析 security-scoped bookmark 后再建立 session。
- session 存续期间维持访问权限，关闭时释放。
- 不跟随越出仓库的符号链接。
- 主题/Hugo Module 的合法挂载若明确指向仓库外，应作为单独能力处理，不能绕过验证器。

## 10. 单篇预览设计

### 10.1 不能只加载一篇 Markdown

PaperMod-PE 的文章导航使用 `site.RegularPages`。真实页面还可能依赖 taxonomy、menu、related、translations 和 `.Site.Data`。因此必须先建立完整站点对象图。

### 10.2 使用 Hugo Segments

Hugo `0.134.3` 已支持 `renderSegments`。目标行为是：

- 加载完整站点和页面元数据。
- 保留所有模板可访问对象。
- 仅渲染当前文章对应 HTML output。
- 仍运行该页面依赖的 Hugo Pipes。

临时 Segment 只存在覆盖配置中，不写 `hugo.yaml`。

示意配置：

```yaml
segments:
  hugoInkCurrentPage:
    includes:
      - path: /posts/example
        output: html

renderSegments:
  - hugoInkCurrentPage
```

注意：Segment 的 `path` 是 Hugo logical path，不一定等于内容文件路径或最终 permalink。实现不能只靠字符串替换推断。桥接层应建立“仓库内容路径 → Hugo logical path → output path”映射。

### 10.3 两阶段页面定位

推荐：

1. `OpenSession` 加载配置和站点对象图。
2. 桥接层根据 repository-relative content path 定位 Hugo Page。
3. 获取 logical path、language、output formats、permalink。
4. 生成内存 Segment。
5. Build 只渲染目标页面。

如果当前文件不是可发布 Page，应返回明确诊断，例如：

- Headless bundle。
- 未识别 content mount。
- draft 未包含。
- 日期在未来且 `buildFuture=false`。
- 没有 HTML output format。

### 10.4 内部链接

预览 HTTP server 收到尚未生成的站内路径时：

1. 根据已建立的 page index 定位目标 Page。
2. 通知 Build Coordinator。
3. 生成新 Segment build。
4. 构建完成后响应或让 WebView 重试。

MVP 可先拦截 WKNavigationAction，完成构建后再导航；不要在 HTTP 请求线程中长时间阻塞。

### 10.5 未保存文章

`FileEditorView.pendingContent` 作为 overlay data 传给运行时：

```text
repositoryRelativePath: content/.../index.md
contents: pendingContent UTF-8 data
```

不得先保存到 Git 工作树。用户点击正常保存时才由现有编辑器写入仓库。

## 11. 多主题设计

### 11.1 发现主题

扫描仓库中的：

```text
themes/<name>/theme.toml
themes/<name>/hugo.toml
```

主题描述至少包含：

- 目录名。
- `name`。
- `min_version`。
- 作者和许可证（如存在）。
- 是否满足固定 Hugo `0.134.3`。
- 是否发现外部构建工具调用。

不要通过网络搜索并自动下载主题；第一阶段只使用仓库已经包含的主题。

### 11.2 主题选择不写配置

主题选择保存在 App 的 repository-scoped 设置中，通过临时 Hugo config override 传入运行时：

```yaml
theme: PaperMod
```

不得修改仓库真实 `hugo.yaml`。如果原配置的 `theme` 是数组，必须保留 Hugo theme/module composition 语义，不能强行转换成单字符串。

### 11.3 严格模式是默认模式

严格模式只覆盖 `theme` 值，其余配置和项目文件全部保留。项目 `layouts/**` 继续优先于主题 layouts，这是 Hugo 真实规则。

`hotbitd/layouts/partials/head.html` 是 PaperMod-PE 定制覆盖。切换到 PaperMod/PaperModX 后如果它导致异常，严格模式应真实显示异常，不得偷偷跳过。

### 11.4 纯主题模式不是 MVP 必需项

未来可以增加“纯主题体验”，临时排除项目的主题特定 layouts，但必须明确标注为非生产一致预览。不得默认启用。

### 11.5 主题隔离

每个主题拥有独立：

- Hugo session。
- output directory。
- resource cache namespace。
- page/output index。
- WebView navigation history。

缓存键包含主题目录和内容签名，禁止复用另一主题生成的 fingerprint 资源。

## 12. 预览 HTTP Origin

### 12.1 为什么使用设备内 HTTP

目标不是部署网站，而是给 WKWebView 提供接近正常网站的 Origin。相较 `file://` 或自定义 scheme，HTTP 对以下功能更可靠：

- 相对链接。
- ES modules。
- Fetch/XHR。
- Cookie 和 localStorage。
- CORS 与 Origin 判断。
- 主题运行时 JavaScript。

### 12.2 服务约束

- 只监听 `127.0.0.1`，不监听 `0.0.0.0`。
- 使用系统分配的随机端口。
- URL 包含随机 session token。
- 仅支持 GET/HEAD。
- 禁止目录列表。
- 路径规范化后才能读取输出。
- MIME type 必须正确。
- 支持 `index.html` 路由和 Hugo pretty URL。
- 支持 CSS/JS source map 时仍需路径边界校验。
- 关闭预览或进入后台时停止 listener。
- 如果 ATS 阻止本地 HTTP，仅配置最小范围的本地网络例外；不得为了预览加入全局 `NSAllowsArbitraryLoads`。

示意 URL：

```text
http://127.0.0.1:<random>/<token>/posts/example/
```

### 12.3 WKWebView 配置

真实主题预览：

- `WKWebsiteDataStore.nonPersistent()`。
- 允许 JavaScript，因为主题行为属于预览内容。
- 不向 HTML 注入会改变主题的统一 CSP。
- 禁止 `file://` 导航。
- 本地 token Origin 始终允许。
- 外部 HTTP/HTTPS 链接默认交给系统浏览器或由用户确认。
- 主题运行依赖的 HTTPS CDN 子资源可按产品策略允许。
- 禁止从网页访问 App 私有 URL scheme、Git、Keychain 或 Swift bridge。
- `isInspectable` 只在 Debug 且有明确设置时启用。

现有近似预览会删除脚本并设置 `script-src 'none'`，真实模式不能继续这样做，否则 PaperMod-PE 的主题切换、目录、Fancybox 等行为不真实。

## 13. 能力检测和不支持策略

预览前进行只读扫描，检测：

- `resources.GetRemote`。
- `css.Sass` / `toCSS`。
- PostCSS。
- Babel。
- TailwindCSS。
- AsciiDoctor、Pandoc、rst 等外部 converter。
- `os/exec` 类外部命令需求。
- Hugo Modules 是否需要联网下载。
- 主题最低 Hugo 版本。

结果分级：

```text
supported
requiresNetwork
requiresExtendedHugo
requiresExternalExecutable
requiresNewerHugo
unknown
```

处理原则：

- `supported`：构建。
- `requiresNetwork`：根据用户网络权限构建，并标记离线限制。
- `requiresExtendedHugo`：当前 runtime 不是 Extended 时阻止构建。
- `requiresExternalExecutable`：iOS 不可真实执行时阻止构建。
- `requiresNewerHugo`：显示主题要求和固定版本。
- `unknown`：允许真实 Hugo 尝试，但保留诊断；不得改用近似渲染。

## 14. 缓存策略

### 14.1 目录

```text
Library/Caches/HugoPreview/
└── <repository-id>/
    └── 0.134.3-standard/
        └── <theme-hash>/
            ├── public/
            ├── resources/
            ├── file-cache/
            └── metadata.json
```

### 14.2 缓存生命周期

- 当前仓库当前主题：热缓存。
- 最近使用的第二主题：可热缓存。
- 其余主题：关闭 session，仅保留磁盘资源缓存。
- 收到系统内存警告：关闭非当前 session。
- App Cache 超限：LRU 删除旧主题输出。
- 删除仓库：删除对应 preview cache。
- Hugo runtime 版本变化：使用新 namespace，不复用旧缓存。

### 14.3 缓存正确性优先

如果无法证明依赖追踪完整，宁可重建页面或 session，不得展示陈旧主题结果。UI 应展示“正在重新构建”，不能继续把旧主题页面当成最新结果。

## 15. UI 集成

### 15.1 编辑器模式

建议在 Markdown Preview/Split 中增加明确选择：

```text
快速预览 | Hugo 主题
```

- 快速预览继续使用现有 `nativeMarkdownPreview`。
- Hugo 主题使用新运行时。
- 第一次加载 runtime 时显示构建进度。
- 构建失败显示 Hugo 原始诊断的脱敏版本。

### 15.2 主题控制

真实主题预览控制栏至少包括：

- 主题选择。
- Phone / Tablet / Desktop 宽度。
- 刷新。
- 显示 Hugo `0.134.3`。
- 构建状态。
- 打开构建诊断。

不再手动让用户选择 `layout` 和 `contentType` 作为默认流程。真实 Hugo 应从文章 front matter、内容路径和模板查找规则自行决定。可以在高级调试中显示 Hugo 最终选中的 Page kind、type、layout 和 output format，但不能用 Swift 选择器绕过真实规则。

### 15.3 状态机

```swift
enum HugoPreviewPhase: Equatable {
    case idle
    case openingRuntime
    case indexingSite
    case building
    case ready(URL)
    case failed(HugoPreviewFailure)
}
```

当用户继续输入时：

- 保留当前页面，显示正在更新。
- 新构建成功后替换。
- 旧 generation 完成时丢弃。
- 不闪回旧内容。

### 15.4 iPad

- Split 模式优先左右布局。
- 预览保持主题自己的响应式宽度，不按屏幕无限拉伸。
- Phone/Tablet/Desktop 是 viewport 宽度，不是伪造 User-Agent 的唯一依据。
- 后续可增加真实 User-Agent/size class 验证，但 MVP 不应对 HTML 做设备特定改写。

## 16. 错误与诊断

定义结构化错误：

```swift
enum HugoPreviewFailureKind: String, Codable {
    case runtimeUnavailable
    case versionMismatch
    case repositoryUnavailable
    case invalidConfiguration
    case themeNotFound
    case themeIncompatible
    case externalToolUnavailable
    case networkRequired
    case pageNotFound
    case templateError
    case resourcePipelineError
    case outputMissing
    case cancelled
    case internalRuntimeError
}
```

诊断必须包含：

- 类别。
- 用户可读摘要。
- Hugo 原始错误文本的安全摘要。
- 相关仓库相对路径和行号（如 Hugo 提供）。
- Hugo 版本和主题名。
- 是否可重试。

诊断不得包含：

- 文章完整正文。
- Token、OAuth 请求或 Keychain 数据。
- 仓库外绝对隐私路径（UI 可显示仓库相对路径）。
- 远程认证响应正文。

## 17. 从旧实现迁移

### 阶段 A：并存

- 保留现有原生 Markdown 快速预览。
- 新增真实 Hugo runtime 和独立服务。
- 真实模式不调用 `HugoTemplateCompatibilityService`。
- 新增 feature flag 或 Debug 入口，先在 fixture 和 `hotbitd` 验证。

### 阶段 B：接管 Theme 模式

- `previewStyle == .theme` 时调用真实 runtime。
- `HugoThemeWebPreview` 改为加载本地 HTTP URL，而不是 `loadHTMLString`。
- 删除 Theme 模式对 `HugoThemePreviewService.render` 的调用。
- 保留旧服务测试直到新集成测试稳定。

### 阶段 C：删除近似主题渲染

确认新实现通过验收后删除或缩减：

- `HugoThemePreviewService` 中的近似 render/parser。
- `HugoTemplateCompatibilityService`。
- `HugoThemeSnapshotService` 的弱语义比较。
- 对应“unsupported template expression”占位逻辑。
- 旧近似预览 fixture 和测试。

若 `HugoThemePreviewService` 还有安全路径/MIME 等可复用代码，应迁移到职责明确的新服务后再删除文件。

## 18. 测试方案

### 18.1 Go 包装层单元测试

- 固定版本报告。
- 最小 Hugo 站点构建。
- base template + partial。
- shortcode。
- render hook。
- `resources.Get` + fingerprint。
- `js.Build`。
- overlay 覆盖文章但不修改源文件。
- Segment 只输出目标页面。
- `.Site.RegularPages` 仍包含其他页面。
- theme override。
- 配置错误结构化返回。
- session 关闭后不能继续读取。

### 18.2 Swift 单元测试

- Build Coordinator generation 去重。
- debounce 和取消。
- session key。
- 主题发现和 `min_version` 比较。
- 缓存 LRU。
- 错误映射。
- HTTP path traversal 防护。
- MIME type。
- 内部链接到目标 Page 的映射。
- Git 操作后 session invalidation。

### 18.3 集成 Fixture

创建新的真实 fixture，至少包含：

```text
HugoRealPreviewFixture/
├── hugo.toml
├── content/
│   └── posts/
│       ├── first/index.md
│       └── second/index.md
├── layouts/
├── themes/
│   ├── ThemeA/
│   └── ThemeB/
├── assets/
└── static/
```

Fixture 必须覆盖：

- 当前文章标题和正文。
- 上一篇/下一篇依赖完整站点图。
- 自定义 shortcode。
- 项目 layout 覆盖主题 layout。
- 两个主题切换。
- JS 和 CSS 资源生成。
- 未保存 overlay。

参考输出必须由官方 Hugo `0.134.3` 生成并记录生成方式。不能继续使用 Swift 生成的 HTML 当作“官方参考”。

### 18.4 `hotbitd` 手工/验收测试

`hotbitd` 不应作为 Sync.md 单元测试的外部固定依赖，但应作为开发环境验收项目。

必须检查：

- PaperMod-PE 当前文章页面。
- PaperMod、PaperModX 切换。
- 根 `layouts` 覆盖在严格模式下仍生效。
- 代码块。
- Mermaid。
- 数学公式。
- 图片和本地字体。
- 标签、归档、瞬间页面。
- 上一篇/下一篇。
- dark mode。
- Fancybox/主题 JavaScript。
- draft 未保存内容。
- 内部文章链接懒构建。

### 18.5 源仓库零写入测试

仅检查 `git status` 不够，因为 `public` 已被忽略。测试需要记录并比较：

- 构建前后仓库文件列表。
- `public` 是否存在或 mtime 是否改变。
- `.hugo_build.lock` 是否出现。
- `resources/_gen` 文件 hash/mtime。
- `hugo.yaml` hash。
- Git index/worktree 状态。

验收要求：源仓库没有任何预览产生的写入。

### 18.6 WebView/UI 测试

- 本地 Origin 能加载 HTML、CSS、JS、图片和字体。
- JavaScript 可以执行主题交互。
- 外部导航不能留在 App 内执行危险 scheme。
- Phone 390、Tablet 768、Desktop 1200 宽度。
- 横竖屏和 Split View。
- 非持久化 website data store。
- listener 关闭后旧 URL 不再访问。

## 19. 性能目标

以正确性优先，初始目标建议：

- `hotbitd` 首次打开站点对象图：真机可接受范围内，记录基线，不在没有测量前承诺固定毫秒数。
- 编辑后单篇更新：目标低于 1 秒，理想值 300–600ms。
- UI 主线程不能执行 Hugo 构建或遍历完整主题。
- 连续输入不会排队执行每次中间构建。
- 第二次预览复用 resources/static 缓存。
- 内存警告时可安全回收非当前主题。

必须使用 signpost 或现有 DebugLogger 记录阶段耗时，但不得记录文章内容。

## 20. 安全审查清单

- [ ] Hugo runtime 不接触 GitHub Token 或 Keychain。
- [ ] 预览 listener 仅绑定 loopback。
- [ ] URL 带随机不可预测 token。
- [ ] 所有输出路径防止 `../` 和编码绕过。
- [ ] 不允许 WebView 调用 App 内部 privileged bridge。
- [ ] 外部链接由导航策略处理。
- [ ] 主题构建错误不输出文章正文。
- [ ] 资源大小和响应大小有合理上限。
- [ ] 构建取消不会留下锁或半写入源仓库。
- [ ] 删除 repository 时同步关闭 session/listener/cache。
- [ ] 第三方 Hugo/Go/主题许可证随 App 分发。

## 21. 分阶段开发任务与完成定义

### Phase 0：原生可行性

任务：

- [ ] 固定 Hugo `v0.134.3`。
- [ ] 建立 Go façade。
- [ ] 生成真机和模拟器 XCFramework。
- [ ] Swift 调用版本接口。
- [ ] 构建最小测试站点。

完成定义：满足第 6.4 节全部条件。

### Phase 1：完整站点真实构建

任务：

- [ ] `HugoRuntimeService`。
- [ ] 仓库只读输入。
- [ ] 输出和 resource/cache 重定向。
- [ ] 构建生产环境完整站点。
- [ ] 读取入口 HTML。

完成定义：`hotbitd + PaperMod-PE` 在 iOS Simulator 和真机成功构建，仓库零写入。

### Phase 2：WKWebView 真实加载

任务：

- [ ] loopback HTTP server。
- [ ] pretty URL 和 MIME。
- [ ] WKWebView JavaScript/导航安全策略。
- [ ] 加载 PaperMod-PE CSS、JS、字体和图片。

完成定义：主题交互和视觉与同一 commit 的 Hugo `0.134.3` 桌面构建一致。

### Phase 3：单篇 Segment

任务：

- [ ] 内容路径到 Hugo Page 映射。
- [ ] 动态 Segment。
- [ ] 完整对象图 + 单篇输出。
- [ ] 内部链接懒构建。

完成定义：目标文章的上一篇/下一篇与完整构建一致，未请求页面不必提前输出。

### Phase 4：未保存 Overlay

任务：

- [ ] `pendingContent` 覆盖。
- [ ] debounce/generation/cancel。
- [ ] front matter 变化触发正确失效。

完成定义：未保存内容进入真实主题页面，磁盘文章和 Git 状态不改变。

### Phase 5：多主题

任务：

- [ ] 主题发现。
- [ ] 固定 Hugo 版本兼容检查。
- [ ] 主题临时配置覆盖。
- [ ] session/cache 隔离。
- [ ] UI 主题选择。

完成定义：`hotbitd` 可在 PaperMod-PE、PaperMod、PaperModX 之间切换，严格遵守项目 layouts 覆盖规则，且不修改 `hugo.yaml`。

### Phase 6：替换旧近似 Theme 模式

任务：

- [ ] `FileEditorView` 接通真实 Theme 模式。
- [ ] 保留原生快速预览。
- [ ] 删除近似模板/shortcode 渲染路径。
- [ ] 替换弱语义 snapshot 测试。
- [ ] 完成本地化。

完成定义：产品中不存在把 Swift 近似渲染标记为 Hugo Theme Preview 的路径。

### Phase 7：生产一致性与发布准备

任务：

- [ ] Cloudflare Standard/Extended 确认。
- [ ] 完整生产验证模式。
- [ ] 性能、缓存和内存测试。
- [ ] 第三方许可证。
- [ ] CI 和真机验证记录。

完成定义：通过第 18 节验收，具备清晰的已支持/不支持主题能力说明。

## 22. 构建与 CI

- iOS/XCFramework 构建只能在 macOS/Xcode 环境完成。
- Go runtime 构建脚本必须可重复执行并验证版本。
- 不应在每次普通 Swift build 中在线下载并重编译 Hugo。
- CI 应使用已生成且校验过的 XCFramework，或先执行有缓存的专用 runtime job。
- 是否提交 `HugoRuntime.xcframework` 需要结合仓库体积和现有 `libgit2.xcframework` 策略决定；做决定前先记录产物大小。
- 修改工程配置后运行仓库指南中的 `xcodebuild test`。
- 文档修改本身无需触发 iOS 编译。

## 23. 已知风险与处理

### 风险 1：Hugo 依赖无法直接通过 gomobile

处理：先尝试最小 façade；失败后尝试 `c-archive`。记录具体不兼容依赖，不得隐藏失败。

### 风险 2：Extended Hugo

Extended 可能引入 CGO/LibSass 等额外原生依赖。当前 hotbitd 的 Standard 构建成功，因此第一版不主动承担 Extended。Cloudflare 若实际是 Extended，先比较当前项目是否使用 Extended-only 功能，再决定是否扩大范围。

### 风险 3：外部构建工具

iOS 无法像桌面系统一样任意执行 Node、PostCSS、Tailwind、Pandoc。真实策略是阻止并报告，不是近似渲染。

### 风险 4：第三方主题脚本

真实主题需要 JavaScript，但不应获得 App 权限。使用隔离 WKWebView、非持久化存储、导航控制和无 privileged bridge。

### 风险 5：大仓库和大 static

不复制完整仓库；Hugo 输出和 static 发布结果进入 LRU Cache。后续通过复用输出和资源签名降低重复 IO。

### 风险 6：Hugo 内部 API 不稳定

版本固定 `0.134.3`，所有 Hugo 内部调用封装在 Go façade，不向 Swift 泄漏。未来升级 Hugo 时只迁移 façade 并重新跑完整 fixture。

## 24. 首次开发前仍需确认的事实

这些问题不改变总体方案，但需要在对应阶段确认：

1. Cloudflare 构建日志是 `v0.134.3` 还是 `v0.134.3+extended`。
2. 当前 Cloudflare 完整 build command 和 draft/future/expired 参数。
3. Cloudflare Preview 环境是否与 Production 使用相同 `HUGO_VERSION`。
4. App Store 构建是否接受计划中的 Go runtime 产物和许可证打包方式。
5. `HugoRuntime.xcframework` 的实际体积以及是否提交仓库。

前两项在生产一致性阶段必须解决；不应阻止 Phase 0 的 Standard 可行性验证。

## 25. 最终验收清单

- [ ] App 显示的 runtime 精确为 Hugo `0.134.3`。
- [ ] `hotbitd + PaperMod-PE` 真机成功构建。
- [ ] 不是 Swift 近似模板解析结果。
- [ ] 当前文章使用完整 `.Site` 对象图。
- [ ] 单篇预览只输出目标页面和必要资源。
- [ ] 未保存文章可以进入 Hugo 构建。
- [ ] PaperMod-PE/PaperMod/PaperModX 可切换。
- [ ] 切换主题不修改 `hugo.yaml`。
- [ ] 不复制完整博客仓库。
- [ ] 仓库内不生成或修改 `public`、lock、resources cache。
- [ ] WKWebView 主题 JavaScript 正常运行。
- [ ] 内部链接可按需构建。
- [ ] 外部工具/更高版本主题明确报错。
- [ ] 生产验证结果与 Cloudflare 结构和视觉一致。
- [ ] XCTest、真机验证、`git diff --check` 全部通过。

## 26. 建议新对话的首条消息

可在新对话中直接使用：

> 请完整阅读 `docs/HugoRealThemePreviewImplementationPlan.md` 和仓库 `AGENTS.md`，严格按照文档从 Phase 0 开始实现。不要继续扩展现有 Swift 近似 Hugo 解析器，不要修改博客仓库，也不要跳过 iOS 真机/模拟器原生 Hugo 可行性闸门。先检查当前工作树、现有 Preview 代码和工程依赖，然后给出 Phase 0 的具体执行计划并开始实现；每个阶段完成后按文档完成定义验证。

## 27. 实现时使用的权威资料

- Hugo `v0.134.3` 源码与 Release：<https://github.com/gohugoio/hugo/releases/tag/v0.134.3>
- Hugo Segments：<https://gohugo.io/configuration/segments/>
- Hugo 构建命令和 flags：<https://gohugo.io/commands/hugo/>
- Hugo 目录与 unified file system：<https://gohugo.io/getting-started/directory-structure/>
- Cloudflare Pages Hugo 版本配置：<https://developers.cloudflare.com/pages/framework-guides/deploy-a-hugo-site/>
- Go mobile/gomobile：<https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile>
- PaperMod-PE 上游：<https://github.com/tofuwine/PaperMod-PE>

文档网站默认展示最新版 Hugo 行为。凡是涉及内部 API、配置字段或 Segment 细节，必须以 `v0.134.3` 源码和实际测试为准，不能直接照抄最新版文档后假定完全相同。
