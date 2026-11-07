#if DEBUG
import Foundation

extension WenkuService {
    /// 仅由调试启动参数触发，串行验证官网公开分类；不修改账号书架。
    func validateFacets() async {
        struct ResultRow: Codable {
            let name: String
            let group: String
            let path: String
            let status: String
            let count: Int
            let covers: Int
            let detail: String
        }
        var rows: [ResultRow] = []
        do {
            let list = try await page("/modules/article/toplist.php?sort=lastupdate")
            let home = try await page("/index.php")
            var ids = Set<String>()
            var facets = (list.facets + home.facets).filter { ids.insert($0.id).inserted }
            let extra = ProcessInfo.processInfo.arguments.contains("--verify-extra")
            if extra { facets = facets.filter { $0.group == "作品筛选" } }
            print("WENKU_VERIFY_START total=\(facets.count)")
            for (index, facet) in facets.enumerated() {
                let row: ResultRow
                do {
                    let result = try await page(facet.path)
                    row = ResultRow(name: facet.name, group: facet.group, path: facet.path,
                                    status: result.books.isEmpty ? "empty" : "pass", count: result.books.count,
                                    covers: result.books.filter { $0.cover != nil }.count, detail: result.title)
                } catch {
                    row = ResultRow(name: facet.name, group: facet.group, path: facet.path, status: "error", count: 0, covers: 0, detail: error.localizedDescription)
                }
                rows.append(row)
                if let data = try? JSONEncoder().encode(row), let json = String(data: data, encoding: .utf8) {
                    print("WENKU_VERIFY \(index + 1)/\(facets.count) \(json)")
                }
                if !authenticated { print("WENKU_VERIFY_STOP session expired"); break }
            }
            if extra {
                let searches = [("书名搜索", Self.searchPath("都市系列", field: "articlename", page: 1)),
                                ("作者搜索", Self.searchPath("川上稔", field: "author", page: 1)),
                                ("云书架", "/modules/article/bookcase.php")]
                for (name, path) in searches {
                    do {
                        let result = try await page(path)
                        let row = ResultRow(name: name, group: "功能验证", path: path, status: result.books.isEmpty ? "empty" : "pass", count: result.books.count, covers: result.books.filter { $0.cover != nil }.count, detail: result.title)
                        rows.append(row)
                        if let data = try? JSONEncoder().encode(row), let json = String(data: data, encoding: .utf8) { print("WENKU_FEATURE " + json) }
                    } catch { print("WENKU_FEATURE_ERROR \(name) \(error.localizedDescription)") }
                }
                if let sample = list.books.first {
                    let detail = try await page("/book/\(sample.id).htm")
                    if let own = detail.books.first(where: { $0.id == sample.id }) {
                        print("WENKU_DETAIL title=\(!own.title.isEmpty) author=\(!own.author.isEmpty) summary=\(!own.summary.isEmpty) cover=\(own.cover != nil) tags=\(own.tags?.count ?? 0)")
                    }
                    if let path = detail.catalogue {
                        let catalogue = try await page(path)
                        print("WENKU_CATALOGUE chapters=\(catalogue.chapters.count) volumes=\(Set(catalogue.chapters.map(\.volume)).count)")
                    }
                }
            }
            let directory = URL.applicationSupportDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(rows)
            try data.write(to: directory.appending(path: "WenkuValidation.json"), options: .atomic)
            print("WENKU_VERIFY_DONE pass=\(rows.filter { $0.status == "pass" }.count) empty=\(rows.filter { $0.status == "empty" }.count) errors=\(rows.filter { $0.status == "error" }.count)")
        } catch { print("WENKU_VERIFY_ABORT \(error.localizedDescription)") }
    }
}
#endif
