import Foundation

/// EPUB 的“包信息”：书名、作者、封面，以及正文文件的阅读顺序。
struct EPUBPackage {
    var title: String?
    var author: String?
    /// 封面图在压缩包里的路径
    var coverPath: String?
    /// 正文各章在压缩包里的路径，按阅读顺序
    var spine: [String] = []

    enum EPUBError: Error {
        case missingPackage
    }

    init(zip: ZipReader) throws {
        // META-INF/container.xml 指明 .opf 文件在哪。
        guard let containerData = try zip.read("META-INF/container.xml"),
              let container = XMLTree.parse(containerData),
              let opfPath = container.first("rootfile")?.attribute("full-path"),
              let opfData = try zip.read(opfPath),
              let opf = XMLTree.parse(opfData)
        else { throw EPUBError.missingPackage }

        let baseDirectory = (opfPath as NSString).deletingLastPathComponent
        func resolve(_ href: String) -> String {
            let decoded = href.removingPercentEncoding ?? href
            let joined = baseDirectory.isEmpty ? decoded : baseDirectory + "/" + decoded
            return (joined as NSString).standardizingPath
        }

        title = opf.first("title")?.text.trimmed
        author = opf.first("creator")?.text.trimmed

        let items = opf.all("item")
        let hrefByID = Dictionary(
            items.compactMap { item in item.attribute("id").flatMap { id in item.attribute("href").map { (id, $0) } } },
            uniquingKeysWith: { first, _ in first }
        )

        // EPUB 3 用 properties="cover-image"，EPUB 2 用 <meta name="cover" content="图片 id">。
        let coverHref = items.first { ($0.attribute("properties") ?? "").split(separator: " ").contains("cover-image") }?
            .attribute("href")
            ?? opf.all("meta").first { $0.attribute("name") == "cover" }?.attribute("content").flatMap { hrefByID[$0] }
        coverPath = coverHref.map(resolve)

        spine = opf.all("itemref").compactMap { $0.attribute("idref").flatMap { hrefByID[$0] }.map(resolve) }
    }
}

extension String {
    /// 去掉首尾空白；去完是空的就当没有。
    var trimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
