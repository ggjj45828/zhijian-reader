# 纸间 · 原生 iPhone 版

这是独立的 SwiftUI iOS 应用源码，不是网页 WebView 套壳。搜索通过 iPhone 当前网络并行请求百度和必应；书籍、主题、阅读进度、书签、笔记和阅读分钟数保存在 iPhone。NAS 地址留空时仍可搜索、导入和阅读；填写 NAS 阅读器地址后，可将本机书库与 NAS 现有书库合并上传。

## 已实现

- 原生书架、书名/作者搜索、书架继续阅读、滑动删除
- TXT、Markdown、HTML、PDF、EPUB、FB2、DOCX、RTF 导入和本机保存
- 手机网络并行搜索网页；打开候选后在应用内提取正文，提取失败可在应用内打开原网页
- 分页阅读、章节标题导航、字体大小、四种纯色主题
- 阅读进度、书签、读书笔记、每日阅读目标和最近七天统计
- 可选 NAS 合并上传，不依赖 NAS 做网页搜索或网页正文读取

## 构建

需要 macOS 与 Xcode 15 或更新版本。用 Xcode 打开 `ZhijianReader.xcodeproj`，选择 `ZhijianReader` target，在 Signing & Capabilities 中选择自己的 Team，再运行到 iPhone。EPUB/DOCX 使用 ZIPFoundation Swift Package，首次在 Xcode 打开项目时需要联网解析依赖。

也可以走云端构建：`.github/workflows/build-ios.yml` 会在 `macos-15` 上先 `-resolvePackageDependencies` 拉 ZIPFoundation，再以 `CODE_SIGNING_ALLOWED=NO` 编译出未签名 IPA，产物在 workflow run 的 artifact 里（名 `zhijian-unsigned-ipa`）。未签名 IPA 需要用 Sideloadly 之类工具以你自己的 Apple ID 重签后才能装到 iPhone。


## 当前边界

- 搜索网站会限制频率，网络供应商也可能屏蔽个别搜索源；搜索响应不保证固定有结果。
- 部分小说站需要登录、付费或 JavaScript 才显示正文。应用不会绕过这些限制；此时可在应用内网页视图阅读。
- 支持 TXT、Markdown、HTML、PDF、EPUB、FB2、DOCX 和 RTF。EPUB/DOCX 使用 ZIPFoundation Swift Package；首次在 Xcode 打开项目时需要联网解析依赖。MOBI/AZW3 与带 DRM 的电子书暂不支持。云端账号认证和双向冲突同步尚未实现。
- NAS 的 `/api/books` 当前无账号认证。只在私有网络或可信的 HTTPS 远程访问入口使用，不要将服务直接公开到公网。
