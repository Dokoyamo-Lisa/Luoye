import Foundation

/// URLSession keeps source-specific headers during redirects; credentials belong to one origin.
final class MangaSourceRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func redirected(_ request: URLRequest, from original: URL?) -> URLRequest {
        var next = request
        func origin(_ url: URL?) -> String {
            guard let url else { return "" }
            return "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
        }
        if origin(original) != origin(request.url) {
            for name in ["Authorization", "Proxy-Authorization", "Cookie"] { next.setValue(nil, forHTTPHeaderField: name) }
        }
        return next
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.redirected(request, from: response.url))
    }
}
