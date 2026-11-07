import SwiftUI

/// 控制远程封面并发下载数量，避免瀑布流或网格滑动时瞬间发起过多请求。
private actor ImageFetchLimiter {
    static let shared = ImageFetchLimiter(maximumConcurrent: 6)
    private let maximumConcurrent: Int
    private var active = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var inFlight: [String: Task<Data, Error>] = [:]

    init(maximumConcurrent: Int) {
        self.maximumConcurrent = maximumConcurrent
    }

    func fetch(url: URL) async throws -> Data {
        let key = url.absoluteString
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task<Data, Error> {
            try await acquire()
            defer { release() }
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let host = url.host?.lowercased() ?? ""
            if host.contains("zlib") || host.contains("z-lib") || host.contains("1lib") {
                request.setValue("https://z-lib.sk/", forHTTPHeaderField: "Referer")
            } else {
                request.setValue("https://www.wenku8.net/", forHTTPHeaderField: "Referer")
            }
            let (data, response) = try await FanhuaNetwork.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count > 64,
                  data.count < 8_000_000 else {
                throw URLError(.badServerResponse)
            }
            return data
        }
        inFlight[key] = task
        defer { inFlight.removeValue(forKey: key) }
        return try await task.value
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if active < maximumConcurrent {
            active += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    private func release() {
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume()
            return
        }
        active = max(0, active - 1)
    }
}

/// 图片单独请求，附带来源页与并发上限；内存缓存与 FanhuaCache 避免重复下载。
struct WenkuRemoteImage: View {
    let url: URL
    @State private var image: UIImage?
    private static let cache: NSCache<NSURL, UIImage> = {
        let value = NSCache<NSURL, UIImage>()
        value.totalCostLimit = 24_000_000
        value.countLimit = 140
        return value
    }()
    static func clearMemory() { cache.removeAllObjects() }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            if let saved = Self.cache.object(forKey: url as NSURL) {
                image = saved
                return
            }
            if let data = await FanhuaCache.shared.data(for: url.absoluteString),
               let decoded = UIImage(data: data) {
                Self.cache.setObject(decoded, forKey: url as NSURL, cost: Int(decoded.size.width * decoded.size.height * 4))
                image = decoded
                return
            }
            do {
                let data = try await ImageFetchLimiter.shared.fetch(url: url)
                guard let decoded = UIImage(data: data) else { return }
                Self.cache.setObject(decoded, forKey: url as NSURL, cost: Int(decoded.size.width * decoded.size.height * 4))
                await FanhuaCache.shared.store(data, for: url.absoluteString)
                if !Task.isCancelled { image = decoded }
            } catch {
                // 封面加载失败保持默认纸质书封回退
            }
        }
    }
}
