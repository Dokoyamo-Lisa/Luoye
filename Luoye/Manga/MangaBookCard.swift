import SwiftUI

struct MangaBookCover: View {
    let comic: MangaOnlineComic
    var body: some View {
        GeometryReader { proxy in
            MangaCoverImage(comic: comic)
                .frame(width: proxy.size.width, height: proxy.size.height).clipped()
        }
        .aspectRatio(0.69, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.ink.opacity(0.08), lineWidth: 0.5) }
        .shadow(color: Color.ink.opacity(0.08), radius: 5, y: 3)
    }
}

struct MangaLocalCover: View {
    let comic: MangaComic
    var body: some View {
        GeometryReader { proxy in
            Group {
                if let url = comic.coverURL, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.accent.opacity(0.08))
                        .overlay { Image(systemName: "photo.on.rectangle.angled").font(.system(size: 24, weight: .ultraLight)).foregroundStyle(.tint) }
                }
            }.frame(width: proxy.size.width, height: proxy.size.height).clipped()
        }
        .aspectRatio(0.69, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.ink.opacity(0.08), lineWidth: 0.5) }
        .shadow(color: Color.ink.opacity(0.08), radius: 5, y: 3)
    }
}

struct MangaBookGrid: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(MangaSourceStore.self) private var sources
    @Environment(MangaLibrary.self) private var library
    let comics: [MangaOnlineComic]
    var history = false
    var body: some View {
        let metrics = ShelfMetrics.of(sizeClass)
        LazyVGrid(columns: metrics.columns, alignment: .leading, spacing: metrics.rowGap) {
            ForEach(comics, id: \.identity) { comic in
                NavigationLink {
                    if let source = sources.source(for: comic.source) { MangaOnlineDetailView(comic: comic, source: source) }
                    else { LuoyeEmptyState(icon: "network", title: "漫画源未启用", message: "请在我的 → 漫画源管理中启用对应漫画源。") }
                } label: {
                    ShelfTile(title: comic.title, author: sources.sources.first { $0.key == comic.source }?.name ?? "MangaDex", large: sizeClass == .regular) {
                        MangaBookCover(comic: comic)
                    }
                }.buttonStyle(PressStyle())
                    .contextMenu {
                        Button(library.isFavorite(comic) ? "取消收藏" : "收藏", systemImage: "heart") { library.toggleFavorite(comic) }
                        Button(library.isReadLater(comic) ? "移出稍后阅读" : "稍后阅读", systemImage: "bookmark") { library.toggleReadLater(comic) }
                        if history { Button("移除浏览记录", systemImage: "clock.badge.xmark", role: .destructive) { library.removeRecent(comic) } }
                    }
            }
        }
    }
}
