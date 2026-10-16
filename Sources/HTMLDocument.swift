import Foundation

/// 极简 HTML 解析器 + 可见文本抽取。
///
/// 只为「正文提取」服务，所以刻意不做完整 HTML5 语义：不补全隐式 tbody、
/// 不实现 CSS 选择器、不解析命名空间，未闭合标签靠栈容错。
///
/// 节点存成**扁平数组 + 下标父子关系**（而不是递归 enum）：一来省内存，
/// 二来因为子节点下标一定大于父节点，倒序扫一遍就能自底向上算出每个容器
/// 子树内的「正文权重 / 链接权重 / 折行数」，正文识别就靠这三个量。
final class HTMLDocument {
    struct Node {
        var tag: String = "#text"
        var attrs: [String: String] = [:]
        var parent: Int = -1
        var children: [Int] = []
        var text: String = ""
        var depth: Int = 0
    }

    struct Stats {
        /// 正文权重（中日韩字符按 2 计，其余非空白按 1 计）
        var text = 0
        /// 其中落在 `<a>` 里的权重——链接密度就是 links / text
        var links = 0
        /// `<br>` 数量：小说正文几乎全靠 br 折行，导航栏没有
        var breaks = 0
    }

    private(set) var nodes: [Node] = []
    private(set) var baseHref: String?

    /// `#document` 永远在下标 0 —— 拿不到正文容器时用它兜底取整页可见文本。
    var root: Int { 0 }

