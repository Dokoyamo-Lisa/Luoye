#if DEBUG
import Foundation
import QuartzCore
import UIKit

/// A real standard ZIP fixture is generated outside the app; no library state is touched.
@MainActor enum ComicIndexVerification {
    static func run() async {
        var checks: [[String: Any]] = []
        var metrics: [String: Double] = [:]
        func check(_ passed: Bool, _ title: String) { checks.append(["passed": passed, "title": title]) }
        do {
            let file = FileManager.default.temporaryDirectory.appending(path: "LuoyeComicIndexFixture.cbz")
            // Let unrelated initial scene work settle before measuring the reader operation.
            try await Task.sleep(for: .seconds(1))
            let start = CACurrentMediaTime()
            let mainQueueProbe = Task { @MainActor in CACurrentMediaTime() - start }
            let count = try await ComicArchive.loadPageCount(fileURL: file, format: "cbz")
            metrics["indexDuration"] = CACurrentMediaTime() - start
            let mainQueueDelay = await mainQueueProbe.value
            metrics["mainQueueDelay"] = mainQueueDelay
            check(count == 40_000, "large standard CBZ retains every image page")
            check(mainQueueDelay < 0.1, "main actor remains responsive while indexing a large CBZ")

            let cancelled = Task { try await ComicArchive.loadPageCount(fileURL: file, format: "cbz") }
            try await Task.sleep(for: .milliseconds(10))
            cancelled.cancel()
            do { _ = try await cancelled.value; check(false, "cancelled indexing cannot publish a count") }
            catch is CancellationError { check(true, "cancelled indexing cannot publish a count") }
            catch { check(false, "cancellation preserves CancellationError") }

            let directory = FileManager.default.temporaryDirectory.appending(path: "comic-index-verification-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let missing = directory.appending(path: "missing.cbz")
            do { _ = try await ComicArchive.loadPageCount(fileURL: missing, format: "cbz"); check(false, "missing files retain a readable file error") }
            catch { let failure = error as NSError; check(failure.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code), "missing files retain a readable file error") }
            let alreadyCancelled = Task { try await ComicArchive.loadPageCount(fileURL: missing, format: "cbz") }
            alreadyCancelled.cancel()
            do { _ = try await alreadyCancelled.value; check(false, "cancelled request does not begin file access") }
            catch is CancellationError { check(true, "cancelled request does not begin file access") }
            catch { check(false, "cancelled request does not begin file access") }

            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).pngData { context in
                UIColor.systemPink.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }
            try png.write(to: directory.appending(path: "10.png")); try png.write(to: directory.appending(path: "2.png"))
            let folderCount = try await ComicArchive.loadPageCount(fileURL: directory, format: "folder")
            check(folderCount == 2, "downloaded image folders retain the correct page count")
            let pdf = directory.appending(path: "two-pages.pdf")
            try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 50, height: 70)).writePDF(to: pdf) { context in context.beginPage(); context.beginPage() }
            let pdfCount = try await ComicArchive.loadPageCount(fileURL: pdf, format: "pdf")
            check(pdfCount == 2, "PDF indexing retains the correct page count")
            let corrupt = directory.appending(path: "corrupt.cbz"); try Data("not a zip".utf8).write(to: corrupt)
            do { _ = try await ComicArchive.loadPageCount(fileURL: corrupt, format: "cbz"); check(false, "corrupt archives remain rejected") }
            catch is ZipReader.ZipError { check(true, "corrupt archives remain rejected") }
            catch { check(false, "corrupt archives preserve their archive error") }
        } catch { check(false, "unexpected error: \(error)") }
        let report: [String: Any] = ["success": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks, "metrics": metrics]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appending(path: "LuoyeComicIndexVerification.json"), options: .atomic)
        }
    }
}
#endif
