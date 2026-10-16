import SwiftUI
import UniformTypeIdentifiers

struct RootTabView: View {
    var body: some View {
        TabView {
            NavigationStack { BookshelfView() }.tabItem { Label("书架", systemImage: "books.vertical") }
            NavigationStack { DiscoverView() }.tabItem { Label("发现", systemImage: "magnifyingglass") }
            NavigationStack { ReadingStatsView() }.tabItem { Label("统计", systemImage: "chart.bar") }
            NavigationStack { SettingsView() }.tabItem { Label("设置", systemImage: "slider.horizontal.3") }
        }
    }
}

struct BookshelfView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var showingImporter = false
    @State private var searchText = ""
    @State private var activeShelf = "全部"
    @State private var alertMessage: String?

    // 这两个计算属性不在 `body` 里，读的是 `store.books`（LibraryStore 是 @MainActor），
    // 必须显式标 @MainActor 才能通过隔离检查。
    @MainActor private var shelves: [String] { ["全部"] + Array(Set(store.books.map(\.shelf))).filter { $0 != "全部书籍" }.sorted() }
    @MainActor private var filtered: [ReadingBook] {
        store.books.filter { (activeShelf == "全部" || $0.shelf == activeShelf || (activeShelf == "全部" && $0.shelf == "全部书籍")) && (searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) || $0.author.localizedCaseInsensitiveContains(searchText)) }
    }

    /// `.allowedContentTypes` 会在 `body` 求值时**立刻**构造，所以任何一个
    /// `UTType(filenameExtension:)!` 拿到 nil 都会在打开书架那一刻崩掉。
    /// `epub` / `fb2` / `markdown` 在 iOS 上并不是系统预声明的类型，原来的
    /// 5 处强制解包有实际崩溃风险。这里逐个安全降级，最后兜一个 `.data`，
    /// 让不认识的扩展名也能被选中，再由 `importFile` 给出「格式不支持」的提示。
    private static let importableTypes: [UTType] = {
        var types: [UTType] = [.plainText, .pdf, .html, .rtf]
        for ext in ["md", "markdown", "epub", "fb2", "docx"] {
            if let type = UTType(filenameExtension: ext, conformingTo: .data) { types.append(type) }
        }
        types.append(.data)
        return types
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 4) { Text("纸间").font(.largeTitle.bold()); Text("你的私人阅读空间").foregroundStyle(.secondary) }; Spacer(); Button { showingImporter = true } label: { Image(systemName: "plus").font(.title3.bold()).padding(12).background(store.theme.tint.opacity(0.14), in: Circle()) } }
                .padding(.horizontal).padding(.top, 10)
            HStack { Image(systemName: "magnifyingglass"); TextField("搜索书名或作者", text: $searchText).textInputAutocapitalization(.never) }
                .padding(12).background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14)).padding()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack { ForEach(shelves, id: \.self) { shelf in Button(shelf) { activeShelf = shelf }.font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 9).background(activeShelf == shelf ? store.theme.tint : Color.secondary.opacity(0.12), in: Capsule()).foregroundStyle(activeShelf == shelf ? store.theme.background : .primary) } }.padding(.horizontal)
            }.padding(.bottom, 8)
            if let current = store.books.filter({ $0.progress > 0 && $0.progress < 1 }).max(by: { ($0.lastReadAt ?? .distantPast) < ($1.lastReadAt ?? .distantPast) }) {
                NavigationLink(value: current) { HStack { Image(systemName: "book.closed.fill").font(.title2).padding(13).background(store.theme.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 13)); VStack(alignment: .leading) { Text("继续阅读").font(.caption).foregroundStyle(.secondary); Text(current.title).font(.headline).lineLimit(1); ProgressView(value: current.progress).tint(store.theme.tint) }; Spacer(); Text("\(Int(current.progress * 100))%").font(.caption.monospacedDigit()) }.padding().background(store.theme.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 18)) }.buttonStyle(.plain).padding(.horizontal).padding(.bottom, 8)
            }
            if filtered.isEmpty { ContentUnavailableView(store.books.isEmpty ? "书架还空着" : "没有匹配的书", systemImage: "books.vertical", description: Text("导入 TXT、Markdown、HTML、PDF、EPUB、FB2、DOCX 或 RTF，开始阅读。")) }
            else {
                List {
                    ForEach(filtered) { book in
                        NavigationLink(value: book) {
                            HStack(spacing: 13) {
                                RoundedRectangle(cornerRadius: 8).fill(store.theme.tint.opacity(0.2)).frame(width: 50, height: 68).overlay(Text(String(book.title.prefix(1))).font(.title2.bold()).foregroundStyle(store.theme.tint))
                                VStack(alignment: .leading, spacing: 5) { Text(book.title).font(.headline).lineLimit(2); Text("\(book.author) · \(book.format)").font(.caption).foregroundStyle(.secondary); ProgressView(value: book.progress).tint(store.theme.tint) }
                                Spacer(minLength: 0)
                            }.padding(.vertical, 3)
                        }
                        .swipeActions { Button("删除", role: .destructive) { store.delete(book) } }
                    }
                }.listStyle(.plain)
            }
        }
        .background(store.theme.background.ignoresSafeArea())
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ReadingBook.self) { ReaderView(book: $0) }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: Self.importableTypes, allowsMultipleSelection: true) { result in
            do { for url in try result.get() { store.add(try store.importFile(url)) } }
            catch { alertMessage = error.localizedDescription }
        }
        .alert("导入没有完成", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) { Button("好", role: .cancel) {} } message: { Text(alertMessage ?? "") }
    }
}

