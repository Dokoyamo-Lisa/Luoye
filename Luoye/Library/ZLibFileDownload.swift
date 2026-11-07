import Foundation

/// Z-Library 电子书文件获取与校验层，支持进度回调、取消清理与内容签名验证。
enum ZLibFileDownload {
    enum Failure: LocalizedError {
        case unsupportedFormat(String)
        case missingDownloadLink
        case loginRequired
        case challengeRequired
        case quotaExceeded(String)
        case invalidFileContent
        case network(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                let name = ext.isEmpty ? "该" : ext.uppercased()
                return "当前阅读器暂不支持 \(name) 格式，请选择 \(BookImporter.supportedExtensionsDisplay) 版本。"
            case .missingDownloadLink:
                return "该版本需登录 Z-Library 账号后方可下载。"
            case .loginRequired:
                return "当前版本或下载通道需要登录 Z-Library 账号。"
            case .challengeRequired:
                return "下载通道触发了安全验证，请完成安全验证后重试。"
            case .quotaExceeded(let hint):
                return hint.isEmpty
                    ? "当前账号或 IP 今日下载额度已用完，请等待额度重置后再试。"
                    : "今日下载额度已用完（\(hint)）。"
            case .invalidFileContent:
                return "下载的文件内容无效或格式不匹配，请尝试其他版本。"
            case .network(let message):
                return message.isEmpty ? "文件下载失败，请检查网络后重试。" : message
            }
        }
    }

    /// 下载指定版本的书籍到临时文件并通过调用方闭包完成导入，退出时自动清理临时文件。
    static func fetchAndProcess<T>(
        downloadPath: String,
        extensionName: String,
        baseURL: URL,
        cookies: [HTTPCookie],
        onProgress: @MainActor @Sendable (Int64, Int64?) -> Void,
        processor: (URL) throws -> T
    ) async throws -> T {
        let ext = extensionName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard BookImporter.isSupported(extensionName: ext) else {
            throw Failure.unsupportedFormat(ext)
        }
        guard !downloadPath.isEmpty,
              let url = URL(string: downloadPath, relativeTo: baseURL)?.absoluteURL else {
            throw Failure.missingDownloadLink
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appending(path: "zlib-dl-\(UUID().uuidString).\(ext)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        // Keep cookies in the ephemeral session instead of creating an App Group cookie store per download.
        let cookieStorage = config.httpCookieStorage
        for cookie in cookies { cookieStorage?.setCookie(cookie) }
        config.httpShouldSetCookies = true

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.setValue(ZLibService.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Failure.network("连接下载服务器失败，请稍后重试。")
        }

        guard let http = response as? HTTPURLResponse else {
            throw Failure.network("未收到有效的服务器响应。")
        }
        let finalPath = http.url?.path.lowercased() ?? ""
        if finalPath.hasPrefix("/login") || finalPath.hasPrefix("/registration") {
            throw Failure.loginRequired
        }
        if http.statusCode == 401 { throw Failure.loginRequired }
        if http.statusCode == 503 || http.statusCode == 513 || http.statusCode == 517 {
            throw Failure.challengeRequired
        }
        guard http.statusCode == 200 else {
            throw Failure.network("下载服务器返回状态码 \(http.statusCode)，请稍后重试。")
        }

        let expectedLength: Int64? = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        await onProgress(0, expectedLength)

        FileManager.default.createFile(atPath: tempURL.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        var headSample = Data()
        var buffer = Data()
        buffer.reserveCapacity(65_536)
        var totalReceived: Int64 = 0
        var lastReported: Int64 = 0

        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                if headSample.count < 2048 {
                    headSample.append(byte)
                }
                buffer.append(byte)
                totalReceived += 1
                if buffer.count >= 65_536 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    if totalReceived - lastReported >= 65_536 {
                        lastReported = totalReceived
                        await onProgress(totalReceived, expectedLength)
                    }
                }
                if totalReceived > 150_000_000 {
                    throw Failure.invalidFileContent
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                buffer.removeAll()
            }
            try handle.close()
            await onProgress(totalReceived, expectedLength ?? totalReceived)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as Failure {
            throw failure
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Failure.network("文件传输中断，请重试。")
        }

        try Task.checkCancellation()
        try validateDownloadedFile(
            headSample: headSample,
            totalBytes: totalReceived,
            mimeType: http.mimeType ?? "",
            extensionName: ext
        )

        return try processor(tempURL)
    }

    /// 严格检验文件内容，防止将 HTML 登录页、验证页、额度提示页或损坏数据误认为正常书籍。
    static func validateDownloadedFile(
        headSample: Data,
        totalBytes: Int64,
        mimeType: String,
        extensionName: String
    ) throws {
        guard totalBytes > 128 else {
            throw Failure.invalidFileContent
        }
        let headText = String(decoding: headSample, as: UTF8.self)
        let lowerHead = headText.lowercased()
        let lowerMime = mimeType.lowercased()

        let looksLikeHTML = lowerMime.contains("text/html")
            || lowerHead.contains("<!doctype html")
            || lowerHead.contains("<html")
            || lowerHead.contains("diamwall")

        if looksLikeHTML {
            if lowerHead.contains("diamwall") || lowerHead.contains("just a moment") || lowerHead.contains("security verification") {
                throw Failure.challengeRequired
            }
            if lowerHead.contains("daily limit") || lowerHead.contains("download limit") || lowerHead.contains("downloads limit") || lowerHead.contains("more downloads") {
                var hint = ""
                if let range = headText.range(of: "resets in [0-9]+ [a-zA-Z]+", options: [.regularExpression, .caseInsensitive]) {
                    hint = String(headText[range])
                }
                throw Failure.quotaExceeded(hint)
            }
            if lowerHead.contains("loginform") || lowerHead.contains("data-action=\"login\"") || lowerHead.contains("sign in") || lowerHead.contains("log in") {
                throw Failure.loginRequired
            }
            throw Failure.invalidFileContent
        }

        guard let format = BookImporter.canonicalFormat(for: extensionName) else {
            throw Failure.unsupportedFormat(extensionName)
        }

        switch format {
        case "epub":
            // EPUB 必须是合法的 ZIP 容器 (PK\x03\x04)
            guard headSample.starts(with: [0x50, 0x4B, 0x03, 0x04]) else {
                throw Failure.invalidFileContent
            }
        case "mobi":
            // PalmDB / MOBI / AZW3 在偏移 60..68 处包含 "BOOKMOBI" 或 "TEXtREAd"
            guard headSample.count >= 68 else {
                throw Failure.invalidFileContent
            }
            let magic = String(decoding: headSample[60..<68], as: UTF8.self)
            guard magic == "BOOKMOBI" || magic == "TEXtREAd" else {
                throw Failure.invalidFileContent
            }
        case "fb2":
            guard lowerHead.contains("<fictionbook") || lowerHead.contains("<?xml") else {
                throw Failure.invalidFileContent
            }
        default:
            break
        }
    }
}