    /// 自闭合 / 空元素
    static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]
    /// 整块丢弃：脚本、样式、图标、表单控件、以及**导航类语义标签**
    static let droppedTags: Set<String> = [
        "script", "style", "noscript", "svg", "iframe", "canvas", "template",
        "textarea", "select", "option", "button", "form", "input",
        "nav", "header", "footer", "aside", "map", "object", "embed",
        "audio", "video"
    ]
    /// 块级元素：抽取文本时在边界折行
    static let blockTags: Set<String> = [
        "address", "article", "blockquote", "dd", "div", "dl", "dt", "fieldset",
        "figcaption", "figure", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "li",
        "main", "ol", "p", "pre", "section", "table", "tbody", "td", "tfoot",
        "th", "thead", "tr", "ul"
    ]
    /// 内容按原样吞掉，不做标签解析
    static let rawTextTags: Set<String> = [
        "script", "style", "noscript", "svg", "iframe", "textarea", "canvas", "template"
    ]

    init(html: String) {
        nodes.append(Node(tag: "#document"))
        parse(Array(html))
    }

    // MARK: - 解析

    private func parse(_ c: [Character]) {
        var stack: [Int] = [0]
        var i = 0
        let total = c.count

        func push(_ node: Node) -> Int {
            var node = node
            let parent = stack[stack.count - 1]
            node.parent = parent
            node.depth = nodes[parent].depth + 1
            nodes.append(node)
            let idx = nodes.count - 1
            nodes[parent].children.append(idx)
            return idx
        }

        func openIndex(_ tag: String) -> Int? {
            var k = stack.count - 1
            while k >= 0 {
                if nodes[stack[k]].tag == tag { return k }
                k -= 1
            }
            return nil
        }

        while i < total {
            if c[i] != "<" {
                var j = i
                while j < total && c[j] != "<" { j += 1 }
                if j > i {
                    _ = push(Node(tag: "#text", text: String(c[i..<j])))
                }
                i = j
                continue
            }
            // <!-- 注释 -->
            if i + 3 < total, c[i + 1] == "!", c[i + 2] == "-", c[i + 3] == "-" {
                i = HTMLDocument.index(after: i + 4, token: "-->", in: c)
                continue
            }
            // <!doctype> / <?xml ?>
            if i + 1 < total, c[i + 1] == "!" || c[i + 1] == "?" {
                i = HTMLDocument.index(after: i + 1, token: ">", in: c)
                continue
            }
            // </tag>
            if i + 1 < total, c[i + 1] == "/" {
                var j = i + 2
                let name = HTMLDocument.readName(c, &j).lowercased()
                i = HTMLDocument.index(after: j, token: ">", in: c)
                if !name.isEmpty, let pos = openIndex(name), pos >= 1 {
                    stack.removeSubrange(pos...)
                }
                continue
            }
            // <tag ...>
            var j = i + 1
            let name = HTMLDocument.readName(c, &j).lowercased()
            guard !name.isEmpty else { i += 1; continue }

            var attrs: [String: String] = [:]
            var selfClosing = false
            var k = j
            while k < total, c[k] != ">" {
                if c[k] == "/", k + 1 < total, c[k + 1] == ">" { selfClosing = true; k += 1; break }
                if c[k].isWhitespace { k += 1; continue }
                let key = HTMLDocument.readName(c, &k).lowercased()
                if key.isEmpty { k += 1; continue }
                var value = ""
                var p = k
                while p < total, c[p].isWhitespace { p += 1 }
                if p < total, c[p] == "=" {
                    p += 1
                    while p < total, c[p].isWhitespace { p += 1 }
                    if p < total, c[p] == "\"" || c[p] == "'" {
                        let quote = c[p]
                        p += 1
                        var v = ""
                        while p < total, c[p] != quote { v.append(c[p]); p += 1 }
                        if p < total { p += 1 }
                        value = v
                    } else {
                        var v = ""
                        while p < total, !c[p].isWhitespace, c[p] != ">" { v.append(c[p]); p += 1 }
                        value = v
                    }
                    k = p
                }
                attrs[key] = HTMLDocument.decodeEntities(value)
            }
            i = HTMLDocument.index(after: k, token: ">", in: c)

            if name == "base", baseHref == nil, let href = attrs["href"] { baseHref = href }
            let idx = push(Node(tag: name, attrs: attrs))
            if HTMLDocument.rawTextTags.contains(name) {
                i = HTMLDocument.index(after: i, token: "</" + name, in: c)
                i = HTMLDocument.index(after: i, token: ">", in: c)
                continue
            }
            if !selfClosing, !HTMLDocument.voidTags.contains(name) {
                stack.append(idx)
            }
        }
    }

    private static func readName(_ c: [Character], _ i: inout Int) -> String {
        var s = ""
        while i < c.count {
            let ch = c[i]
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == ":" {
                s.append(ch)
                i += 1
            } else {
                break
            }
        }
        return s
    }

    /// 从 `from` 起找到 `token`，返回它**之后**的下标；找不到返回 count。
    private static func index(after from: Int, token: String, in c: [Character]) -> Int {
        let t = Array(token)
        guard !t.isEmpty else { return from }
        var i = max(from, 0)
        while i + t.count <= c.count {
            var k = 0
            var matched = true
            while k < t.count {
                if c[i + k] != t[k] { matched = false; break }
                k += 1
            }
            if matched { return i + t.count }
            i += 1
        }
        return c.count
    }

    // MARK: - 实体

    /// 注意 `&amp;` 必须放最后，否则 `&amp;lt;` 会被二次解码成 `<`。
    private static let namedEntities: [(String, String)] = [
        ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
        ("&apos;", "'"), ("&#39;", "'"), ("&middot;", "·"), ("&hellip;", "…"),
        ("&ldquo;", "“"), ("&rdquo;", "”"), ("&lsquo;", "‘"), ("&rsquo;", "’"),
        ("&mdash;", "—"), ("&ndash;", "–"), ("&times;", "×"), ("&divide;", "÷"),
        ("&laquo;", "«"), ("&raquo;", "»"), ("&copy;", "©"), ("&reg;", "®"),
        ("&deg;", "°"), ("&plusmn;", "±"), ("&amp;", "&")
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var s = text
        for (key, value) in namedEntities where s.contains(key) {
            s = s.replacingOccurrences(of: key, with: value, options: .caseInsensitive)
        }
        if s.contains("&#"),
           let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]{1,6}|[0-9]{1,7});") {
            let ns = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                let token = ns.substring(with: match.range(at: 1))
                var value: UInt32?
                if token.lowercased().hasPrefix("x") {
                    value = UInt32(token.dropFirst(), radix: 16)
                } else {
                    value = UInt32(token)
                }
                guard let value, value > 0, let text = HTMLDocument.string(from: value) else { continue }
                s = (s as NSString).replacingCharacters(in: match.range, with: text)
            }
        }
        return s
    }

    /// 用 UTF-16 手工拼字符，绕开 `UnicodeScalar` 到 `String` 的各种初始化重载，
    /// 顺便把非 BMP 的代理对一起处理对。
    static func string(from value: UInt32) -> String? {
        guard value <= 0x10FFFF, !(value >= 0xD800 && value <= 0xDFFF) else { return nil }
        if value <= 0xFFFF {
            return String(decoding: [UInt16(value)], as: UTF16.self)
        }
        let adjusted = value - 0x10000
        let high = UInt16(0xD800 + (adjusted >> 10))
        let low = UInt16(0xDC00 + (adjusted & 0x3FF))
        return String(decoding: [high, low], as: UTF16.self)
    }

    // MARK: - 文本抽取

    /// 抽某个节点下的可见文本。块级标签与 `<br>` 折行；脚本、样式、导航整块丢弃。
    func visibleText(of index: Int) -> String {
        var out = ""
        appendText(index, &out, isRoot: true)
        return out
    }

    private func appendText(_ index: Int, _ out: inout String, isRoot: Bool) {
        let node = nodes[index]
        if node.tag == "#text" {
            out += HTMLDocument.decodeEntities(node.text)
            return
        }
        // 起始节点本身不判丢弃，否则 `<option>` 这类被丢标签自己也取不到文本
        if !isRoot, HTMLDocument.droppedTags.contains(node.tag) { return }
        if !isRoot, isHidden(node) { return }
        if node.tag == "br" || node.tag == "hr" {
            out += "\n"
            return
        }
        let block = HTMLDocument.blockTags.contains(node.tag)
        if block, !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        for child in node.children {
            appendText(child, &out, isRoot: false)
        }
        if block, !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
    }

    /// 把折行全部压成空格——用于取 `<a>`、`<option>` 这类单行的标签文字。
    func inlineText(of index: Int) -> String {
        let raw = visibleText(of: index)
        var out = ""
        var pendingSpace = false
        for ch in raw {
            if ch.isWhitespace {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private func isHidden(_ node: Node) -> Bool {
        if node.attrs["hidden"] != nil { return true }
        if let flag = node.attrs["aria-hidden"], flag.lowercased() == "true" { return true }
        if let style = node.attrs["style"] {
            let flat = style.replacingOccurrences(of: " ", with: "").lowercased()
            if flat.contains("display:none") || flat.contains("visibility:hidden") { return true }
        }
        return false
    }

    // MARK: - 统计 / 查询

    /// 自底向上一次遍历，算出每个节点的子树统计。
    /// 子节点下标一定大于父节点（深度优先追加），所以倒序扫一遍足够。
    func statistics() -> [Stats] {
        var list = Array(repeating: Stats(), count: nodes.count)
        var i = nodes.count - 1
        while i >= 0 {
            let node = nodes[i]
            if node.tag == "#text" {
                list[i].text = HTMLDocument.textWeight(node.text)
            } else if node.tag == "br" {
                list[i].breaks = 1
            }
            let parent = node.parent
            // 被丢弃标签的文本不进祖先统计，和 visibleText 的口径保持一致
            let carries = parent >= 0 && !HTMLDocument.droppedTags.contains(node.tag)
            if carries {
                var carryLinks = list[i].links
                if node.tag == "a" { carryLinks += list[i].text }
                list[parent].text += list[i].text
                list[parent].links += carryLinks
                list[parent].breaks += list[i].breaks
            }
            i -= 1
        }
        return list
    }

    /// 中日韩字符按 2 计：同样字符数下中文正文的权重要压过拉丁文的导航文字。
    static func textWeight(_ text: String) -> Int {
        var n = 0
        for ch in text {
            if ch.isWhitespace || ch == "&" { continue }
            let value = ch.unicodeScalars.first?.value ?? 0
            n += value > 0x2E80 ? 2 : 1
        }
        return n
    }

    func elementIndices(tag: String) -> [Int] {
        var out: [Int] = []
        for (i, node) in nodes.enumerated() where node.tag == tag { out.append(i) }
        return out
    }

    func descendantIndices(of index: Int, tag: String) -> [Int] {
        var out: [Int] = []
        if index < 0 || index >= nodes.count { return out }
        var pending = nodes[index].children
        while let cur = pending.popLast() {
            if nodes[cur].tag == tag { out.append(cur) }
            pending.append(contentsOf: nodes[cur].children)
        }
        out.sort()
        return out
    }

    /// 节点自身 + 祖先的 id/class 串，用于关键词命中判断。
    func hint(of index: Int) -> String {
        var parts: [String] = []
        var cur = index
        var hops = 0
        while cur >= 0, cur < nodes.count, hops < 4 {
            let node = nodes[cur]
            if let id = node.attrs["id"] { parts.append(id) }
            if let cls = node.attrs["class"] { parts.append(cls) }
            cur = node.parent
            hops += 1
        }
        return parts.joined(separator: " ").lowercased()
    }
}
