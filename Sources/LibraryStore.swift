import Foundation
import UIKit
import PDFKit
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published var books: [ReadingBook] = [] { didSet { save() } }
    @Published var theme: ReaderTheme = ReaderTheme(rawValue: UserDefaults.standard.string(forKey: "reader.theme") ?? "paper") ?? .paper {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "reader.theme") }
    }
    @Published var fontSize: Double = UserDefaults.standard.object(forKey: "reader.fontSize") as? Double ?? 19 {
        didSet { UserDefaults.standard.set(fontSize, forKey: "reader.fontSize") }
    }
    @Published var dailyGoal: Int = UserDefaults.standard.object(forKey: "reader.dailyGoal") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(dailyGoal, forKey: "reader.dailyGoal") }
    }
    @Published var minutesByDay: [String: Int] = [:] { didSet { persistMinutes() } }

    private let folder: URL
    private let libraryURL: URL
    private let minutesURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("Zhijian", isDirectory: true)
        libraryURL = folder.appendingPathComponent("library.json")
        minutesURL = folder.appendingPathComponent("reading-minutes.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: libraryURL), let loaded = try? JSONDecoder().decode([ReadingBook].self, from: data) { books = loaded }
        if let data = try? Data(contentsOf: minutesURL), let loaded = try? JSONDecoder().decode([String: Int].self, from: data) { minutesByDay = loaded }
    }

    private func save() {
        guard let data = try? JSONEncoder.pretty.encode(books) else { return }
        try? data.write(to: libraryURL, options: .atomic)
    }
    private func persistMinutes() {
        guard let data = try? JSONEncoder().encode(minutesByDay) else { return }
        try? data.write(to: minutesURL, options: .atomic)
    }
    var todayMinutes: Int { minutesByDay[Self.dayKey(Date())] ?? 0 }
    /// `nonisolated`：`ReadingStatsView` 的 `week` 之类在视图里取日期键，
    /// 不这么标就会把整个 @MainActor 类的隔离传染出去。
    nonisolated static func dayKey(_ date: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date) }
    func addReadingMinute() { minutesByDay[Self.dayKey(Date()), default: 0] += 1 }
    func add(_ book: ReadingBook) { books.insert(book, at: 0) }
    func delete(_ book: ReadingBook) { books.removeAll { $0.id == book.id } }
    func update(_ book: ReadingBook) { if let i = books.firstIndex(where: { $0.id == book.id }) { books[i] = book } }
    /// 网页连载在读的时候回写进度：目录抓全了要存下来（下次从书架进来直接有目录），
    /// 当前章正文也存一份，离线时书架上至少还能看到最后读到的内容。
    func updateWebReading(id: UUID, index: Int, chapters: [WebChapter], text: String, title: String) {
        guard let position = books.firstIndex(where: { $0.id == id }) else { return }
        if !chapters.isEmpty { books[position].webChapters = chapters }
        if index >= 0 { books[position].webIndex = index }
        if !text.isEmpty { books[position].content = text }
        if !title.isEmpty { books[position].lastChapterTitle = title }
        books[position].lastReadAt = Date()
        if !chapters.isEmpty, index >= 0 {
            books[position].progress = Double(index + 1) / Double(chapters.count)
        }
    }
    func importFile(_ url: URL) throws -> ReadingBook {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let text: String
        var title = url.deletingPathExtension().lastPathComponent
        var author = "本地导入"
        let format: String
        switch ext {
        case "txt", "md", "markdown": text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self); format = ext.uppercased()
        case "html", "htm": text = HTMLText.extract(String(decoding: data, as: UTF8.self)); format = "HTML"
        case "rtf":
            let attributed = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            text = attributed.string; format = "RTF"
        case "fb2":
            let book = try FB2Document(data: data).read()
            text = book.content; title = book.title ?? title; author = book.author ?? author; format = "FB2"
        case "epub":
            let book = try EPUBDocument(url: url).read()
            text = book.content; title = book.title ?? title; author = book.author ?? author; format = "EPUB"
        case "docx": text = try DOCXDocument(url: url).read(); format = "DOCX"
        case "pdf":
            guard let pdf = PDFDocument(data: data) else { throw ImportIssue.invalidFile }
            text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n\n"); format = "PDF"
        default: throw ImportIssue.unsupported
        }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 else { throw ImportIssue.emptyText }
        return ReadingBook(title: title, author: author, format: format, content: text)
    }
}

enum ImportIssue: LocalizedError {
    case invalidFile, unsupported, emptyText
    var errorDescription: String? {
        switch self { case .invalidFile: "文件无法读取或格式损坏"; case .unsupported: "支持 TXT、Markdown、HTML、PDF、EPUB、FB2、DOCX 和 RTF"; case .emptyText: "文件中没有可读取的正文" }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}
