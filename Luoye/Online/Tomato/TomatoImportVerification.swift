#if DEBUG
import Foundation
import SwiftData

/// Opt-in runtime integration check. All models, aliases and download fixtures are isolated.
@MainActor enum TomatoImportVerification {
    private final class Outcome { var result: Result<Book, Error>? }
    private final class Gate {
        var continuation: CheckedContinuation<URL, Never>?
        func wait() async -> URL { await withCheckedContinuation { continuation = $0 } }
        func release(_ url: URL) { continuation?.resume(returning: url); continuation = nil }
    }
    private enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
    static func run() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "tomato-import-verification-" + UUID().uuidString)
        var passed: [String] = []
        var errorMessage: String?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let container = try ModelContainer(for: Book.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = ModelContext(container)
            defer {
                for book in (try? context.fetch(FetchDescriptor<Book>())) ?? [] { BookStorage.removeFiles(of: book) }
                try? FileManager.default.removeItem(at: directory)
            }
            func check(_ condition: Bool, _ name: String) throws {
                guard condition else { throw Failure.message(name) }; passed.append(name); print("TOMATO_IMPORT PASS " + name)
            }
            let base = try TomatoClient.serverURL("https://LuoYe-Fixture.invalid:443/")
            try check(base.absoluteString == "https://luoye-fixture.invalid", "canonical service identity")
            let coordinator = TomatoImportCoordinator(aliasFile: directory.appending(path: "aliases.json"))
            let file = TomatoRemoteFile(kind: "file", name: "落叶自写导入验证.txt", rel_path: "fixture/book.txt", ext: "txt", size: 300)
            let book = TomatoBook(id: "7654593151348247614", title: "落叶自写导入验证", author: "落叶测试")
            func fixture(_ name: String, content: String) throws -> URL {
                let url = directory.appending(path: name + "-" + UUID().uuidString + ".txt")
                try content.write(to: url, atomically: true, encoding: .utf8); return url
            }
            let text = "落叶自写导入验证\n\n第一章 初见\n这是落叶自写的原生导入测试正文，用于检查阅读器与书斋。\n\n第二章 续读\n这里的阅读进度需要在重复导入后保留。"
            func perform(_ importer: TomatoImportCoordinator, file: TomatoRemoteFile, book: TomatoBook?, payload: URL) async throws -> Book {
                let outcome = Outcome()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let id = importer.start(file: file, base: base, book: book, context: context, download: { payload }) { result in
                        outcome.result = result; continuation.resume()
                    }
                    if id == nil { outcome.result = .failure(Failure.message("unexpected busy import")); continuation.resume() }
                }
                return try outcome.result!.get()
            }
            let first = try await perform(coordinator, file: file, book: nil, payload: fixture("valid", content: text))
            first.readingOffset = 123; first.progress = 0.4; try context.save()
            let content = try BookContent.load(fileURL: first.fileURL, format: first.format, title: first.title)
            try check(!content.chapters.isEmpty && content.chapters.reduce(0) { $0 + $1.characterCount } > 20, "native text import is readable")
            let duplicatePayload = try fixture("duplicate", content: text)
            let second = try await perform(coordinator, file: file, book: book, payload: duplicatePayload)
            try check(first.id == second.id && second.readingOffset == 123 && second.progress == 0.4, "detail and library reuse book and preserve reading progress")
            try check(coordinator.localBookID(for: book.id) == first.id, "detail resume resolves generic library import")
            // A duplicate must not start transport; the fixture remains untouched.
            try check(FileManager.default.fileExists(atPath: duplicatePayload.path), "duplicate avoids another download")
            let reopened = TomatoImportCoordinator(aliasFile: directory.appending(path: "aliases.json"))
            let third = try await perform(reopened, file: file, book: nil, payload: duplicatePayload)
            try check(third.id == first.id && (try context.fetchCount(FetchDescriptor<Book>())) == 1, "import aliases survive coordinator restart")
            let filesBeforeFailure = Set(try FileManager.default.contentsOfDirectory(atPath: BookStorage.directory.path))
            let bad = TomatoRemoteFile(kind: "file", name: "bad.txt", rel_path: "fixture/bad.txt", ext: "txt", size: 100)
            do {
                _ = try await perform(coordinator, file: bad, book: nil, payload: fixture("bad", content: "<!DOCTYPE html><html><body>请先登录</body></html>"))
                throw Failure.message("HTML was imported as TXT")
            } catch { try check(!(error is Failure), "HTTP-200 login page rejected before insertion") }
            let epub = TomatoRemoteFile(kind: "file", name: "bad.epub", rel_path: "fixture/bad.epub", ext: "epub", size: 100)
            do {
                _ = try await perform(coordinator, file: epub, book: nil, payload: fixture("bad-epub", content: "corrupt ZIP fixture"))
                throw Failure.message("invalid EPUB was imported")
            } catch { try check(!(error is Failure), "corrupt EPUB rejected and copied file removed") }
            try check((try context.fetchCount(FetchDescriptor<Book>())) == 1, "failed imports leave existing library unchanged")
            try check(Set(try FileManager.default.contentsOfDirectory(atPath: BookStorage.directory.path)) == filesBeforeFailure, "failed import leaves no copied book or cover file")
            let oldFile = TomatoRemoteFile(kind: "file", name: "old.txt", rel_path: "old/book.txt", ext: "txt", size: 100)
            let newFile = TomatoRemoteFile(kind: "file", name: "new.txt", rel_path: "new/book.txt", ext: "txt", size: 100)
            let oldGate = Gate(), newGate = Gate(), oldOutcome = Outcome(), newOutcome = Outcome()
            let oldID = coordinator.start(file: oldFile, base: base, book: nil, context: context, download: { await oldGate.wait() }) { oldOutcome.result = $0 }!
            try await wait { oldGate.continuation != nil }
            let refused = coordinator.start(file: newFile, base: base, book: nil, context: context, download: { await newGate.wait() }) { _ in }
            try check(refused == nil, "concurrent library screens cannot start duplicate imports")
            coordinator.cancel(id: oldID)
            _ = coordinator.start(file: newFile, base: base, book: nil, context: context, download: { await newGate.wait() }) { newOutcome.result = $0 }
            try await wait { newGate.continuation != nil }
            let oldTemp = try fixture("old", content: text)
            oldGate.release(oldTemp)
            try await wait { oldOutcome.result != nil }
            try check(coordinator.importing == newFile.id && !FileManager.default.fileExists(atPath: oldTemp.path), "canceled old source cannot clear new import or leak temporary file")
            newGate.release(try fixture("new", content: text))
            try await wait { newOutcome.result != nil }
            _ = try newOutcome.result!.get()
            try check((try context.fetchCount(FetchDescriptor<Book>())) == 2, "only new source inserts a book after cancellation")
        } catch { errorMessage = error.localizedDescription; print("TOMATO_IMPORT FAIL " + error.localizedDescription) }
        let report: [String: Any] = ["passed": passed, "success": errorMessage == nil, "error": errorMessage ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appending(path: "LuoyeTomatoImportVerification.json"), options: .atomic)
        }
        print("TOMATO_IMPORT RESULT passed=\(passed.count) success=\(errorMessage == nil)")
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(10)
        while !predicate() {
            if Date() > end { throw Failure.message("timed out waiting for controlled import task") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif
