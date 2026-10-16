import Foundation

// MARK: - 正文识别

struct CleanedPage {
    var document: HTMLDocument
    /// 章节标题（优先取正文容器里的 h1，其次解析 <title>）
    var title: String
    /// 书名（从 <title> 的分段里挑非章节、非站点名的那一段）
    var bookName: String?
    /// 净化后的正文
    var text: String
    /// 只做了空白归一、没做噪声行过滤的版本，供「关闭净化」时对照
    var plain: String
}

/// 正文识别：readability 的简化版。
///
/// 老实现是把所有 `<...>` 一律换成空格，等于「整页都是正文」，所以导航条、
/// 站点公告、本书简介、最新章节列表、广告会被一起吞进来。这里改成：
///   1. 用统计量给每个容器打分（正文权重 × (1 − 链接密度) × 关键词加权 × 折行加成）
///   2. **只抽得分最高的那个容器**，不做兄弟合并（合并容易把侧栏的「简介」卷进来）
///   3. 再逐行过滤站点噪声
enum ArticleCleaner {
    /// id/class 命中这些词说明多半是正文容器
    private static let contentHints = [
        "content", "chapter", "article", "read", "txt", "text", "novel",
        "book", "story", "main", "zw", "nr", "show", "booktext", "detail",
        "htmlcontent", "readcontent", "bookcontent"
    ]
    /// 命中这些词说明多半是侧栏 / 广告 / 导航
    private static let noiseHints = [
        "comment", "sidebar", "nav", "menu", "footer", "header", "advert",
        "share", "related", "recommend", "breadcrumb", "pager", "copyright",
        "banner", "login", "toolbar", "search", "rank", "booklist", "hotlist"
    ]
    /// 整行等于这些词 → 丢掉
    private static let exactNoise: Set<String> = [
        "目录", "章节目录", "返回目录", "回目录", "小说目录", "目录列表",
        "上一章", "下一章", "上一页", "下一页", "上一节", "下一节",
        "上一卷", "下一卷", "返回书页", "返回顶部", "返回列表", "加入书签",
        "投推荐票", "推荐本书", "收藏本书", "手机阅读", "字体大小", "护眼模式",
        "背景颜色", "夜间模式", "白天模式", "首页", "书架", "排行榜", "分类",
        "登录", "注册", "搜索", "报错", "章节报错", "点此报错", "展开全部", "收起",
        "全文阅读", "免费阅读", "在线阅读", "最新章节", "全部章节", "作品相关",
        "查看更多", "上一页", "下一页", "回顶部", "章节列表"
    ]
    /// 行内出现这些片段（且整行很短）→ 丢掉
    private static let noiseFragments = [
        "请记住本站", "最快更新", "更新最快", "无弹窗", "手机版", "一秒记住",
        "第一时间更新", "本章未完", "请点击下一页", "内容未完", "章节内容正在加载",
        "如果觉得本站", "加入书签方便阅读", "天才一秒记住", "笔趣阁", "顶点小说",
        "免费小说", "小说阅读网", "最新网址", "备用网址", "请收藏本站", "求收藏",
        "求推荐票", "投推荐票", "本站域名", "更换域名", "请分享给朋友", "记住本站网址",
        "永久免费", "广告位", "内容均来自网络", "版权归作者所有"
    ]

    static func clean(html: String, fallbackTitle: String) -> CleanedPage {
        let doc = HTMLDocument(html: html)
        let stats = doc.statistics()
        let scores = scoreAll(doc: doc, stats: stats)
        let winner = best(doc: doc, scores: scores)

        var raw: String
        if let winner, stats[winner].text >= 150 {
            raw = doc.visibleText(of: winner)
        } else {
            // 兜底：整页可见文本，至少比空白强
            raw = doc.visibleText(of: doc.root)
        }

        let headings = titles(doc: doc, winner: winner, fallback: fallbackTitle)
        let lines = normalize(raw)
        var content = filterNoise(lines, title: headings.chapter ?? "")
        if content.isEmpty { content = lines.joined(separator: "\n") }
        return CleanedPage(document: doc,
                           title: headings.chapter ?? fallbackTitle,
                           bookName: headings.book,
                           text: content,
                           plain: lines.joined(separator: "\n"))
    }

