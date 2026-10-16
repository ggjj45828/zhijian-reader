import Foundation

// MARK: - 搜索源

/// 一次搜索要跨十几个源。这里的四条设计原则：
///   ① **并发发起、各自独立超时** —— 海外源在当前网络下经常不可达，但不能拖住国内源；
///   ② **失败静默** —— 只以一行小字回报「Google：连接超时」，绝不进结果列表；
///   ③ **先出结果、后验正文** —— 引擎命中立刻上屏，正文校验完一条插一条，
///      用户三秒内就能看到东西，而不是干等三十秒；
///   ④ **取结果不依赖 DOM 结构** —— 只认「站外 http 链接 + 锚文本 + 邻域文本」，
///      因为每个引擎的 HTML 结构都不一样，而且一变就全废。
enum SearchService {

    struct Source: Identifiable, Hashable, Sendable {
        enum Kind: String, Sendable {
            /// 通用搜索结果页：抓整页的**站外**链接（会剔掉引擎自己的域）
            case links
            /// 书站目录/搜索页：目标就是站内的条目页，所以**不过滤自身域**，
            /// 改用「路径至少两段」来滤掉顶层导航
            case catalogue
            /// 维基文库 action=query&list=search（官方 JSON）
            case wikisource
            /// Internet Archive advancedsearch（官方 JSON）
            case archive
        }

        let title: String
        let base: String
        let key: String
        /// 判定「这条链接指向搜索引擎自己」用的域名根
        let host: String
        let kind: Kind
        /// 海外源：在当前网络下最容易超时，界面上单独归组
        let overseas: Bool

        var id: String { title }

        init(_ title: String, _ base: String, _ key: String, _ host: String,
             kind: Kind = .links, overseas: Bool = false) {
            self.title = title
            self.base = base
            self.key = key
            self.host = host
            self.kind = kind
            self.overseas = overseas
        }
    }

    /// 全部源。国内外通用引擎 + 开放书源，一共 27 个。
    static let allSources: [Source] = [
        Source("百度", "https://www.baidu.com/s", "wd", "baidu.com"),
        Source("必应", "https://cn.bing.com/search", "q", "bing.com"),
        Source("搜狗", "https://www.sogou.com/web", "query", "sogou.com"),
        Source("360", "https://www.so.com/s", "q", "so.com"),
        Source("神马", "https://m.sm.cn/s", "q", "sm.cn"),
        Source("夸克", "https://quark.sm.cn/s", "q", "quark.sm.cn"),
        Source("无追", "https://www.wuzhuiso.com/s", "q", "wuzhuiso.com"),
        Source("头条", "https://so.toutiao.com/search", "keyword", "toutiao.com"),
        Source("中搜", "https://www.zhongsou.com/search", "w", "zhongsou.com"),
        Source("中国搜索", "https://www.chinaso.com/search/pagesearch.htm", "q", "chinaso.com"),
        Source("搜狗微信", "https://weixin.sogou.com/weixin", "query", "weixin.sogou.com"),

        Source("Google", "https://www.google.com/search", "q", "google.com", overseas: true),
        Source("必应国际", "https://www.bing.com/search", "q", "bing.com", overseas: true),
        Source("DuckDuckGo", "https://html.duckduckgo.com/html/", "q", "duckduckgo.com", overseas: true),
        Source("Brave", "https://search.brave.com/search", "q", "brave.com", overseas: true),
        Source("Startpage", "https://www.startpage.com/sp/search", "query", "startpage.com", overseas: true),
        Source("Mojeek", "https://www.mojeek.com/search", "q", "mojeek.com", overseas: true),
        Source("Marginalia", "https://search.marginalia.nu/search", "query", "marginalia.nu", overseas: true),
        Source("Yahoo", "https://search.yahoo.com/search", "p", "yahoo.com", overseas: true),
        Source("Ecosia", "https://www.ecosia.org/search", "q", "ecosia.org", overseas: true),
        Source("Qwant", "https://lite.qwant.com/", "q", "qwant.com", overseas: true),
        Source("SearXNG", "https://searx.be/search", "q", "searx.be", overseas: true),
        Source("Yandex", "https://yandex.com/search/", "text", "yandex.com", overseas: true),

        Source("维基文库", "https://zh.wikisource.org/w/api.php", "srsearch", "wikisource.org",
               kind: .wikisource, overseas: true),
        Source("古腾堡", "https://www.gutenberg.org/ebooks/search/", "query", "gutenberg.org",
               kind: .catalogue, overseas: true),
        Source("中国哲学书", "https://ctext.org/searchbooks.pl", "search", "ctext.org",
               kind: .catalogue, overseas: true),
        Source("Internet Archive", "https://archive.org/advancedsearch.php", "q", "archive.org",
               kind: .archive, overseas: true),
    ]

