import Foundation
import Observation
import UIKit

@MainActor @Observable
final class MangaPageImageModel {
    private(set) var image: UIImage?
    private(set) var resourceKey: String?
    private(set) var failure = false
    @ObservationIgnored private var request = UUID()
    private let cache: MangaPageCache
    init(cache: MangaPageCache = .shared) { self.cache = cache }

    /// Returns true only when this request still owns the visible image.
    func load(_ resource: MangaPageResource) async -> Bool {
        guard !Task.isCancelled else { return false }
        if resourceKey == resource.key, image != nil { return true }
        let token = UUID(); request = token
        resourceKey = resource.key; image = nil; failure = false
        do {
            let data = try await cache.data(for: resource)
            guard !Task.isCancelled, request == token else { return false }
            guard let decoded = UIImage(data: data) else {
                failure = true
                await cache.invalidate(resource)
                return false
            }
            image = decoded
            return true
        } catch {
            if !Task.isCancelled && request == token { failure = true }
            return false
        }
    }
    func cancel(keepingImage: Bool) {
        request = UUID()
        if !keepingImage { image = nil; resourceKey = nil; failure = false }
    }
}
