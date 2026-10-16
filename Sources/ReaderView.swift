import SwiftUI
import WebKit

struct ReaderView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var book: ReadingBook
    @State private var page = 0
    @State private var showTOC = false
    @State private var showNote = false
    @State private var noteText = ""
    @State private var fallbackWeb = false

    init(book: ReadingBook) { _book = State(initialValue: book) }
    private var pages: [String] {
        let paragraphs = book.content.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var result: [String] = [], current = ""
        for paragraph in paragraphs {
            if current.count + paragraph.count > 1700 && !current.isEmpty { result.append(current); current = "" }
            current += (current.isEmpty ? "" : "\n\n") + paragraph
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [book.content] : result
    }
    private var currentText: String { pages[min(page, max(0, pages.count - 1))] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { showTOC = true } label: { Label("目录", systemImage: "list.bullet") }
                Spacer()
                Text("\(page + 1) / \(pages.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("添加书签", systemImage: "bookmark") { addBookmark() }
                    Button("写读书笔记", systemImage: "note.text") { showNote = true }
                    Button("网页原文模式", systemImage: "safari") { fallbackWeb = true }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            }.padding(.horizontal).padding(.vertical, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(book.title).font(.system(size: 27, weight: .bold, design: .serif))
                        Text(book.author).font(.subheadline).foregroundStyle(.secondary)
                        Text(currentText).font(.system(size: store.fontSize, weight: .regular, design: .serif)).lineSpacing(9).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id(page)
                        HStack { Text("\(book.format) · \(book.wordCount) 字"); Spacer(); Text("\(Int(book.progress * 100))%") }.font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 24).padding(.vertical, 28)
                }.onChange(of: page) { _, value in withAnimation { proxy.scrollTo(value, anchor: .top) } }
            }
            HStack(spacing: 22) {
                Button { page = max(0, page - 1); saveProgress() } label: { Label("上一页", systemImage: "chevron.left") }.disabled(page == 0)
                Spacer()
                Button { store.fontSize = max(14, store.fontSize - 1) } label: { Text("A−") }
                Button { store.fontSize = min(32, store.fontSize + 1) } label: { Text("A＋") }
                Spacer()
                Button { page = min(pages.count - 1, page + 1); saveProgress() } label: { Label("下一页", systemImage: "chevron.right").labelStyle(.titleAndIcon) }.disabled(page >= pages.count - 1)
            }.font(.subheadline.weight(.medium)).padding(.horizontal, 18).padding(.vertical, 14).background(store.theme.background)
        }
        .foregroundStyle(store.theme.ink).background(store.theme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showTOC) { tocSheet }
        .sheet(isPresented: $showNote) { noteSheet }
        .sheet(isPresented: $fallbackWeb) { if let url = book.sourceURL.flatMap({ URL(string: $0) }) { InAppWebView(url: url).ignoresSafeArea() } else { ContentUnavailableView("没有网页原文", systemImage: "safari") } }
        .onAppear { page = min(Int(book.progress * Double(max(1, pages.count))), pages.count - 1); book.lastReadAt = Date(); saveProgress() }
        .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)); if !Task.isCancelled { store.addReadingMinute() } } }
        .onDisappear { saveProgress() }
    }

    // 下面这两个 sheet 是**独立的计算属性**，不在 `body` 里，闭包不会继承 body 的
    // 主线程隔离。它们内部要调 `store.update(_:)`（LibraryStore 是 @MainActor），
    // 所以整块必须显式标 @MainActor，否则报「call to main actor-isolated instance
    // method in a synchronous nonisolated context」。
    @MainActor
    private var tocSheet: some View {
        NavigationStack { List { if book.chapters.isEmpty { ContentUnavailableView("暂无章节标题", systemImage: "list.bullet") } else { ForEach(book.chapters.indices, id: \.self) { index in let title = book.chapters[index]; Button(title) { if let pageIndex = pages.firstIndex(where: { $0.localizedCaseInsensitiveContains(title) }) { page = pageIndex; saveProgress() }; showTOC = false }.foregroundStyle(.primary) } } }.navigationTitle("章节目录").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showTOC = false } } } }
            .presentationDetents([.medium, .large])
    }
    @MainActor
    private var noteSheet: some View {
        NavigationStack { Form { Section("本页摘录") { Text(String(currentText.prefix(400))).font(.callout).foregroundStyle(.secondary) }; Section("笔记") { TextEditor(text: $noteText).frame(minHeight: 120) } }.navigationTitle("读书笔记").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showNote = false } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { book.notes.append(ReaderNote(text: noteText, quote: String(currentText.prefix(200)))); store.update(book); noteText = ""; showNote = false } .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } } }.presentationDetents([.medium, .large])
    }
    @MainActor private func addBookmark() { book.bookmarks.append(ReaderBookmark(title: "第 \(page + 1) 页", offset: page)); store.update(book) }
    @MainActor private func saveProgress() { book.progress = Double(page + 1) / Double(max(pages.count, 1)); book.lastReadAt = Date(); store.update(book) }
}

