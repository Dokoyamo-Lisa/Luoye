import Foundation

enum MangaPageResource: Hashable, Sendable {
    case local(URL, String, Int, revision: UUID?)
    case remote(MangaImageRequest)

    var key: String {
        switch self {
        case .local(let url, let format, let index, let revision):
            return ["local", url.path, format, String(index), revision?.uuidString ?? ""].map { String($0.utf8.count) + ":" + $0 }.joined()
        case .remote(let request):
            let parts = ["remote", request.processor?.identifier.uuidString ?? "native", request.processingKey ?? "", request.url.absoluteString]
                + request.headers.keys.sorted().flatMap { [$0, request.headers[$0] ?? ""] }
            return parts.map { String($0.utf8.count) + ":" + $0 }.joined()
        }
    }
}

actor MangaPageCache {
    typealias Loader = @Sendable (MangaPageResource) async throws -> Data
    static let shared = MangaPageCache()
    private struct Flight {
        let id: UUID
        let task: Task<Data, Error>
        var subscribers: Set<UUID>
    }
    private var flights: [MangaPageResource: Flight] = [:]
    private let loader: Loader
    private let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()
    init(loader: Loader? = nil) {
        if let loader { self.loader = loader }
        else { self.loader = { resource in try await Self.loadResource(resource) } }
    }

    func data(for resource: MangaPageResource) async throws -> Data {
        try Task.checkCancellation()
        if let cached = cache.object(forKey: resource.key as NSString) { return cached as Data }
        let subscriber = UUID()
        var flight: Flight
        if let existing = flights[resource] { flight = existing }
        else {
            let loader = self.loader
            flight = Flight(id: UUID(), task: Task { try await loader(resource) }, subscribers: [])
        }
        flight.subscribers.insert(subscriber)
        flights[resource] = flight
        let id = flight.id, task = flight.task
        return try await withTaskCancellationHandler {
            do {
                let data = try await task.value
                guard !data.isEmpty else { throw ComicArchive.ArchiveError.noPages }
                if flights[resource]?.id == id {
                    cache.setObject(data as NSData, forKey: resource.key as NSString, cost: data.count)
                    flights[resource] = nil
                }
                try Task.checkCancellation()
                return data
            } catch {
                if flights[resource]?.id == id { flights[resource] = nil }
                throw error
            }
        } onCancel: {
            Task { await self.cancel(subscriber, for: resource, flightID: id) }
        }
    }
    private func cancel(_ subscriber: UUID, for resource: MangaPageResource, flightID: UUID) {
        guard var flight = flights[resource], flight.id == flightID else { return }
        flight.subscribers.remove(subscriber)
        if flight.subscribers.isEmpty { flight.task.cancel(); flights[resource] = nil }
        else { flights[resource] = flight }
    }

    /// Successful HTTP responses can still contain an error page rather than an image.
    func invalidate(_ resource: MangaPageResource) {
        cache.removeObject(forKey: resource.key as NSString)
    }

    private nonisolated static func loadResource(_ resource: MangaPageResource) async throws -> Data {
        let data: Data
        switch resource {
        case .local(let url, let format, let index, _):
            guard let value = try await Task.detached(priority: .userInitiated, operation: {
                try ComicArchive(fileURL: url, format: format).imageData(at: index)
            }).value else {
                throw ComicArchive.ArchiveError.noPages
            }
            data = value
        case .remote(let imageRequest):
            var request = URLRequest(url: imageRequest.url)
            request.allHTTPHeaderFields = imageRequest.headers
            request.timeoutInterval = 40
            let (value, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
            if let processor = imageRequest.processor, let key = imageRequest.processingKey { data = try await processor.processImage(value, key: key) }
            else { data = value }
        }
        return data
    }
    func prefetch(_ resources: [MangaPageResource]) async {
        await withTaskGroup(of: Void.self) { group in
            for resource in resources.prefix(4) {
                group.addTask { _ = try? await self.data(for: resource) }
            }
        }
    }
}