    static let domesticCount = allSources.filter { !$0.overseas }.count

    /// 按用户勾选的标题挑出要跑的源。一个都没勾时回退成「全部」，
    /// 否则搜索会变成什么都不做，用户只会觉得「搜不出来了」。
    static func sources(for titles: [String]) -> [Source] {
        let wanted = Set(titles)
        let picked = allSources.filter { wanted.contains($0.title) }
        return picked.isEmpty ? allSources : picked
    }

    // MARK: - 事件

    enum Event: Sendable {
        /// 正在做哪一阶段
        case stage(String)
        /// 某个源回来了多少条，或者为什么失败
        case source(title: String, count: Int, error: String?)
        /// 一条**正文校验通过**的候选，可以立刻上屏
        case found(WebCandidate)
        /// 正文校验进度
        case progress(done: Int, total: Int, kept: Int)
        /// 全部结束
        case done(scanned: Int, kept: Int, failed: Int)
    }

    // MARK: - 入口

    /// 跑一次搜索。返回的是**流式事件**：引擎命中先出、正文校验边验边出。
    static func search(_ rawQuery: String,
                       sources: [Source],
                       verifyBody: Bool,
                       maxCandidates: Int = 36) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                await run(rawQuery, sources: sources, verifyBody: verifyBody,
                          maxCandidates: maxCandidates) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(_ rawQuery: String,
                            sources: [Source],
                            verifyBody: Bool,
                            maxCandidates: Int,
                            emit: @escaping (Event) -> Void) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            emit(.done(scanned: 0, kept: 0, failed: 0))
            return
        }
        let fullQuery = query + " 小说 在线阅读 章节"

        // ---- 第一阶段：并发问所有源 ----
        emit(.stage("正在向 \(sources.count) 个搜索源提问…"))
        var harvested: [WebCandidate] = []
        var failed = 0

        await withTaskGroup(of: (String, [WebCandidate], String?).self) { group in
            for source in sources {
                group.addTask { await fetch(source, query: fullQuery) }
            }
            for await (title, list, error) in group {
                if let error {
                    failed += 1
                    emit(.source(title: title, count: 0, error: error))
                } else {
                    emit(.source(title: title, count: list.count, error: nil))
                    harvested.append(contentsOf: list)
                }
            }
        }

        // ---- 去重 + 交错排序 ----
        var seen = Set<String>()
        var unique: [WebCandidate] = []
        for item in harvested {
            // 键里**必须带 query**：百度的结果全走 `www.baidu.com/link?url=…`，
            // 只按 host+path 去重会把一整页结果压成一条。
            var key = (item.url.host?.lowercased() ?? "") + item.url.path
            if let query = item.url.query, !query.isEmpty { key += "?" + query }
            if seen.insert(key).inserted { unique.append(item) }
        }
        let ordered = interleave(unique, sources: sources)

        // ---- 第二阶段：正文校验（或者直接全部上屏）----
        if !verifyBody {
            let cap = min(ordered.count, 120)
            for index in 0..<cap {
                emit(.found(ordered[index]))
            }
            emit(.done(scanned: ordered.count, kept: cap, failed: failed))
            return
        }

        let total = min(ordered.count, maxCandidates)
        if total == 0 {
            emit(.stage("所有源都没返回可用链接"))
            emit(.done(scanned: 0, kept: 0, failed: failed))
            return
        }
        emit(.stage("正在逐个确认有没有正文…"))

        var done = 0
        var kept = 0
        var cursor = 0
        // 并发 6 路：更宽会同时压太多站点（也更容易被限频），
        // 更窄则 36 个页面要等太久。
        while cursor < total {
            let end = min(cursor + 6, total)
            var batch: [WebCandidate] = []
            for index in cursor..<end {
                batch.append(ordered[index])
            }
            cursor = end
            await withTaskGroup(of: WebCandidate?.self) { group in
                for item in batch {
                    group.addTask { await verify(item) }
                }
                for await result in group {
                    done += 1
                    if let result {
                        kept += 1
                        emit(.found(result))
                    }
                    emit(.progress(done: done, total: total, kept: kept))
                }
            }
        }
        emit(.done(scanned: total, kept: kept, failed: failed))
    }

    /// 按源轮询交错：不这么排的话，某个源一次给 12 条会把别的源全挤到 36 条窗口外面。
    private static func interleave(_ list: [WebCandidate], sources: [Source]) -> [WebCandidate] {
        var buckets: [String: [WebCandidate]] = [:]
        for item in list {
            buckets[item.engine, default: []].append(item)
        }
        var out: [WebCandidate] = []
        var round = 0
        var progressed = true
        while progressed && out.count < list.count {
            progressed = false
            for source in sources {
                let bucket = buckets[source.title] ?? []
                if round < bucket.count {
                    out.append(bucket[round])
                    progressed = true
                }
            }
            round += 1
        }
        // 万一有 source 名字对不上（理论上不会），把剩下的补上
        if out.count < list.count {
            let present = Set(out.map { $0.url.absoluteString })
            for item in list where !present.contains(item.url.absoluteString) {
                out.append(item)
            }
        }
        return out
    }

    // MARK: - 正文校验

    /// 判断这一页到底有没有正文。没有就返回 nil，这条候选**不会出现在列表里**。
    ///
    /// 阈值 500（约 250 个汉字）：小说章节动辄两三千字，而首页、目录页、404 页、
    /// 需要登录的提示页都远低于这个数。低于阈值的一律当「没有正文」。
    private static let minimumBodyWeight = 500

    private static func verify(_ candidate: WebCandidate) async -> WebCandidate? {
        guard let url = URL(string: candidate.url.absoluteString) else { return nil }
        guard let page = try? await ArticleService.fetchHTML(url, timeout: 10) else { return nil }
        let cleaned = ArticleCleaner.clean(html: page.html, fallbackTitle: candidate.title)
        let weight = HTMLDocument.textWeight(cleaned.text)
        guard weight >= minimumBodyWeight else { return nil }

        var out = candidate
        // 跳转链接（百度的 /link?url=、360 的 /link?m=）在这里已经跟到最终地址了，
        // 用真实地址覆盖掉，列表上才不会显示成一串 baidu.com/link
        out.url = page.url
        if cleaned.title.count >= 2, cleaned.title.count <= 70 {
            out.title = cleaned.title
        }
        out.site = page.url.host ?? candidate.url.host ?? ""
        out.bodyWeight = weight
        let flat = cleaned.text.replacingOccurrences(of: "\n", with: " ")
        out.snippet = String(flat.prefix(110))
        return out
    }

    // MARK: - 取一个源

    private static func fetch(_ source: Source, query: String) async -> (String, [WebCandidate], String?) {
        do {
            switch source.kind {
            case .links, .catalogue:
                let page = try await fetchHTMLSource(source, query: query)
                let list = links(in: page.html, pageURL: page.url, source: source, limit: 12)
                return (source.title, list, nil)
            case .wikisource:
                let data = try await fetchData(source, query: query,
                                               extra: ["action": "query", "list": "search",
                                                       "format": "json", "srlimit": "12", "srprop": "snippet"])
                return (source.title, wikisourceCandidates(data, source: source), nil)
            case .archive:
                let data = try await fetchData(source, query: query,
                                               extra: ["fl[]": "identifier", "fl[]": "title",
                                                       "rows": "12", "output": "json"])
                return (source.title, archiveCandidates(data, source: source), nil)
            }
        } catch {
            return (source.title, [], shortError(error))
        }
    }

    private static func fetchHTMLSource(_ source: Source, query: String) async throws -> (String, URL) {
        guard var components = URLComponents(string: source.base) else { throw SearchIssue.badResponse }
        components.queryItems = [URLQueryItem(name: source.key, value: query)]
        guard let url = components.url else { throw SearchIssue.badResponse }
        // 搜索页一律走桌面 UA —— 移动 UA 下百度会跳验证码、搜狗只剩两条外链
        return try await ArticleService.fetchHTML(url, timeout: 12, desktop: true)
    }

    private static func fetchData(_ source: Source, query: String,
                                 extra: [String: String]) async throws -> Data {
        var components = URLComponents(string: source.base)
        var items = (components?.queryItems ?? [])
        items.append(URLQueryItem(name: source.key, value: query))
        for (key, value) in extra {
            items.append(URLQueryItem(name: key, value: value))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw SearchIssue.badResponse }
        return try await ArticleService.fetchData(url)
    }

    private static func shortError(_ error: Error) -> String {
        var text = error.localizedDescription
        if let localized = error as? LocalizedError, let described = localized.errorDescription {
            text = described
        }
        if text.contains("timed out") || text.contains("超时") { return "连接超时" }
        if text.contains("offline") || text.contains("internet connection") { return "网络不可达" }
        if text.contains("有效页面") { return "没有返回有效页面" }
        if text.contains("certificate") || text.contains("TLS") { return "证书不受信" }
        return String(text.prefix(24))
    }

    // MARK: - 从搜索结果页抽链接

    /// 不去猜每个引擎的 DOM：只看**锚点是站外 http 链接、锚文本像标题、锚点周围有文字**。
    private static let blockedHosts: [String] = [
        // CDN / 静态资源 / 统计
        "bdstatic.com", "bdimg.com", "bcebos.com", "360tres.com", "360kuai.com",
        "searchpstatp.com", "byteimg.com", "ibytedtos.com", "gstatic.com",
        "googleusercontent.com", "ytimg.com", "doubleclick.net", "googleadservices.com",
        "r.bing.com", "bing.net", "msn.cn", "go.microsoft.com", "microsoft.com",
        "w3.org", "schema.org", "creativecommons.org", "gplv3.org", "apple.com",
        "mozilla.org", "gravatar.com", "gmpg.org", "bingj.com",
    ]

    private static let blockedPathSuffixes: [String] = [
        ".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg", ".ico", ".bmp",
        ".css", ".js", ".json", ".xml", ".rss", ".pdf", ".zip", ".apk", ".ico",
    ]

    private static let navWords: Set<String> = [
        "登录", "注册", "首页", "更多", "设置", "下载", "反馈", "帮助", "关于",
        "上一页", "下一页", "展开", "收起", "广告", "图片", "视频", "地图",
        "翻译", "词典", "百科", "贴吧", "知道", "文库", "音乐", "购物",
        "登录/注册", "意见反馈", "使用帮助", "隐私政策", "用户协议",
        "Sign in", "Log in", "Settings", "About", "Help", "Privacy", "Terms",
        "Images", "Videos", "Maps", "News", "Next", "Previous",
    ]

    private static func links(in html: String, pageURL: URL, source: Source, limit: Int) -> [WebCandidate] {
        let doc = HTMLDocument(html: html)
        var seen = Set<String>()
        var out: [WebCandidate] = []
        for anchor in doc.elementIndices(tag: "a") {
            if out.count >= limit { break }
            let node = doc.nodes[anchor]
            guard let href = node.attrs["href"] else { continue }
            let raw = href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, !raw.hasPrefix("#"), !raw.hasPrefix("javascript:") else { continue }
            guard let resolved = URL(string: raw, relativeTo: pageURL)?.absoluteURL else { continue }
            guard let scheme = resolved.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            guard let host = resolved.host?.lowercased(), !host.isEmpty else { continue }

            let isSelf = host == source.host || host.hasSuffix("." + source.host)
            let isRedirect = resolved.path.lowercased().contains("/link")
                || resolved.path.lowercased().contains("/jump")
            // 搜索引擎自己的域：只放行 /link? 这类跳转（后面会跟到真实地址）
            if isSelf && (source.kind == .links) && !isRedirect { continue }
            // 书站目录页：目标就在站内，但要滤掉顶层导航（路径至少两段）
            if isSelf && (source.kind == .catalogue) {
                let depth = resolved.path.split(separator: "/").count
                if depth < 2 { continue }
            }
            if blockedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { continue }

            let path = resolved.path.lowercased()
            if blockedPathSuffixes.contains(where: { path.hasSuffix($0) }) { continue }
            if path.contains("/img") || path.contains("/image") || path.contains("/static/") { continue }

            let title = doc.inlineText(of: anchor)
            guard title.count >= 2, title.count <= 70 else { continue }
            if navWords.contains(title) { continue }
            if title.allSatisfy({ $0.isNumber || $0.isPunctuation }) { continue }

            var key = host + path
            if let query = resolved.query, isRedirect { key += "?" + query }
            guard seen.insert(key).inserted else { continue }

            let snippet = neighbourhood(doc, anchor)
            out.append(WebCandidate(title: title, url: resolved, snippet: snippet, engine: source.title))
        }
        return out
    }

    /// 找到锚点附近「有点像摘要」的整块文字：向上爬最多 4 层，取第一块够长的。
    private static func neighbourhood(_ doc: HTMLDocument, _ anchor: Int) -> String {
        var cur = doc.nodes[anchor].parent
        var hops = 0
        while cur > 0, hops < 4 {
            let text = doc.inlineText(of: cur)
            if text.count >= 30 {
                return String(text.prefix(170))
            }
            cur = doc.nodes[cur].parent
            hops += 1
        }
        return ""
    }

    // MARK: - 开放书源

    private static func wikisourceCandidates(_ data: Data, source: Source) -> [WebCandidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let list = query["search"] as? [[String: Any]] else { return [] }
        var out: [WebCandidate] = []
        for item in list {
            guard let title = item["title"] as? String, !title.isEmpty else { continue }
            guard let encoded = title.addingPercentEncoding(withAllowedCharacters: wikiPathAllowed),
                  let url = URL(string: "https://zh.wikisource.org/wiki/" + encoded) else { continue }
            let snippet = stripTags((item["snippet"] as? String) ?? "")
            out.append(WebCandidate(title: title, url: url, snippet: snippet, engine: source.title))
        }
        return out
    }

    private static func archiveCandidates(_ data: Data, source: Source) -> [WebCandidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let docs = response["docs"] as? [[String: Any]] else { return [] }
        var out: [WebCandidate] = []
        for doc in docs {
            guard let identifier = doc["identifier"] as? String, !identifier.isEmpty else { continue }
            guard let url = URL(string: "https://archive.org/details/" + identifier) else { continue }
            let raw = doc["title"]
            let title = (raw as? String) ?? identifier
            out.append(WebCandidate(title: title, url: url, snippet: identifier, engine: source.title))
        }
        return out
    }

    /// 维基标题里可能有 `/`（子页面），所以只在真正不安全的字符上转义。
    private static var wikiPathAllowed: CharacterSet {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~!$&'()*+,;=:@/")
        return set
    }

    /// 维基的摘要里带 `<span class="searchmatch">` 高亮标签，剥掉。
    private static func stripTags(_ raw: String) -> String {
        var out = ""
        var inside = false
        for ch in raw {
            if ch == "<" { inside = true; continue }
            if ch == ">" { inside = false; continue }
            if !inside { out.append(ch) }
        }
        return HTMLDocument.decodeEntities(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 取页失败时统一抛这个。`ArticleService` 的 `fetchHTML` / `fetchData` 也用它，
/// 所以别删 —— 重写本文件时漏掉过一次，CI 直接报 `cannot find 'SearchIssue' in scope`。
enum SearchIssue: LocalizedError {
    case badResponse
    var errorDescription: String? { "搜索网站没有返回有效页面" }
}
