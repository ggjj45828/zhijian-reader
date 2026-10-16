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

struct ArticleView: View {
    @EnvironmentObject private var store: LibraryStore
    let candidate: WebCandidate
    @State private var title = ""
    @State private var content = ""
    @State private var loading = true
    @State private var error: String?
    @State private var showWeb = false
    @State private var saved = false

    var body: some View {
        Group {
            if loading { ProgressView("正在用手机网络读取网页…") }
            else if content.count < 160 { VStack(spacing: 16) { ContentUnavailableView("正文提取不完整", systemImage: "doc.text.magnifyingglass", description: Text(error ?? "该网页可能使用动态脚本或限制访问。")); Button("在应用内打开原网页") { showWeb = true }.buttonStyle(.borderedProminent) }.padding() }
            else { ScrollView { VStack(alignment: .leading, spacing: 18) { Text(title).font(.system(size: 28, weight: .bold, design: .serif)); Text(candidate.url.host ?? candidate.engine).font(.caption).foregroundStyle(.secondary); Text(content).font(.system(size: store.fontSize, design: .serif)).lineSpacing(8).textSelection(.enabled) }.padding(22) }.background(store.theme.background) }
        }
        .foregroundStyle(store.theme.ink).background(store.theme.background.ignoresSafeArea())
        .navigationTitle("网页阅读").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(saved ? "已收藏" : "加入书架", systemImage: saved ? "checkmark" : "books.vertical") { saveBook() }.disabled(loading || content.count < 80) } }
        .sheet(isPresented: $showWeb) { InAppWebView(url: candidate.url).ignoresSafeArea() }
        .task { await load() }
    }
    // `load()` 是 async，不标 @MainActor 的话会在后台线程改 @State；
    // `saveBook()` 要调 `store.add`（@MainActor），同理。
    @MainActor private func load() async {
        do { let value = try await ArticleService.fetch(candidate.url); title = value.0; content = value.1; if content.count < 160 { error = "提取到的正文只有 \(content.count) 个字符。" } }
        catch { self.error = "网页读取失败：\(error.localizedDescription)" }
        loading = false
    }
    @MainActor private func saveBook() {
        store.add(ReadingBook(title: title.isEmpty ? candidate.title : title, author: candidate.url.host ?? candidate.engine, format: "网页正文", content: content, sourceURL: candidate.url.absoluteString))
        saved = true
    }
}

struct InAppWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView { WKWebView(frame: .zero) }
    func updateUIView(_ view: WKWebView, context: Context) { if view.url != url { view.load(URLRequest(url: url)) } }
}
