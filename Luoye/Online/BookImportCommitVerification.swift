#if DEBUG
import Foundation
import SwiftData
import UIKit

@MainActor enum BookImportCommitVerification {
    private enum Failure: LocalizedError {
        case check(String)
        var errorDescription: String? { if case .check(let value) = self { return value }; return nil }
    }
    private final class Gate {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    static func run() async {
        var checks: [String] = []
        var failure: String?
        do {
            let container = try ModelContainer(for: Book.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = ModelContext(container)
            defer { for book in (try? context.fetch(FetchDescriptor<Book>())) ?? [] { BookStorage.removeFiles(of: book) } }
            func check(_ value: Bool, _ label: String) throws {
                guard value else { throw Failure.check(label) }; checks.append(label); print("BOOK_COMMIT PASS " + label)
            }
            let text = "第一章 自写测试\n这是落叶的自写事务测试正文，用于检查重复保存、文件恢复与取消。\n第二章 保留进度\n书籍 ID 不应变化，已有书签应仍然指向原来的书籍。"
            func prepare(_ source: String, name: String? = nil, cover: Data? = nil) async throws -> PreparedBookImport {
                try await Task.detached(priority: .userInitiated) {
                    let temp = FileManager.default.temporaryDirectory.appending(path: "book-commit-fixture-" + UUID().uuidString + ".txt")
                    defer { try? FileManager.default.removeItem(at: temp) }
                    try text.write(to: temp, atomically: true, encoding: .utf8)
                    return PreparedBookImport(try BookImporter.importDownloadedBook(from: temp, extensionName: "txt", preferredTitle: "自写事务测试", preferredAuthor: "落叶测试", preferredCover: cover, fileName: name ?? ("book-commit-fixture-" + UUID().uuidString + ".txt"), sourceKey: source, editionNote: "TXT"))
                }.value
            }
            for (index, prefix) in ["wenku8", "zlib", "tomato"].enumerated() {
                let source = prefix + ":commit-fixture"
                let first = try BookImportCommit.commit(try await prepare(source), context: context)
                let identity = first.id, added = first.addedAt
                first.title = "读者自定义标题"; first.readingChapter = 1; first.readingOffset = 87; first.progress = 0.35
                try context.save()
                let duplicate = try await prepare(source)
                let reused = try BookImportCommit.commit(duplicate, context: context)
                try check(reused.id == identity && reused.readingOffset == 87 && !FileManager.default.fileExists(atPath: BookStorage.directory.appending(path: duplicate.fileName).path), prefix + " duplicate reuses original and removes unused copy")
                try FileManager.default.removeItem(at: first.fileURL)
                try check(!BookImportCommit.hasLocalFile(first), prefix + " missing local file detected")
                let repaired = try BookImportCommit.commit(try await prepare(source), context: context)
                let content = try BookContent.load(fileURL: repaired.fileURL, format: repaired.format, title: repaired.title)
                try check(repaired.id == identity && repaired.title == "读者自定义标题" && repaired.addedAt == added && repaired.readingChapter == 1 && repaired.readingOffset == 87 && repaired.progress == 0.35 && !content.chapters.isEmpty, prefix + " repair retains identity metadata and progress")
                let sameName = repaired.fileName
                try FileManager.default.removeItem(at: repaired.fileURL)
                let samePath = try BookImportCommit.commit(try await prepare(source, name: sameName), context: context)
                try check(samePath.id == identity && BookImportCommit.hasLocalFile(samePath), prefix + " restored same path is not mistaken for disposable duplicate")
                try check((try context.fetchCount(FetchDescriptor<Book>())) == index + 1, prefix + " only one persistent model per source")
            }
            let cover = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
                UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }.pngData()!
            let pending = try await prepare("zlib:cancel-fixture", cover: cover)
            let gate = Gate()
            let task = Task { @MainActor in
                await gate.wait()
                do { _ = try BookImportCommit.commit(pending, context: context); return false }
                catch is CancellationError { return true }
                catch { return false }
            }
            let end = Date().addingTimeInterval(10)
            while gate.continuation == nil && Date() < end { await Task.yield() }
            try check(gate.continuation != nil, "prepared download reached controlled pre-commit boundary")
            task.cancel(); gate.release()
            try check(await task.value, "cancellation after processing prevents insertion")
            try check(!FileManager.default.fileExists(atPath: BookStorage.directory.appending(path: pending.fileName).path) && pending.cover.map { !FileManager.default.fileExists(atPath: BookStorage.directory.appending(path: $0).path) } == true, "cancellation removes prepared text and cover")
            try check((try context.fetchCount(FetchDescriptor<Book>())) == 3, "cancellation preserves all existing source records")
        } catch { failure = error.localizedDescription; print("BOOK_COMMIT FAIL " + error.localizedDescription) }
        let report: [String: Any] = ["success": failure == nil, "passed": checks, "error": failure ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appending(path: "LuoyeBookImportCommitVerification.json"), options: .atomic)
        }
        print("BOOK_COMMIT RESULT passed=\(checks.count) success=\(failure == nil)")
    }
}
#endif
