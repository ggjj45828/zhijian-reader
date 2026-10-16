import Foundation
import SwiftUI

enum ReaderTheme: String, CaseIterable, Identifiable, Codable {
    case paper, white, green, night
    var id: String { rawValue }
    var title: String { switch self { case .paper: "暖纸"; case .white: "白昼"; case .green: "松绿"; case .night: "夜读" } }
    var background: Color { switch self { case .paper: Color(red: 0.97, green: 0.96, blue: 0.92); case .white: .white; case .green: Color(red: 0.92, green: 0.95, blue: 0.91); case .night: Color(red: 0.13, green: 0.15, blue: 0.13) } }
    var ink: Color { self == .night ? Color(red: 0.9, green: 0.89, blue: 0.84) : Color(red: 0.16, green: 0.17, blue: 0.15) }
    var tint: Color { switch self { case .paper: Color(red: 0.34, green: 0.46, blue: 0.37); case .white: Color(red: 0.24, green: 0.40, blue: 0.31); case .green: Color(red: 0.25, green: 0.45, blue: 0.31); case .night: Color(red: 0.68, green: 0.77, blue: 0.65) } }
}

struct ReaderBookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var offset: Int
    var createdAt = Date()
}

struct ReaderNote: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var quote: String
    var createdAt = Date()
}

struct ReadingBook: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var author: String
    var format: String
    var content: String
    var sourceURL: String?
    var shelf: String = "全部书籍"
    var addedAt = Date()
    var lastReadAt: Date?
    var progress: Double = 0
    var bookmarks: [ReaderBookmark] = []
    var notes: [ReaderNote] = []
    /// 网页连载的目录（只对「从网页加入书架」的书有意义）。
    /// 声明成 Optional 是刻意的：可选字段在 key 缺失时解成 nil，
    /// 而带默认值的非可选字段在 key 缺失时会**整条 decode 失败**，
    /// 那样老版本存的 library.json 会被整库丢掉。
    var webChapters: [WebChapter]?
    var webIndex: Int?
    /// 最近读到的章节名，用于书架上「继续阅读」那一行
    var lastChapterTitle: String?
    enum CodingKeys: String, CodingKey { case id, title, author, format, content, sourceURL = "sourceUrl", shelf, addedAt, lastReadAt, progress, bookmarks, notes, webChapters, webIndex, lastChapterTitle }
    var wordCount: Int { content.count }
    /// 有目录 + 有入口链接 = 按网页连载打开，而不是按离线正文打开
    var isWebSerial: Bool { sourceURL != nil && !(webChapters ?? []).isEmpty }
    var chapters: [String] { content.components(separatedBy: .newlines).filter { line in
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count < 55 && (t.range(of: #"^(第[零〇一二三四五六七八九十百千万\d]+[章节回卷部篇]|序章|楔子|番外|Chapter\s+\d+)"#, options: .regularExpression) != nil)
    } }
}

struct WebCandidate: Identifiable, Hashable {
    var id: String { url.absoluteString }
    let title: String
    let url: URL
    let snippet: String
    let engine: String
}
