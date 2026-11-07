#if DEBUG
import Foundation

@MainActor enum BookImportCollisionVerification {
    static func run() {
        let name = "luoye-collision-fixture-" + UUID().uuidString + ".txt"
        let destination = BookStorage.directory.appending(path: name)
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".txt")
        let original = Data("第一章 原有正文\n这份自写正文代表书斋里原来可读的文件，重试失败后必须保留。".utf8)
        var passed = false
        var noOrphans = false
        var successIsolated = false
        var invalidPathRejected = false
        do {
            try original.write(to: destination)
            try Data().write(to: temp)
            let before = Set(try FileManager.default.contentsOfDirectory(atPath: BookStorage.directory.path))
            do {
                let unexpected = try BookImporter.importDownloadedBook(from: temp, extensionName: "txt", preferredTitle: "冲突测试", preferredAuthor: "", preferredCover: nil, fileName: name, sourceKey: nil, editionNote: nil)
                BookStorage.removeFiles(of: unexpected)
            } catch {}
            passed = (try? Data(contentsOf: destination)) == original
            noOrphans = Set(try FileManager.default.contentsOfDirectory(atPath: BookStorage.directory.path)) == before
            try Data("第一章 新副本\n这是另一份自写测试正文，用于确认成功导入也不覆盖旧书。".utf8).write(to: temp)
            let fresh = try BookImporter.importDownloadedBook(from: temp, extensionName: "txt", preferredTitle: "独立副本测试", preferredAuthor: "", preferredCover: nil, fileName: name, sourceKey: nil, editionNote: nil)
            successIsolated = fresh.fileName != name && FileManager.default.fileExists(atPath: fresh.fileURL.path) && (try? Data(contentsOf: destination)) == original
            BookStorage.removeFiles(of: fresh)
            let escapedName = "../luoye-escape-fixture-" + UUID().uuidString + ".txt"
            do {
                let unexpected = try BookImporter.importDownloadedBook(from: temp, extensionName: "txt", preferredTitle: "路径测试", preferredAuthor: "", preferredCover: nil, fileName: escapedName, sourceKey: nil, editionNote: nil)
                BookStorage.removeFiles(of: unexpected)
            } catch BookImporter.ImportError.invalidFileName { invalidPathRejected = true } catch {}
        } catch { print("BOOK_IMPORT_COLLISION ERROR " + error.localizedDescription) }
        try? FileManager.default.removeItem(at: destination); try? FileManager.default.removeItem(at: temp)
        let report: [String: Any] = ["originalPreserved": passed, "failedCopyCleaned": noOrphans, "successUsesIndependentCopy": successIsolated, "invalidPathRejected": invalidPathRejected]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) {
            try? data.write(to: FileManager.default.temporaryDirectory.appending(path: "LuoyeBookImportCollisionVerification.json"), options: .atomic)
        }
        print("BOOK_IMPORT_COLLISION originalPreserved=\(passed) failedCopyCleaned=\(noOrphans) successUsesIndependentCopy=\(successIsolated) invalidPathRejected=\(invalidPathRejected)")
    }
}
#endif
