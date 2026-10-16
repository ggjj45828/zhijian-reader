import Foundation

enum SearchService {
    private struct Engine: Sendable { let title: String; let base: String; let key: String }
    private static let engines = [
        Engine(title: "百度", base: "https://www.baidu.com/s", key: "wd"),
        Engine(title: "必应", base: "https://www.bing.com/search", key: "q")
    ]

    static func search(_ rawQuery: String) async -> ([WebCandidate], [String]) {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ([], []) }
        let query = q + " 小说 在线阅读 章节"
        return await withTaskGroup(of: (String, [WebCandidate], String?).self) { group in
            for engine in engines {
                group.addTask {
                    do { return (engine.title, try await fetch(engine, query: query), nil) }
                    catch { return (engine.title, [], error.localizedDescription) }
                }
            }
            var results: [WebCandidate] = [], failures: [String] = []
            for await (name, found, error) in group {
                results.append(contentsOf: found)
                if let error { failures.append("\(name)：\(error)") }
            }
            var seen = Set<String>()
            results = results.filter { seen.insert($0.url.absoluteString).inserted }
            return (Array(results.prefix(20)), failures)
        }
    }

    private static func fetch(_ engine: Engine, query: String) async throws -> [WebCandidate] {
        guard var components = URLComponents(string: engine.base) else { return [] }
        components.queryItems = [URLQueryItem(name: engine.key, value: query)]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url); request.timeoutInterval = 9
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.6", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SearchIssue.badResponse }
        let html = String(decoding: data, as: UTF8.self)
        return HTMLText.searchCandidates(html, engine: engine.title)
    }
}

enum SearchIssue: LocalizedError {
    case badResponse
    var errorDescription: String? { "搜索网站没有返回有效页面" }
}