    // MARK: 打分

    private static func scoreAll(doc: HTMLDocument, stats: [HTMLDocument.Stats]) -> [Double] {
        var scores = Array(repeating: 0.0, count: doc.nodes.count)
        for (i, node) in doc.nodes.enumerated() {
            guard node.tag != "#text", node.tag != "#document" else { continue }
            guard !HTMLDocument.droppedTags.contains(node.tag) else { continue }
            let stat = stats[i]
            guard stat.text >= 60 else { continue }
            let density = Double(stat.links) / Double(stat.text)
            guard density <= 0.5 else { continue }

            var score = Double(stat.text) * (1.0 - density)
            let hint = doc.hint(of: i)
            if !hint.isEmpty {
                if contentHints.contains(where: { hint.contains($0) }) { score *= 2.2 }
                if noiseHints.contains(where: { hint.contains($0) }) { score *= 0.35 }
            }
            if node.tag == "article" || node.tag == "main" { score *= 1.4 }
            // br 越多越像小说正文
            score *= 1.0 + min(Double(stat.breaks), 80.0) / 240.0
            // 同分时偏向更深的节点（否则 <body> 会和正文容器打平，然后被它抢走）
            score *= 1.0 + Double(node.depth) * 0.01
            scores[i] = score
        }
        return scores
    }

    private static func best(doc: HTMLDocument, scores: [Double]) -> Int? {
        var winner: Int?
        var bestScore = 0.0
        for i in scores.indices where scores[i] > bestScore {
            winner = i
            bestScore = scores[i]
        }
        return winner
    }

    // MARK: 标题

    /// 从 `<title>` 里拆出「章节名」和「书名」。
    /// 中文小说站的 title 基本是 `章节名_书名_站点名` 或 `书名 - 最新章节 - 站点`。
    private static func titles(doc: HTMLDocument, winner: Int?, fallback: String) -> (chapter: String?, book: String?) {
        if let winner {
            let heads = doc.descendantIndices(of: winner, tag: "h1")
            if let first = heads.first {
                let text = doc.inlineText(of: first)
                if text.count >= 2, text.count <= 60 { return (text, nil) }
            }
        }
        for i in doc.elementIndices(tag: "title") {
            let raw = doc.inlineText(of: i)
            guard !raw.isEmpty else { continue }
            let segments = titleSegments(raw)
            guard !segments.isEmpty else { continue }
            var chapter = segments.first(where: { ChapterIndex.isChapterTitle($0) })
            if chapter == nil, segments.count == 1, segments[0].count <= 60 { chapter = segments[0] }
            var book: String?
            for segment in segments where segment != chapter {
                guard segment.count >= 2, segment.count <= 40 else { continue }
                if looksLikeSiteName(segment) { continue }
                if let existing = book, existing.count >= segment.count { continue }
                book = segment
            }
            if chapter != nil || book != nil { return (chapter ?? fallback, book) }
        }
        return (fallback, nil)
    }

    private static func titleSegments(_ raw: String) -> [String] {
        var out: [String] = []
        for chunk in raw.components(separatedBy: " - ") {
            for piece in chunk.components(separatedBy: CharacterSet(charactersIn: "_|·－｜")) {
                let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { out.append(text) }
            }
        }
        return out
    }

    private static func looksLikeSiteName(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = ["小说网", "书屋", "文学", "阅读网", "读书", "书吧", "书院", "网",
                       "首页", "最新章节", "免费", "txt", "www", ".com", ".net", ".cc",
                       ".org", "更新", "首发", "手打", "站"]
        if text.count <= 3 { return true }
        return markers.contains(where: { lowered.contains($0) })
    }

    // MARK: 行归一与噪声过滤

    private static func normalize(_ raw: String) -> [String] {
        var out: [String] = []
        var previous = ""
        let pieces = raw.split(separator: "\n", omittingEmptySubsequences: false)
        for piece in pieces {
            var line = piece.replacingOccurrences(of: "\u{00A0}", with: " ")
            line = line.replacingOccurrences(of: "[ \t\u{3000}]{2,}", with: " ", options: .regularExpression)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line == previous { continue }
            out.append(line)
            previous = line
        }
        return out
    }