// MARK: - 网页连载阅读器

/// 网页小说阅读页。
///
/// 和 v1.0 的 `ArticleView` 的区别：
///   · 正文不再是「整页替换掉标签」，而是先识别正文容器，再逐行过滤站点噪声
///   · 自动抓目录（`<select>` 下拉优先，其次按父节点聚类章节链接）；抓不到就顺着
///     「目录」链接去目录页再抓一次
///   · 底部常驻 上一章 / 目录 / 下一章；有目录时用目录下标翻页，比站点链接可靠
///   · 落在书籍介绍页（正文很短但有目录）时自动进入第一章
struct WebNovelReader: View {
    @EnvironmentObject private var store: LibraryStore

    private let start: WebChapter
    private let bookID: UUID?

    @State private var chapters: [WebChapter] = []
    @State private var index = -1
    @State private var title = ""
    @State private var content = ""
    @State private var plain = ""
    @State private var bookName: String?
    @State private var status = ""
    @State private var loading = true
    @State private var error: String?
    @State private var showTOC = false
    @State private var showWeb = false
    @State private var purified = true
    @State private var savedID: UUID?
    @State private var currentURL = ""
    @State private var previousURL: String?
    @State private var nextURL: String?
    @State private var tocURL: String?

    init(chapter: WebChapter, bookID: UUID? = nil) {
        self.start = chapter
        self.bookID = bookID
    }

    private enum LoadResult { case ok, landing, failed(String) }

    private var displayText: String { purified ? content : plain }
    private var activeID: UUID? { bookID ?? savedID }
    private var alreadySaved: Bool { activeID != nil }

    private var positionText: String {
        guard index >= 0, !chapters.isEmpty else { return "" }
        return "\(index + 1) / \(chapters.count)"
    }
    private var previousTarget: String? {
        if index > 0, index <= chapters.count { return chapters[index - 1].url }
        return previousURL
    }
    private var nextTarget: String? {
        if index >= 0, index + 1 < chapters.count { return chapters[index + 1].url }
        return nextURL
    }

