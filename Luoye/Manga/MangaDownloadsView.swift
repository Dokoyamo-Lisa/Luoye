import SwiftUI

struct MangaDownloadJob: Codable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case queued, running, pausing, paused, failed, completed
        var title: String {
            switch self {
            case .queued: "等待下载"
            case .running: "正在下载"
            case .pausing: "正在暂停…"
            case .paused: "已暂停"
            case .failed: "下载失败"
            case .completed: "已保存到书斋"
            }
        }
    }
    let id: UUID
    let comic: MangaOnlineComic
    let chapter: MangaOnlineChapter
    var status = Status.paused
    var completed = 0
    var total = 0
    var error: String?
}

struct MangaDownloadsView: View {
    @Environment(MangaLibrary.self) private var library
    @State private var openedComic: MangaComic?
    @State private var missingJob: MangaDownloadJob?

    var body: some View {
        Group {
            if library.downloads.isEmpty {
                LuoyeEmptyState(icon: "arrow.down.circle", title: "暂无下载任务", message: "在漫画目录中点击下载，即可离线阅读。")
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(library.downloads) { job in
                        LuoyePanel {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(job.comic.title).font(.serif(15, medium: true))
                                Text(job.chapter.title).font(.serif(12)).foregroundStyle(.secondary)
                                ProgressView(value: Double(min(job.completed, max(job.total, 1))), total: Double(max(job.total, 1)))
                                HStack(alignment: .center, spacing: 14) {
                                    Text("\(job.status.title) · \(job.completed) / \(job.total) 页")
                                        .font(.serif(11)).foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                    if job.status == .running || job.status == .queued {
                                        Button("暂停") { library.pauseDownload(job.id) }.frame(minHeight: 44)
                                    } else if job.status == .completed {
                                        if let comic = library.savedDownload(job.id) {
                                            Button("阅读") {
                                                if FileManager.default.fileExists(atPath: comic.fileURL.path) { openedComic = comic }
                                                else { missingJob = job }
                                            }.frame(minHeight: 44)
                                        } else {
                                            Button("重新下载") { library.enqueueDownload(job.chapter, of: job.comic) }.frame(minHeight: 44)
                                        }
                                    } else if job.status != .pausing {
                                        Button(job.status == .failed ? "重试" : "继续") { library.resumeDownload(job.id) }.frame(minHeight: 44)
                                    }
                                    if job.status != .running && job.status != .pausing {
                                        Button("移除", role: .destructive) { library.removeDownload(job.id) }.frame(minHeight: 44)
                                    }
                                }
                                .font(.serif(12)).buttonStyle(.borderless)
                                if let error = job.error { Text(error).font(.serif(11)).foregroundStyle(.secondary) }
                            }.padding(17)
                        }
                    }
                }
            }
        }
        .tint(Color.accent)
        .fullScreenCover(item: $openedComic) { ComicReaderView(comic: $0) }
        .alert("离线文件已丢失", isPresented: Binding(get: { missingJob != nil }, set: { if !$0 { missingJob = nil } }), presenting: missingJob) { job in
            Button("重新下载") { library.enqueueDownload(job.chapter, of: job.comic) }
            Button("取消", role: .cancel) { }
        } message: { _ in Text("可以重新下载这一话，阅读进度会保留。") }
    }
}
