import SwiftUI

struct MangaCoverImage: View {
    @Environment(MangaSourceStore.self) private var store
    let comic: MangaOnlineComic
    @State private var image: UIImage?
    @State private var loadedIdentity: CoverIdentity?
    private struct CoverIdentity: Hashable {
        let comic: MangaOnlineComic.Identity
        let url: URL?
    }
    private var identity: CoverIdentity { CoverIdentity(comic: comic.identity, url: comic.coverURL) }
    var body: some View {
        Group {
            if loadedIdentity == identity, let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Color.accent.opacity(0.1) }
        }
        .task(id: identity) {
            image = nil; loadedIdentity = nil
            let requestedIdentity = identity
            do {
                guard let url = comic.coverURL else { return }
                let request: MangaImageRequest
                if let script = store.source(for: comic.source) as? MangaScriptSource {
                    let data = try await script.runtime.call("__thumbnailRequest", arguments: [url.absoluteString, comic.id])
                    let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                    guard let raw = value["url"] as? String, let target = URL(string: raw.hasPrefix("//") ? "https:" + raw : raw) else { return }
                    request = MangaImageRequest(url: target, headers: value["headers"] as? [String: String] ?? [:], processor: script.runtime, processingKey: value["processingKey"] as? String)
                } else { request = MangaImageRequest(url: url) }
                let data = try await MangaPageCache.shared.data(for: .remote(request))
                if !Task.isCancelled {
                    image = UIImage(data: data)
                    loadedIdentity = requestedIdentity
                    if image == nil { await MangaPageCache.shared.invalidate(.remote(request)) }
                }
            } catch { }
        }
    }
}