    private static func filterNoise(_ lines: [String], title: String) -> String {
        var out: [String] = []
        for (index, line) in lines.enumerated() {
            // 正文第一行常常是重复的章节标题——界面已经单独渲染标题了
            if index == 0, !title.isEmpty, title.count >= 4,
               line == title || (line.count <= title.count + 8 && line.contains(title)) {
                continue
            }
            if isNoiseLine(line) { continue }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    static func isNoiseLine(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return true }
        if exactNoise.contains(line) { return true }
        if line.count <= 30, noiseFragments.contains(where: { line.contains($0) }) { return true }
        let lowered = line.lowercased()
        if line.count <= 80, !line.contains("。"),
           lowered.contains("http://") || lowered.contains("https://") || lowered.contains("www.") {
            return true
        }
        if line.count <= 20, line.hasPrefix("简介") || line.hasPrefix("内容简介") || line.hasPrefix("本书简介") {
            return true
        }
        if line.count <= 24, line.hasSuffix("简介") || line.hasSuffix("简介：") || line.hasSuffix("简介:") {
            return true
        }
        return false
    }
}

// MARK: - 章节目录 / 翻页

/// 网页连载的目录项
struct WebChapter: Codable, Hashable, Identifiable {
    var title: String
    var url: String
    var id: String { url }
}

enum ChapterIndex {
    struct Navigation {
        var previous: String?
        var next: String?
        var toc: String?
    }

    private static let navWords: Set<String> = [
        "目录", "章节目录", "返回目录", "回目录", "上一章", "下一章", "上一页", "下一页",
        "上一节", "下一节", "首页", "书架", "排行", "排行榜", "分类", "登录", "注册",
        "全部章节", "作品相关", "最新章节", "章节目录列表"
    ]

    /// 章节标题的样子：第123章 / 第 123 节 / 楔子 / 序章 / 番外 / Chapter 12 …
    static let chapterPattern =
        #"^(?:正文|vip|VIP|作品相关)?\s*(?:第\s*[0-9零一二三四五六七八九十百千万两]{1,9}\s*[章節节回卷集话話篇]|楔子|序章|序言|前言|引子|尾声|终章|结局|番外|后记|外传|Chapter\s*\d+)"#

    // MARK: URL

    static func effectiveBase(_ doc: HTMLDocument, _ pageURL: URL) -> URL {
        guard let raw = doc.baseHref, let resolved = URL(string: raw, relativeTo: pageURL) else {
            return pageURL
        }
        return resolved.absoluteURL
    }

    static func resolve(_ href: String, base: URL) -> String? {
        let raw = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let lowered = raw.lowercased()
        if lowered.hasPrefix("javascript:") || lowered.hasPrefix("#")
            || lowered.hasPrefix("mailto:") || lowered.hasPrefix("tel:") {
            return nil
        }
        guard let url = URL(string: raw, relativeTo: base) else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteURL.absoluteString
    }

    /// 同一页的不同写法（末尾斜杠、http/https 之外）比对用。
    static func samePage(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let ua = URL(string: a), let ub = URL(string: b) else { return false }
        guard ua.host?.lowercased() == ub.host?.lowercased() else { return false }
        var pa = ua.path
        var pb = ub.path
        while pa.hasSuffix("/") { pa.removeLast() }
        while pb.hasSuffix("/") { pb.removeLast() }
        return pa == pb
    }

    // MARK: 上一章 / 下一章 / 目录

    static func navigation(in doc: HTMLDocument, pageURL: URL) -> Navigation {
        let base = effectiveBase(doc, pageURL)
        var nav = Navigation()
        for anchor in doc.elementIndices(tag: "a") {
            guard let href = doc.nodes[anchor].attrs["href"],
                  let url = resolve(href, base) else { continue }
            let text = doc.inlineText(of: anchor).replacingOccurrences(of: " ", with: "")
            guard text.count <= 12 else { continue }
            if nav.next == nil, matchesNext(text) { nav.next = url; continue }
            if nav.previous == nil, matchesPrevious(text) { nav.previous = url; continue }
            if nav.toc == nil, matchesTOC(text) { nav.toc = url }
        }
        if let next = nav.next, samePage(next, pageURL.absoluteString) { nav.next = nil }
        if let previous = nav.previous, samePage(previous, pageURL.absoluteString) { nav.previous = nil }
        return nav
    }

