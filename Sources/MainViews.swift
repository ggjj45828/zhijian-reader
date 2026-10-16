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

    /// 网页连载的入口章：优先回到上次读到的下标，否则退回目录第一章。
    ///
    /// 这本书里的 `webChapters` 是「上次读到哪」的唯一依据 —— 目录抓全时由
    /// `LibraryStore.updateWebReading` 存下来，老版本存的 `library.json` 里没有这个
    /// 字段（解成 nil），此时只能退回 `sourceUrl` 当入口，让阅读页自己重新抓一次目录。
    @MainActor
    private func resumeChapter(for book: ReadingBook) -> WebChapter {
        let list = book.webChapters ?? []
        if let position = book.webIndex, position >= 0, position < list.count {
            return list[position]
        }
        if let first = list.first { return first }
        return WebChapter(title: book.lastChapterTitle ?? book.title, url: book.sourceURL ?? "")
    }

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
        .navigationDestination(for: ReadingBook.self) { book in
            if book.isWebSerial {
                // 网页连载：回到上次读到的那一章，目录与进度都在书里
                WebNovelReader(chapter: resumeChapter(for: book), bookID: book.id)
            } else {
                ReaderView(book: book)
            }
        }
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
    @State private var searching = false
    @State private var message: String?
    @State private var stage = ""
    @State private var verifiedDone = 0
    @State private var verifiedTotal = 0
    @State private var kept = 0
    @State private var failures: [String] = []
    @State private var hits: [String: Int] = [:]

    @MainActor private var activeSources: [SearchService.Source] {
        SearchService.sources(for: store.searchSources)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("书名、作者或章节", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit { runSearch() }
                Button { runSearch() } label: {
                    Image(systemName: "magnifyingglass").font(.headline).padding(12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal).padding(.top, 12)

            sourceRow
            pasteRow
            if searching || !stage.isEmpty { statusBlock }
            if !failures.isEmpty { failureBlock }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }

            if results.isEmpty {
                if searching {
                    Spacer()
                } else {
                    ContentUnavailableView("还没有结果", systemImage: "text.magnifyingglass",
                                           description: Text("会在 \(activeSources.count) 个搜索源里找有正文的页面。"))
                }
            } else {
                // 行内容就地展开，不抽成方法 —— 抽出去就变成 `body` 之外的成员，
                // 读 `store.theme.tint` 会撞上主线程隔离检查。
                List(results) { candidate in
                    NavigationLink {
                        WebNovelReader(chapter: WebChapter(title: candidate.title,
                                                           url: candidate.url.absoluteString))
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(candidate.title).font(.headline).lineLimit(2)
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(candidate.hasBody ? store.theme.tint : Color.secondary.opacity(0.4))
                                    .frame(width: 6, height: 6)
                                Text(subtitle(candidate)).font(.caption2)
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            if !candidate.snippet.isEmpty {
                                Text(candidate.snippet).font(.caption)
                                    .foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(store.theme.background.ignoresSafeArea())
        .navigationTitle("发现与搜索")
    }

    // MARK: - 搜索源

    @MainActor
    private var sourceRow: some View {
        HStack(spacing: 10) {
            Menu {
                Button("全选 \(SearchService.allSources.count) 个源") { store.searchSources = [] }
                Button("只留国内引擎 \(SearchService.domesticCount) 个") {
                    store.searchSources = SearchService.allSources.filter { !$0.overseas }.map(\.title)
                }
                Button("只留开放书源") {
                    let kinds: Set<String> = ["wikisource", "catalogue", "archive"]
                    store.searchSources = SearchService.allSources.filter { kinds.contains($0.kind.rawValue) }.map(\.title)
                }
                Divider()
                ForEach(SearchService.allSources) { source in
                    Button { toggle(source) } label: {
                        Label(source.title + (source.overseas ? "（海外）" : ""),
                              systemImage: isEnabled(source) ? "checkmark.circle.fill" : "circle")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text("搜索源 \(activeSources.count)/\(SearchService.allSources.count)")
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(store.theme.tint.opacity(0.12), in: Capsule())
            }

            Spacer(minLength: 0)

            Toggle(isOn: $store.verifySearchBody) {
                Text("只显示有正文的").font(.footnote)
            }
            .toggleStyle(.switch)
        }
        .padding(.horizontal)
    }

    @MainActor
    private func isEnabled(_ source: SearchService.Source) -> Bool {
        if store.searchSources.isEmpty { return true }
        return store.searchSources.contains(source.title)
    }

    @MainActor
    private func toggle(_ source: SearchService.Source) {
        var current = store.searchSources
        if current.isEmpty { current = SearchService.allSources.map(\.title) }
        if let index = current.firstIndex(of: source.title) {
            current.remove(at: index)
        } else {
            current.append(source.title)
        }
        store.searchSources = current
    }

    // MARK: - 粘贴链接

    private var pasteRow: some View {
        HStack {
            TextField("也可以粘贴公开章节链接", text: $pastedURL)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            NavigationLink {
                if let url = URL(string: pastedURL) {
                    WebNovelReader(chapter: WebChapter(title: url.host ?? "网页正文", url: url.absoluteString))
                } else {
                    ContentUnavailableView("链接无效", systemImage: "link.badge.plus")
                }
            } label: {
                Image(systemName: "arrow.down.doc").padding(10)
            }
            .buttonStyle(.bordered)
            .disabled(URL(string: pastedURL)?.scheme == nil)
        }
        .padding(.horizontal)
    }

    // MARK: - 状态

    @MainActor
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            if searching, verifiedTotal > 0 {
                ProgressView(value: Double(verifiedDone), total: Double(max(1, verifiedTotal)))
                    .tint(store.theme.tint)
            } else if searching {
                ProgressView().tint(store.theme.tint)
            }
            Text(stage).font(.caption).foregroundStyle(.secondary)
            if !sourceSummary.isEmpty {
                Text(sourceSummary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    @MainActor
    private var sourceSummary: String {
        if hits.isEmpty { return "" }
        let sorted = hits.sorted { $0.value > $1.value }
        let head = Array(sorted.prefix(5))
        var parts: [String] = []
        for pair in head { parts.append("\(pair.key) \(pair.value) 条") }
        var text = "命中：" + parts.joined(separator: " · ")
        if sorted.count > head.count { text += " · 等 \(sorted.count) 个源" }
        return text
    }

    @MainActor
    private var failureBlock: some View {
        let head = Array(failures.prefix(6))
        var text = "没连上：" + head.joined(separator: " · ")
        if failures.count > head.count { text += " 等 \(failures.count) 个源" }
        return Text(text)
            .font(.caption2).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
    }

    /// 只做字符串拼接，不碰 `store`，所以可以安全地写成 `body` 之外的成员。
    private func subtitle(_ candidate: WebCandidate) -> String {
        var parts: [String] = []
        if candidate.hasBody {
            parts.append("约 \(candidate.approxCharacters) 字")
        } else {
            parts.append("未校验")
        }
        parts.append(candidate.engine)
        if !candidate.site.isEmpty { parts.append(candidate.site) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 搜索

    @MainActor
    private func runSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let sources = activeSources
        let checkBody = store.verifySearchBody

        searching = true
        message = nil
        failures = []
        hits = [:]
        results = []
        stage = "正在向 \(sources.count) 个搜索源提问…"
        verifiedDone = 0
        verifiedTotal = 0
        kept = 0

        Task {
            let stream = SearchService.search(text, sources: sources, verifyBody: checkBody)
            for await event in stream {
                apply(event)
            }
            searching = false
            if results.isEmpty {
                message = checkBody
                    ? "这 \(sources.count) 个源都没找到能抽出正文的页面。可以关掉「只显示有正文的」先看看原始结果，或者换成更精确的书名。"
                    : "没有取到候选结果。可能是网络访问不了这些搜索源，或搜索网站限制了请求。你仍可以粘贴已知章节链接。"
            }
        }
    }

    @MainActor
    private func apply(_ event: SearchService.Event) {
        switch event {
        case .stage(let text):
            stage = text
        case .source(let title, let count, let error):
            if let error {
                failures.append("\(title)（\(error)）")
            } else if count > 0 {
                hits[title] = count
            }
        case .found(let candidate):
            results.append(candidate)
        case .progress(let finished, let all, let alive):
            verifiedDone = finished
            verifiedTotal = all
            kept = alive
        case .done(let scanned, let alive, let failed):
            verifiedDone = max(verifiedTotal, scanned)
            kept = alive
            if scanned > 0 {
                stage = "扫了 \(scanned) 条链接，留下 \(alive) 条有正文的"
            }
            if failed > 0 { stage += "；\(failed) 个源没连上" }
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
