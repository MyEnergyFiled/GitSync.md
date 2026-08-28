# Hugo Theme Preview Compatibility

HugoInk 的 **Hugo Theme** 模式使用内嵌的 Hugo `0.134.3 Standard` 引擎，不是
Swift 模板或 Markdown 近似渲染器。Swift 的原生解析器只用于单独的
**Quick Preview** 模式。

## 已支持的真实路径

- 通过 Go façade 调用 Hugo 对象图、模板、Markdown、shortcode、页面集合和 Hugo Pipes
- 从只读仓库输入构建；未保存文章通过 overlay 注入
- 输出、资源和缓存写入仓库外的 disposable workspace
- 单篇 editor segment、pretty URL、内部链接按需构建
- loopback HTTP 输出服务加载 HTML、CSS、JavaScript、字体、图片和媒体
- PaperMod-PE 等标准 Hugo 主题的主题布局和项目布局覆盖
- 主题发现、Hugo 版本检查、外部构建工具能力检查和主题隔离缓存

## 明确限制

- 当前固定为 Hugo `0.134.3 Standard`；需要更高版本或 Extended 的主题会失败并显示原因
- iOS 不执行 Node、PostCSS、Tailwind、Pandoc、Asciidoctor 或其他外部可执行工具
- 远程资源、Hugo modules 和需要网络的主题能力会被标记或阻止，不会静默近似渲染
- 生产环境与 Cloudflare 的 Hugo 版本、参数和主题 commit 必须一致，最终视觉一致性仍需真机/生产站点验收

## 验证资产

`SyncMDTests/HugoRealPreviewFixture` 是真实 Hugo runtime fixture，覆盖主题布局、项目
layout 覆盖、shortcode、资源管线、JavaScript 资源、单篇 segment 和未保存 overlay。
Go runtime 单元测试在 `Hugo Runtime` workflow 中执行；iOS simulator 编译/测试和真机
设备架构 XCFramework 构建也由同一 workflow 验证。
