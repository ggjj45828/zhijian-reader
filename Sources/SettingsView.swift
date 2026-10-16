import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @AppStorage("nas.reader.url") private var nasURL = ""
    @State private var status = ""
    @State private var syncing = false

    var body: some View {
        Form {
            Section("阅读外观") {
                Picker("主题", selection: $store.theme) { ForEach(ReaderTheme.allCases) { theme in Text(theme.title).tag(theme) } }
                VStack(alignment: .leading) { HStack { Text("正文大小"); Spacer(); Text("\(Int(store.fontSize)) pt").foregroundStyle(.secondary) }; Slider(value: $store.fontSize, in: 15...30, step: 1) }
            }
            Section("阅读目标") {
                Stepper("每天 \(store.dailyGoal) 分钟", value: $store.dailyGoal, in: 5...240, step: 5)
                Text("今天已读 \(store.todayMinutes) 分钟。统计与书籍保存在 iPhone 本机。") .font(.caption).foregroundStyle(.secondary)
            }
            Section("NAS 可选上传") {
                TextField("NAS 阅读器地址，例如 https://…", text: $nasURL).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                Button { Task { await uploadToNAS() } } label: { if syncing { ProgressView("正在合并并上传…") } else { Label("合并上传书库", systemImage: "icloud.and.arrow.up") } }.disabled(syncing || store.books.isEmpty || nasURL.isEmpty)
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                Text("上传前会读取 NAS 当前书库并合并，避免覆盖 NAS 上已有书籍。请使用极空间远程访问或私有 HTTPS 地址；当前 NAS 接口没有登录认证，不要公开暴露。手机搜索和阅读网页不依赖 NAS。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("数据与支持") {
                NavigationLink("书签与笔记", destination: NotesView())
                LabeledContent("本机书籍", value: "\(store.books.count) 本")
                LabeledContent("文件", value: "TXT、MD、HTML、PDF、EPUB、FB2、DOCX、RTF")
                Text("纸间原生 iPhone · 开发版").font(.caption).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden).background(store.theme.background).navigationTitle("设置")
    }

    @MainActor private func uploadToNAS() async {
        guard var base = URL(string: nasURL.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(base.scheme?.lowercased() ?? "") else { status = "请输入有效的 http 或 https 地址。"; return }
        syncing = true; defer { syncing = false }
        base.append(path: "api/books")
        do {
            var get = URLRequest(url: base); get.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: get)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SyncIssue.server }
            let existing = object["books"] as? [[String: Any]] ?? []
            let localData = try JSONEncoder.pretty.encode(store.books)
            let local = try JSONSerialization.jsonObject(with: localData) as? [[String: Any]] ?? []
            var merged = existing
            var ids = Set(existing.compactMap { $0["id"] as? String })
            for book in local { if let id = book["id"] as? String, ids.insert(id).inserted { merged.append(book) } }
            var put = URLRequest(url: base); put.httpMethod = "PUT"; put.timeoutInterval = 30
            put.setValue("application/json", forHTTPHeaderField: "Content-Type")
            put.httpBody = try JSONSerialization.data(withJSONObject: ["books": merged])
            let (_, putResponse) = try await URLSession.shared.data(for: put)
            guard (putResponse as? HTTPURLResponse)?.statusCode == 200 else { throw SyncIssue.server }
            status = "完成：合并后 NAS 共有 \(merged.count) 本书。"
        } catch { status = "上传失败：\(error.localizedDescription)" }
    }
}

enum SyncIssue: LocalizedError { case server; var errorDescription: String? { "NAS 服务没有返回成功结果，请检查地址与 reader 容器状态。" } }

struct NotesView: View {
    @EnvironmentObject private var store: LibraryStore
    // 同上：不在 body 里，读的是 @MainActor 的 store.books，必须显式标 @MainActor。
    @MainActor private var rows: [(ReadingBook, ReaderNote)] { store.books.flatMap { book in book.notes.map { (book, $0) } }.sorted { $0.1.createdAt > $1.1.createdAt } }
    @MainActor private var marks: [(ReadingBook, ReaderBookmark)] { store.books.flatMap { book in book.bookmarks.map { (book, $0) } }.sorted { $0.1.createdAt > $1.1.createdAt } }
    var body: some View {
        List {
            Section("书签 · \(marks.count)") {
                if marks.isEmpty { Text("阅读时点右上角 ··· 添加书签").foregroundStyle(.secondary) }
                ForEach(marks.indices, id: \.self) { index in let (book, mark) = marks[index]; HStack { Image(systemName: "bookmark.fill").foregroundStyle(store.theme.tint); VStack(alignment: .leading) { Text(book.title).font(.headline); Text(mark.title).font(.caption).foregroundStyle(.secondary) } } }
            }
            Section("笔记 · \(rows.count)") {
                if rows.isEmpty { Text("阅读时点右上角 ··· 写读书笔记").foregroundStyle(.secondary) }
                ForEach(rows.indices, id: \.self) { index in let (book, note) = rows[index]; VStack(alignment: .leading, spacing: 6) { Text(book.title).font(.headline); Text(note.text); if !note.quote.isEmpty { Text("“\(note.quote)”").font(.caption).foregroundStyle(.secondary).lineLimit(3) } } }
            }
        }.scrollContentBackground(.hidden).background(store.theme.background).navigationTitle("书签与笔记")
    }
}
