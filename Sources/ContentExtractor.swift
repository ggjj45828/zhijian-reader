import Foundation
import CoreFoundation

enum HTMLText {
    static func extract(_ source: String) -> String {
        var html = source
        for pattern in ["(?is)<script\\b[^>]*>.*?</script>", "(?is)<style\\b[^>]*>.*?</style>", "(?is)<noscript\\b[^>]*>.*?</noscript>", "(?is)<svg\\b[^>]*>.*?</svg>", "(?is)<!--.*?-->"] { html = html.replacingOccurrences(of: pattern, with: " ", options: .regularExpression) }
        html = html.replacingOccurrences(of: "(?i)</(p|div|article|section|h[1-6]|li|br|tr)>", with: "\n\n", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
        html = decodeEntities(html)
        let lines = html.components(separatedBy: .newlines).map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.joined(separator: "\n\n")
    }

    // 说明：原来这里还有 `title(_:fallback:)` 与 `searchCandidates(_:engine:)` 两个方法。
    // 前者已经没人调用（标题统一由 `ArticleCleaner.titles` 从 `<title>` 分段里拆），
    // 后者是「靠 <h2>/<h3> 里套 <a> 的结构抓结果」的旧实现 —— 只对百度/必应碰巧有效，
    // 对 360 那种全走 /link? 跳转、搜狗那种 JS 渲染、以及书站目录页全都抓不到。
    // 两者都已删除，取结果改由 `SearchService` 的通用「站外链接 + 邻域文本」启发式负责。

    private static func decodeEntities(_ text: String) -> String {
        var s = text
        let replacements = ["&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&middot;": "·", "&#x2F;": "/"]
        for (key, value) in replacements { s = s.replacingOccurrences(of: key, with: value, options: .caseInsensitive) }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-f]+|[0-9]+);", options: .caseInsensitive) {
            let ns = s as NSString
            for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                let token = ns.substring(with: match.range(at: 1))
                let value = token.lowercased().hasPrefix("x") ? UInt32(token.dropFirst(), radix: 16) : UInt32(token)
                if let value, let scalar = UnicodeScalar(value) { s = (s as NSString).replacingCharacters(in: match.range, with: String(scalar)) }
            }
        }
        return s
    }

    static func decodeBytes(_ data: Data, response: URLResponse) -> String {
        var names: [String] = []
        if let charset = mimeCharset(response) { names.append(charset) }
        let prefix = String(decoding: data.prefix(8192), as: UTF8.self)
        if let range = prefix.range(of: #"(?i)<meta[^>]+charset\s*=\s*['\"]?([\w.-]+)"#, options: .regularExpression) {
            let fragment = String(prefix[range])
            if let capture = fragment.range(of: #"(?i)charset\s*=\s*['\"]?([\w.-]+)"#, options: .regularExpression) {
                names.append(String(fragment[capture]).components(separatedBy: "=").last?.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) ?? "")
            }
        }
        names += ["utf-8", "gb18030"]
        for name in names where !name.isEmpty {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cf)
                if let value = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) { return value }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func mimeCharset(_ response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse, let type = http.value(forHTTPHeaderField: "Content-Type"),
              let match = type.range(of: #"(?i)charset\s*=\s*['\"]?([\w.-]+)"#, options: .regularExpression) else { return nil }
        return String(type[match]).components(separatedBy: "=").last?.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
    }
}

enum ArticleService {
    /// 移动版 Safari：章节页用这个，很多书站会因此给一个更干净、JS 更少的页面
    private static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    /// 桌面版 Chrome：**搜索引擎必须用这个**。实测同一个 query，
    /// 移动 UA 下百度会 302 到验证码页、搜狗只剩 2 条外链、360 只给 4 个域；
    /// 换成桌面 UA 后必应 13 个域、360 192 条外链、搜狗 62 条，差距是数量级的。
    private static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    /// 取网页原文，同时把**最终** URL 带回来（站点 301/302 跳转很常见，
    /// 后续解析相对链接必须用最终地址当 base，否则目录/下一章全部解析错）。
    static func fetchHTML(_ url: URL, timeout: TimeInterval = 16, desktop: Bool = false) async throws -> (html: String, url: URL) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(desktop ? desktopUA : mobileUA, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.6", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SearchIssue.badResponse }
        let finalURL = response.url ?? url
        return (HTMLText.decodeBytes(data, response: response), finalURL)
    }

    /// 只要状态码 200 就返回**原始 Data**（开放书源的 JSON 接口用，不能当 HTML 解码）
    static func fetchData(_ url: URL, timeout: TimeInterval = 14) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/html;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SearchIssue.badResponse }
        return data
    }
}