    var body: some View {
        VStack(spacing: 0) {
            if loading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在读取网页并识别正文…").font(.footnote).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                VStack(spacing: 14) {
                    ContentUnavailableView("没有读到正文", systemImage: "doc.text.magnifyingglass", description: Text(error))
                    Button("在应用内打开原网页") { showWeb = true }.buttonStyle(.borderedProminent)
                    if previousTarget != nil {
                        Button("回到上一章") { go(previousTarget) }.buttonStyle(.bordered)
                    }
                }.padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(title).font(.system(size: 25, weight: .bold, design: .serif))
                        if !status.isEmpty {
                            Text(status).font(.caption).foregroundStyle(store.theme.tint)
                        }
                        Text(displayText)
                            .font(.system(size: store.fontSize, design: .serif))
                            .lineSpacing(10)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        tail
                    }.padding(.horizontal, 22).padding(.vertical, 20)
                }
                bottomBar
            }
        }
        .foregroundStyle(store.theme.ink).background(store.theme.background.ignoresSafeArea())
        .navigationTitle(positionText.isEmpty ? (title.isEmpty ? "阅读" : title) : positionText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(purified ? "关闭净化（看网页原文）" : "开启净化（去导航与广告行）") { purified.toggle() }
                    Button("重新抓取目录") { Task { await rescanTOC() } }
                    Button("在应用内打开原网页") { showWeb = true }
                    Button(alreadySaved ? "已加入书架" : "加入书架") { save() }
                        .disabled(alreadySaved || content.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showTOC) { tocSheet }
        .sheet(isPresented: $showWeb) {
            NavigationStack {
                if let url = URL(string: currentURL.isEmpty ? start.url : currentURL) {
                    InAppWebView(url: url).ignoresSafeArea()
                        .navigationTitle("网页原文").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("完成") { showWeb = false } } }
                } else {
                    ContentUnavailableView("链接无效", systemImage: "link.badge.plus")
                }
            }
        }
        .task { await load(start) }
    }

    /// 正文末尾的翻页区：读完一章顺手点下一章，不用回头去点底栏
    @MainActor
    private var tail: some View {
        VStack(spacing: 12) {
            Divider().padding(.top, 8)
            HStack(spacing: 12) {
                if previousTarget != nil {
                    Button("上一章") { go(previousTarget) }.buttonStyle(.bordered)
                }
                if nextTarget != nil {
                    Button("下一章") { go(nextTarget) }.buttonStyle(.borderedProminent)
                } else {
                    Button("抓取下一章") { Task { await rescanTOC() } }.buttonStyle(.bordered)
                }
            }
            Text(purified ? "已净化：去掉了导航、站点信息与广告行" : "净化已关闭：显示网页原文，含导航与站点文字")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @MainActor
    private var bottomBar: some View {
        HStack(spacing: 0) {
            Button { go(previousTarget) } label: {
                VStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                    Text("上一章").font(.caption2)
                }.frame(maxWidth: .infinity).contentShape(Rectangle())
            }
            .disabled(previousTarget == nil)
            .foregroundStyle(previousTarget == nil ? Color.secondary : store.theme.tint)

            Button { showTOC = true } label: {
                VStack(spacing: 3) {
                    Image(systemName: "list.bullet").font(.system(size: 17, weight: .semibold))
                    Text(chapters.isEmpty ? "无目录" : "目录 \(chapters.count)").font(.caption2)
                }.frame(maxWidth: .infinity).contentShape(Rectangle())
            }
            .disabled(chapters.isEmpty)
            .foregroundStyle(chapters.isEmpty ? Color.secondary : store.theme.tint)

            Button { go(nextTarget) } label: {
                VStack(spacing: 3) {
                    Image(systemName: "chevron.right").font(.system(size: 17, weight: .semibold))
                    Text("下一章").font(.caption2)
                }.frame(maxWidth: .infinity).contentShape(Rectangle())
            }
            .disabled(nextTarget == nil)
            .foregroundStyle(nextTarget == nil ? Color.secondary : store.theme.tint)
        }
        .padding(.vertical, 8)
        .background(store.theme.background)
        .overlay(Divider(), alignment: .top)
    }

    @MainActor
    private var tocSheet: some View {
        NavigationStack {
            Group {
                if chapters.isEmpty {
                    ContentUnavailableView("还没有抓到目录", systemImage: "list.bullet",
                                           description: Text("点右上角「重新抓取目录」。有些站点把目录放在需要 JavaScript 的页面里，这种情况只能一章一章往下翻。"))
                } else {
                    ScrollViewReader { proxy in
                        List {
                            ForEach(chapters.indices, id: \.self) { position in
                                Button {
                                    showTOC = false
                                    go(chapters[position].url)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(chapters[position].title)
                                            .font(.callout)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                            .foregroundStyle(position == index ? store.theme.tint : store.theme.ink)
                                        Spacer(minLength: 0)
                                        if position == index {
                                            Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(store.theme.tint)
                                        }
                                    }
                                }.id(position)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .onAppear { if index >= 0 { proxy.scrollTo(index, anchor: .center) } }
                    }
                }
            }
            .background(store.theme.background)
            .navigationTitle(chapters.isEmpty ? "目录" : "目录 · 共 \(chapters.count) 章")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showTOC = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - 加载

    @MainActor
    private func load(_ target: WebChapter?) async {
        guard let target else { return }
        let result = await fetchChapter(target)
        if case .landing = result, let first = chapters.first {
            _ = await fetchChapter(first)
            status = "这是书籍介绍页，已自动进入第一章"
        }
    }

    @MainActor
    private func fetchChapter(_ target: WebChapter) async -> LoadResult {
        guard let url = URL(string: target.url) else {
            error = "章节链接无效"
            loading = false
            return .failed("章节链接无效")
        }
        loading = true
        error = nil
        do {
            let page = try await ArticleService.fetchHTML(url)
            let cleaned = ArticleCleaner.clean(html: page.html, fallbackTitle: target.title)
            let nav = ChapterIndex.navigation(in: cleaned.document, pageURL: page.url)

            currentURL = page.url.absoluteString
            previousURL = nav.previous
            nextURL = nav.next
            tocURL = nav.toc
            title = cleaned.title
            bookName = cleaned.bookName
            plain = cleaned.plain
            content = cleaned.text

            var notes: [String] = []
            if chapters.isEmpty {
                var found = ChapterIndex.chapters(in: cleaned.document, pageURL: page.url)
                if found.count < 5, let toc = nav.toc, let tocPage = URL(string: toc) {
                    if let list = await fetchChapterList(tocPage), list.count >= 5 { found = list }
                }
                if found.count >= 4 {
                    chapters = found
                    notes.append("已抓到 \(found.count) 章目录")
                }
            }

            index = chapters.firstIndex(where: { ChapterIndex.samePage($0.url, currentURL) || ChapterIndex.samePage($0.url, target.url) }) ?? -1

            let weight = HTMLDocument.textWeight(content)
            let landing = index < 0 && chapters.count >= 4 && weight < 1200
            if !landing, index < 0, weight >= 400 {
                // 目录里没有这一章：把它补进目录，之后翻页就有据可依
                chapters.append(WebChapter(title: title, url: currentURL))
                index = chapters.count - 1
                notes.append("已补进目录")
            }

            status = notes.joined(separator: " · ")
            loading = false
            publishProgress()
            return landing ? .landing : .ok
        } catch {
            let message = "网页读取失败：\(error.localizedDescription)"
            self.error = message
            loading = false
            return .failed(message)
        }
    }

    private func fetchChapterList(_ url: URL) async -> [WebChapter]? {
        guard let page = try? await ArticleService.fetchHTML(url) else { return nil }
        let list = ChapterIndex.chapters(in: HTMLDocument(html: page.html), pageURL: page.url)
        return list.count >= 4 ? list : nil
    }

    @MainActor
    private func rescanTOC() async {
        status = "正在重新抓取目录…"
        var candidates: [URL] = []
        if let url = URL(string: currentURL) { candidates.append(url) }
        if let toc = tocURL, let url = URL(string: toc) { candidates.append(url) }
        for candidate in candidates {
            if let list = await fetchChapterList(candidate), list.count >= 4 {
                chapters = list
                if index < 0 || index >= list.count {
                    index = list.firstIndex(where: { ChapterIndex.samePage($0.url, currentURL) }) ?? -1
                }
                status = "已抓到 \(list.count) 章目录"
                publishProgress()
                return
            }
        }
        status = "没抓到目录（这个站点可能把目录放在需要 JavaScript 的页面里）"
    }

    @MainActor
    private func go(_ target: String?) {
        guard let target, let chapter = chapter(for: target) else { return }
        Task { await load(chapter) }
    }

    private func chapter(for urlString: String) -> WebChapter? {
        if let hit = chapters.first(where: { ChapterIndex.samePage($0.url, urlString) }) { return hit }
        return WebChapter(title: title, url: urlString)
    }

    @MainActor
    private func publishProgress() {
        guard let id = activeID, index >= 0, !content.isEmpty else { return }
        store.updateWebReading(id: id, index: index, chapters: chapters, text: content, title: title)
    }

    @MainActor
    private func save() {
        guard !content.isEmpty else { return }
        let name: String
        if let bookName, bookName.count >= 2 {
            name = bookName
        } else if let first = chapters.first {
            name = first.title
        } else {
            name = title
        }
        var book = ReadingBook(title: name,
                               author: URL(string: currentURL)?.host ?? "网页连载",
                               format: "网页连载",
                               content: content,
                               sourceURL: currentURL)
        book.webChapters = chapters.isEmpty ? nil : chapters
        book.webIndex = index >= 0 ? index : nil
        book.lastChapterTitle = title
        book.progress = chapters.isEmpty ? 0 : Double(index + 1) / Double(chapters.count)
        store.add(book)
        savedID = book.id
        status = "已加入书架，共 \(chapters.count) 章"
    }
}

struct InAppWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView { WKWebView(frame: .zero) }
    func updateUIView(_ view: WKWebView, context: Context) { if view.url != url { view.load(URLRequest(url: url)) } }
}
