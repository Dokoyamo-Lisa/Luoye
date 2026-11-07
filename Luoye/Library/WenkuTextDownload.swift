import Foundation

/// 文库 TXT 获取层，与界面和 SwiftData 无关。
enum WenkuTextDownload {
    struct Download: Sendable { let data: Data; let title: String }
    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "文库暂未提供可用的 TXT 文件，或连接失败。请稍后重试。" }
    }
    static func fetch(aid: Int) async throws -> Download {
        guard aid > 0 else { throw Failure.unavailable }
        for host in ["dl1.wenku8.com", "dl2.wenku8.com"] {
            try Task.checkCancellation()
            let url = URL(string: "https://\(host)/down/txtutf8/\(aid / 1000)/\(aid).txt")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 25
            do {
                let (data, response) = try await FanhuaNetwork.session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      data.count > 100, data.count < 30_000_000,
                      let text = String(data: data, encoding: .utf8),
                      !text.prefix(500).lowercased().contains("<html"),
                      !text.prefix(500).lowercased().contains("<!doctype") else { continue }
                let lines = text.components(separatedBy: .newlines)
                guard let titleLine = lines.prefix(8).first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("<") && $0.contains(">") }) else { continue }
                let title = titleLine.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                guard !title.isEmpty else { continue }
                return Download(data: data, title: title)
            } catch is CancellationError { throw CancellationError() }
            catch { if Task.isCancelled { throw CancellationError() } }
        }
        throw Failure.unavailable
    }
}