    private static func matchesNext(_ text: String) -> Bool {
        if text.count > 12 { return false }
        for token in ["下一章", "下章", "下一节", "下一回", "后一章", "章节向后"] where text.contains(token) {
            return true
        }
        // 很多站点一章一页，按钮写的是「下一页」
        if text.contains("下一页") || text.contains("下页") { return true }
        return text.lowercased() == "next"
    }

    private static func matchesPrevious(_ text: String) -> Bool {
        if text.count > 12 { return false }
        for token in ["上一章", "上章", "上一节", "上一回", "前一章", "章节向前"] where text.contains(token) {
            return true
        }
        if text.contains("上一页") || text.contains("上页") { return true }
        return text.lowercased() == "prev" || text.lowercased() == "previous"
    }

    private static func matchesTOC(_ text: String) -> Bool {
        for token in ["目录", "章节列表", "返回书页", "章节目录", "全部章节"] where text.contains(token) {
            return true
        }
        let lowered = text.lowercased()
        return lowered == "index" || lowered == "catalog" || lowered == "list"
    }

    // MARK: 目录抓取

    static func isChapterTitle(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= 40 else { return false }
        guard !navWords.contains(text) else { return false }
        if text.range(of: chapterPattern, options: .regularExpression) != nil { return true }
        if text.range(of: #"^[0-9]{1,4}\s*[、.．,，:：]"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// 抓目录。优先 `<select>` 下拉（最完整、天然有序），否则按父节点聚类章节链接。
    static func chapters(in doc: HTMLDocument, pageURL: URL) -> [WebChapter] {
        let base = effectiveBase(doc, pageURL)

        var selectBest: [WebChapter] = []
        for select in doc.elementIndices(tag: "select") {
            var list: [WebChapter] = []
            for option in doc.descendantIndices(of: select, tag: "option") {
                guard let value = doc.nodes[option].attrs["value"],
                      let url = resolve(value, base) else { continue }
                let label = doc.inlineText(of: option)
                let title = label.isEmpty ? "第 \(list.count + 1) 节" : label
                list.append(WebChapter(title: title, url: url))
            }
            if list.count > selectBest.count { selectBest = list }
        }
        if selectBest.count >= 5 { return selectBest }

        // 章节样子且 URL 可解析的链接
        var collected: [(node: Int, parent: Int, item: WebChapter)] = []
        var seen = Set<String>()
        for anchor in doc.elementIndices(tag: "a") {
            guard let href = doc.nodes[anchor].attrs["href"],
                  let url = resolve(href, base) else { continue }
            guard !seen.contains(url) else { continue }
            let title = doc.inlineText(of: anchor)
            guard isChapterTitle(title) else { continue }
            seen.insert(url)
            collected.append((anchor, doc.nodes[anchor].parent, WebChapter(title: title, url: url)))
        }
        guard collected.count >= 5 else { return selectBest }

        var groups: [Int: [Int]] = [:]
        for (position, entry) in collected.enumerated() {
            groups[entry.parent, default: []].append(position)
        }
        guard let anchorGroup = groups.max(by: { $0.value.count < $1.value.count }),
              anchorGroup.value.count >= 4 else {
            return selectBest
        }
        // 分卷站点会把每卷放在各自的 <ul> 里，所以同一祖父下的兄弟分组也合并进来
        let ancestor = doc.nodes[anchorGroup.key].parent
        var positions: [Int] = []
        for (parent, list) in groups {
            if parent == anchorGroup.key {
                positions.append(contentsOf: list)
            } else if ancestor >= 0, doc.nodes[parent].parent == ancestor, list.count >= 3 {
                positions.append(contentsOf: list)
            }
        }
        positions.sort()
        let list = positions.map { collected[$0].item }
        return list.count >= 5 ? list : selectBest
    }
}
