import Foundation

enum TomatoDownloadedFile {
    static func validate(_ file: URL, extensionName: String, mimeType: String? = nil) throws {
        guard ["txt", "epub"].contains(extensionName.lowercased()) else { throw TomatoError.message("请选择 TXT 或 EPUB 文件。") }
        if let mime = mimeType?.lowercased(), mime == "text/html" || mime == "application/xhtml+xml" || mime == "application/json" {
            throw TomatoError.message("下载器返回了网页或错误信息，请检查服务登录后重试。")
        }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 200_000_000 else { throw TomatoError.message("下载文件为空或过大。") }
        if extensionName.lowercased() == "txt" {
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            let data = try handle.read(upToCount: 8192) ?? Data()
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? ""
            let start = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).lowercased()
            if start.hasPrefix("<!doctype html") || start.hasPrefix("<html") {
                throw TomatoError.message("下载内容是网页，不是小说正文，请检查服务登录后重试。")
            }
        }
    }
}
