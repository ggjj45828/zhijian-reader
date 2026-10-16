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

    static func title(_ html: String, fallback: String) -> String {
        guard let range = html.range(of: "(?is)<title[^>]*>(.*?)</title>", options: .regularExpression) else { return fallback }
        let raw = String(html[range]).replacingOccurrences(of: "(?is)</?title[^>]*>", with: "", options: .regularExpression)
        let result = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? fallback : result
    }

    static func searchCandidates(_ html: String, engine: String) -> [WebCandidate] {
        guard let regex = try? NSRegularExpression(pattern: "(?is)<h[23][^>]*>.*?<a[^>]+href=[\\\"']([^\\\"']+)[\\\"'][^>]*>(.*?)</a>.*?</h[23]>") else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges > 2 else { return nil }
            let rawURL = decodeEntities(ns.substring(with: match.range(at: 1)))
            let rawTitle = ns.substring(with: match.range(at: 2))
            let title = extract(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: rawURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), title.count > 2 else { return nil }
            let start = max(0, match.range.location - 700), end = min(ns.length, match.range.location + match.range.length + 1800)
            let context = ns.substring(with: NSRange(location: start, length: end - start))
            let text = extract(context).trimmingCharacters(in: .whitespacesAndNewlines)
            return WebCandidate(title: title, url: url, snippet: String(text.prefix(180)), engine: engine)
        }
    }

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
    /// 取网页原文，同时把**最终** URL 带回来（站点 301/302 跳转很常见，
    /// 后续解析相对链接必须用最终地址当 base，否则目录/下一章全部解析错）。
    static func fetchHTML(_ url: URL) async throws -> (html: String, url: URL) {
        var request = URLRequest(url: url); request.timeoutInterval = 16
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.6", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SearchIssue.badResponse }
        let finalURL = response.url ?? url
        return (HTMLText.decodeBytes(data, response: response), finalURL)
    }
}
