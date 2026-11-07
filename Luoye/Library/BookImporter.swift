import Foundation
import UniformTypeIdentifiers
import UIKit

/// 把用户选中或在线获取的电子书复制进书斋，并读出书名、作者和封面。
/// 支持 TXT、EPUB、Kindle（MOBI / AZW / AZW3 / PRC）、FB2、Markdown。
enum BookImporter {
    /// 扩展名 → 书斋里记的格式
    private static let formats: [String: String] = [
        "txt": "txt", "text": "txt",
        "epub": "epub",
        "mobi": "mobi", "azw": "mobi", "azw3": "mobi", "prc": "mobi",
        "fb2": "fb2",
        "md": "md", "markdown": "md",
    ]

    static let supportedTypes: [UTType] = [.plainText, .epub]
        + ["mobi", "azw", "azw3", "prc", "fb2", "md", "markdown"].compactMap { UTType(filenameExtension: $0) }

    static let supportedExtensionsDisplay = "EPUB、TXT、MOBI、AZW3、FB2"

    static func canonicalFormat(for extensionName: String) -> String? {
        let cleaned = extensionName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return formats[cleaned]
    }

    static func isSupported(extensionName: String) -> Bool {
        canonicalFormat(for: extensionName) != nil
    }

    enum ImportError: LocalizedError {
        case unsupportedFormat(String)
        case corruptedContent
        case invalidFileName

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                let label = ext.isEmpty ? "该" : ext.uppercased()
                return "当前阅读器暂不支持 \(label) 格式，请选择 \(BookImporter.supportedExtensionsDisplay) 版本。"
            case .corruptedContent:
                return "电子书文件不完整或内容无法解析，请尝试其他版本。"
            case .invalidFileName:
                return "下载文件名无效，请重新选择下载版本。"
            }
        }
    }

    /// 导入一个本地文件。`url` 来自系统文件选择器，需要先申请访问权限。
    static func importBook(from url: URL) throws -> Book {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        guard let format = formats[ext] else { throw ImportError.unsupportedFormat(ext) }

        let id = UUID()
        let fileName = "\(id.uuidString).\(ext)"
        let destination = BookStorage.directory.appending(path: fileName)
        try FileManager.default.copyItem(at: url, to: destination)

        var title = url.deletingPathExtension().lastPathComponent
        var author = ""
        var cover: Data?
        do {
            switch format {
            case "epub":
                let zip = try ZipReader(url: destination)
                let package = try EPUBPackage(zip: zip)
                title = package.title ?? title
                author = package.author ?? ""
                cover = package.coverPath.flatMap { try? zip.read($0) }
            case "mobi":
                let mobi = try MobiReader(data: Data(contentsOf: destination, options: .mappedIfSafe))
                title = mobi.title.trimmed ?? title
                author = mobi.author
                cover = mobi.coverKey.flatMap(mobi.image)
            case "fb2":
                let fb2 = try FB2Reader(data: Data(contentsOf: destination))
                title = fb2.title.trimmed ?? title
                author = fb2.author.trimmed ?? ""
                cover = fb2.coverKey.flatMap(fb2.image)
            default:
                break
            }
            _ = try BookContent.load(fileURL: destination, format: format, title: title)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        var coverFileName: String?
        if let cover, UIImage(data: cover) != nil {
            let name = "\(id.uuidString)-cover.\(cover.starts(with: [0x89, 0x50]) ? "png" : "jpg")"
            if (try? cover.write(to: BookStorage.directory.appending(path: name), options: .atomic)) != nil {
                coverFileName = name
            }
        }

        return Book(id: id, title: title, author: author, format: format, fileName: fileName, coverFileName: coverFileName)
    }

    /// 导入在线下载的临时文件，验证内容可读性，并保留原站书名、作者与封面。
    static func importDownloadedBook(
        from tempURL: URL,
        extensionName: String,
        preferredTitle: String,
        preferredAuthor: String,
        preferredCover: Data?,
        fileName: String,
        sourceKey: String?,
        editionNote: String?
    ) throws -> Book {
        let ext = extensionName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard let format = formats[ext] else {
            throw ImportError.unsupportedFormat(ext)
        }

        guard !fileName.isEmpty, fileName != ".", fileName != "..", !fileName.contains("/"), !fileName.contains("\\"), !fileName.contains("\0") else { throw ImportError.invalidFileName }
        let id = UUID()
        // A failed retry must never remove or overwrite a file already used by another Book.
        let preferred = BookStorage.directory.appending(path: fileName)
        let storedFileName: String
        if FileManager.default.fileExists(atPath: preferred.path(percentEncoded: false)) {
            let stem = (fileName as NSString).deletingPathExtension
            let suffix = (fileName as NSString).pathExtension
            storedFileName = stem + "-" + id.uuidString + (suffix.isEmpty ? "" : "." + suffix)
        } else { storedFileName = fileName }
        let destination = BookStorage.directory.appending(path: storedFileName)
        try FileManager.default.copyItem(at: tempURL, to: destination)

        var parsedTitle: String?
        var parsedAuthor: String?
        var embeddedCover: Data?
        do {
            switch format {
            case "epub":
                let zip = try ZipReader(url: destination)
                let package = try EPUBPackage(zip: zip)
                parsedTitle = package.title?.trimmed
                parsedAuthor = package.author?.trimmed
                embeddedCover = package.coverPath.flatMap { try? zip.read($0) }
            case "mobi":
                let mobi = try MobiReader(data: Data(contentsOf: destination, options: .mappedIfSafe))
                parsedTitle = mobi.title.trimmed
                parsedAuthor = mobi.author.trimmed
                embeddedCover = mobi.coverKey.flatMap(mobi.image)
            case "fb2":
                let fb2 = try FB2Reader(data: Data(contentsOf: destination))
                parsedTitle = fb2.title.trimmed
                parsedAuthor = fb2.author.trimmed
                embeddedCover = fb2.coverKey.flatMap(fb2.image)
            default:
                break
            }
            let checkTitle = preferredTitle.trimmed ?? parsedTitle ?? "未命名书籍"
            let content = try BookContent.load(fileURL: destination, format: format, title: checkTitle)
            guard !content.chapters.isEmpty else { throw ImportError.corruptedContent }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw ImportError.corruptedContent
        }

        let finalTitle = preferredTitle.trimmed ?? parsedTitle ?? "未命名书籍"
        let finalAuthor = preferredAuthor.trimmed ?? parsedAuthor ?? ""
        let coverCandidate = [preferredCover, embeddedCover].compactMap { $0 }.first { UIImage(data: $0) != nil }

        var coverFileName: String?
        if let cover = coverCandidate {
            let base = (storedFileName as NSString).deletingPathExtension
            let name = "\(base)-cover.\(cover.starts(with: [0x89, 0x50]) ? "png" : "jpg")"
            if (try? cover.write(to: BookStorage.directory.appending(path: name), options: .atomic)) != nil {
                coverFileName = name
            }
        }

        return Book(
            id: id,
            title: finalTitle,
            author: finalAuthor,
            format: format,
            fileName: storedFileName,
            coverFileName: coverFileName,
            sourceKey: sourceKey,
            editionNote: editionNote
        )
    }
}