struct DiscoverView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var query = ""
    @State private var pastedURL = ""
    @State private var results: [WebCandidate] = []
    @State private var errors: [String] = []
    @State private var searching = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) { TextField("书名、作者或章节", text: $query).textFieldStyle(.roundedBorder).submitLabel(.search).onSubmit { runSearch() }; Button { runSearch() } label: { Image(systemName: "magnifyingglass").font(.headline).padding(12) }.buttonStyle(.borderedProminent).disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty) }
                .padding(.horizontal).padding(.top, 12)
            Text("通过 iPhone 当前网络并行查询百度和必应。阅读器在本机提取网页，不需要 NAS 搜索服务。")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            HStack { TextField("也可以粘贴公开章节链接", text: $pastedURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder); NavigationLink { if let url = URL(string: pastedURL) { ArticleView(candidate: WebCandidate(title: url.host ?? "网页正文", url: url, snippet: "", engine: "手动链接")) } else { ContentUnavailableView("链接无效", systemImage: "link.badge.plus") } } label: { Image(systemName: "arrow.down.doc").padding(10) }.buttonStyle(.bordered).disabled(URL(string: pastedURL)?.scheme == nil) }.padding(.horizontal)
            if searching { ProgressView("正在查询，最长约 9 秒…").padding() }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
            if !errors.isEmpty { Text(errors.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal) }
            List(results) { candidate in
                NavigationLink { ArticleView(candidate: candidate) } label: {
                    VStack(alignment: .leading, spacing: 5) { Text(candidate.title).font(.headline).lineLimit(2); Text(candidate.snippet.isEmpty ? candidate.url.host ?? "网页来源" : candidate.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(3); Text("\(candidate.engine) · \(candidate.url.host ?? "")").font(.caption2).foregroundStyle(store.theme.tint) }
                        .padding(.vertical, 5)
                }
            }.listStyle(.plain)
        }
        .background(store.theme.background.ignoresSafeArea())
        .navigationTitle("发现与搜索")
    }

    @MainActor
    private func runSearch() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searching = true; message = nil; errors = []; results = []
        Task {
            let (items, failures) = await SearchService.search(query)
            results = items; errors = failures; searching = false
            message = items.isEmpty ? "没有取到候选结果。可能是当前网络无法访问搜索源，或搜索网站限制了请求。你仍可以粘贴已知章节链接在下一阶段直接阅读。" : "找到 \(items.count) 个网页候选；点开后在应用内提取正文。"
        }
    }
}

struct ReadingStatsView: View {
    @EnvironmentObject private var store: LibraryStore
    @MainActor private var week: [(String, Int)] { (0..<7).reversed().map { offset in let d = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!; return (Self.label(d), store.minutesByDay[LibraryStore.dayKey(d)] ?? 0) } }
    var body: some View {
        List {
            Section("今天") { HStack { Label("阅读时长", systemImage: "clock"); Spacer(); Text("\(store.todayMinutes) 分钟").bold() }; ProgressView(value: Double(store.todayMinutes), total: Double(max(store.dailyGoal, 1))).tint(store.theme.tint); Text("目标 \(store.dailyGoal) 分钟").font(.caption).foregroundStyle(.secondary) }
            Section("最近 7 天") { ForEach(week.indices, id: \.self) { index in let (day, minutes) = week[index]; HStack { Text(day).frame(width: 48, alignment: .leading); ProgressView(value: Double(minutes), total: Double(max(week.map { $0.1 }.max() ?? 1, 1))).tint(store.theme.tint); Text("\(minutes) 分").font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing) } } }
            Section("书库") { Label("\(store.books.count) 本书", systemImage: "books.vertical"); Label("\(store.books.reduce(0) { $0 + $1.wordCount }) 字", systemImage: "text.alignleft"); Label("\(store.books.reduce(0) { $0 + $1.bookmarks.count }) 个书签 · \(store.books.reduce(0) { $0 + $1.notes.count }) 条笔记", systemImage: "bookmark") }
        }.scrollContentBackground(.hidden).background(store.theme.background).navigationTitle("阅读统计")
    }
    private static func label(_ date: Date) -> String { let f = DateFormatter(); f.dateFormat = "E"; return f.string(from: date) }
}
