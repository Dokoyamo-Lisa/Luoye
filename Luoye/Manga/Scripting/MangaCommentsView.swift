import SwiftUI
import SwiftSoup

struct MangaSourceComment: Identifiable {
    let id: String
    let serverID: String?
    let user: String
    let text: String
    let time: String
    let avatar: URL?
    let replies: Int?
}

struct MangaCommentsView: View {
    let comic: MangaOnlineComic
    let source: MangaScriptSource
    var subID: String? = nil
    var chapterID: String? = nil
    var replyTo: String? = nil
    @State private var comments: [MangaSourceComment] = []
    @State private var page = 1
    @State private var ended = false
    @State private var loading = false
    @State private var sending = false
    @State private var canSend = false
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error { Text(error).font(.serif(12)).foregroundStyle(.secondary) }
                if canSend {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $draft).frame(minHeight: 90).font(.serif(14))
                            .scrollContentBackground(.hidden)
                            .padding(8).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        Button(sending ? "正在发送…" : (replyTo == nil ? "发送评论" : "发送回复")) { Task { await send() } }
                            .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(comments) { comment in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 10) {
                                if let avatar = comment.avatar {
                                    AsyncImage(url: avatar) { image in image.resizable().scaledToFill() }
                                    placeholder: { Color.accentColor.opacity(0.1) }
                                    .frame(width: 30, height: 30).clipShape(Circle())
                                }
                                Text(comment.user).font(.serif(13, medium: true))
                                Spacer()
                                Text(comment.time).font(.serif(10)).foregroundStyle(.secondary)
                            }
                            Text(comment.text).font(.serif(14)).textSelection(.enabled)
                            if let id = comment.serverID, let count = comment.replies {
                                NavigationLink("回复 · \(count)") {
                                    MangaCommentsView(comic: comic, source: source, subID: subID, chapterID: chapterID, replyTo: id)
                                }.font(.serif(12))
                            }
                            Divider()
                        }
                    }
                }
                if loading { ProgressView() }
                else if !ended { Button(comments.isEmpty ? "重试" : "加载更多评论") { Task { await load() } } }
                if comments.isEmpty && !loading && error == nil { Text("暂无评论").font(.serif(14)).foregroundStyle(.secondary) }
            }.luoyeContentMargins(top: 16)
        }
        .background(Color.paper)
        .navigationTitle(replyTo == nil ? "评论" : "回复").navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let metadata = try JSONSerialization.jsonObject(with: await source.runtime.metadata()) as? [String: Any] ?? [:]
                canSend = metadata[chapterID == nil ? "sendComments" : "sendChapterComments"] as? Bool ?? false
            } catch { self.error = error.localizedDescription }
            await load()
        }
        .refreshable { await load(reset: true) }
    }

    private func load(reset: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let requested = reset ? 1 : page
            let data = try await source.runtime.call("__comments", arguments: [comic.id, subID as Any? ?? NSNull(), chapterID as Any? ?? NSNull(), requested, replyTo as Any? ?? NSNull()])
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let values = object["comments"] as? [[String: Any]] ?? []
            let next = values.enumerated().map { index, value in
                let serverID = value["id"].flatMap { $0 is NSNull ? nil : String(describing: $0) }
                let html = value["content"] as? String ?? ""
                let text = (try? SwiftSoup.parse(html).text()) ?? html
                return MangaSourceComment(id: serverID ?? "\(requested):\(index)", serverID: serverID, user: value["userName"] as? String ?? "读者", text: text,
                                          time: value["time"].map { $0 is NSNull ? "" : String(describing: $0) } ?? "", avatar: (value["avatar"] as? String).flatMap(URL.init(string:)), replies: value["replyCount"] as? Int)
            }
            if reset { comments = next }
            else { let ids = Set(comments.map(\.id)); comments += next.filter { !ids.contains($0.id) } }
            page = requested + 1
            ended = values.isEmpty || requested >= (object["maxPage"] as? Int ?? Int.max)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func send() async {
        sending = true
        defer { sending = false }
        do {
            _ = try await source.runtime.call("__sendComment", arguments: [comic.id, subID as Any? ?? NSNull(), chapterID as Any? ?? NSNull(), draft, replyTo as Any? ?? NSNull()])
            draft = ""
            await load(reset: true)
        } catch { self.error = error.localizedDescription }
    }
}

struct MangaRatingView: View {
    @Environment(\.dismiss) private var dismiss
    let comic: MangaOnlineComic
    let source: MangaScriptSource
    @State private var rating = 8.0
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Form {
                Section(comic.title) {
                    Text("\(Int(rating)) / 10").font(.serif(22, medium: true))
                    Slider(value: $rating, in: 1...10, step: 1)
                    Button("提交评分") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                _ = try await source.runtime.call("comic.starRating", arguments: [comic.id, Int(rating)])
                                message = "评分已提交"
                            } catch { message = error.localizedDescription }
                        }
                    }.disabled(busy)
                }
                if let message { Text(message).font(.serif(13)) }
            }
            .scrollContentBackground(.hidden).background(Color.paper)
            .navigationTitle("漫画评分").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
