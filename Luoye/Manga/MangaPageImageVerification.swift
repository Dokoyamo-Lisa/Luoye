#if DEBUG
import Foundation
import UIKit

@MainActor enum MangaPageImageVerification {
    private actor Gate {
        var automatic: [String: Data] = [:]
        var pending: [String: CheckedContinuation<Data, Error>] = [:]
        var calls: [String: Int] = [:]
        func load(_ resource: MangaPageResource) async throws -> Data {
            calls[resource.key, default: 0] += 1
            if let data = automatic[resource.key] { return data }
            return try await withCheckedThrowingContinuation { pending[resource.key] = $0 }
        }
        func set(_ resource: MangaPageResource, data: Data) { automatic[resource.key] = data }
        func waiting(_ resource: MangaPageResource) -> Bool { pending[resource.key] != nil }
        func finish(_ resource: MangaPageResource, _ result: Result<Data, Error>) { pending.removeValue(forKey: resource.key)?.resume(with: result) }
        func count(_ resource: MangaPageResource) -> Int { calls[resource.key] ?? 0 }
        func close() { let all = pending.values; pending.removeAll(); for item in all { item.resume(throwing: CancellationError()) } }
    }
    private enum Failure: LocalizedError {
        case check(String)
        var errorDescription: String? { if case .check(let value) = self { return value }; return nil }
    }
    static func run() async {
        let gate = Gate()
        var checks: [String] = [], failure: String?
        do {
            func check(_ value: Bool, _ title: String) throws {
                guard value else { throw Failure.check(title) }; checks.append(title); print("MANGA_IMAGE PASS " + title)
            }
            func resource(_ name: String) -> MangaPageResource { .remote(MangaImageRequest(url: URL(string: "https://luoye-image-fixture.invalid/" + name)!)) }
            func png(width: Int, height: Int, color: UIColor) -> Data {
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
                    color.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                }.pngData()!
            }
            try check(MangaReadingNavigation.visiblePages(at: 2, count: 8, mode: .pageLeftToRight, twoPage: true, coverAlone: true) == [1, 2], "readiness includes both pages of a spread with solo cover")
            try check(MangaReadingNavigation.visiblePages(at: 2, count: 8, mode: .pageRightToLeft, twoPage: true, coverAlone: false) == [2, 3], "RTL spread readiness includes both logical image indexes")
            try check(MangaReadingNavigation.visiblePages(at: 7, count: 8, mode: .pageLeftToRight, twoPage: true, coverAlone: true) == [7], "final unpaired spread requires only its actual image")
            try check(MangaReadingNavigation.visiblePages(at: 2, count: 8, mode: .continuousTopToBottom, twoPage: true, coverAlone: true) == [2], "continuous mode ignores the spread preference")
            try check(MangaReadingNavigation.visiblePages(at: -1, count: 8, mode: .pageLeftToRight, twoPage: false, coverAlone: true).isEmpty, "invalid negative image cannot become ready")
            try check(MangaReadingNavigation.visiblePages(at: 0, count: 0, mode: .pageLeftToRight, twoPage: true, coverAlone: true).isEmpty, "empty chapter cannot become ready")
            let red = png(width: 3, height: 5, color: .red), blue = png(width: 7, height: 9, color: .blue)
            let a = resource("a"), b = resource("b"), c = resource("c"), d = resource("d"), e = resource("e")
            await gate.set(a, data: red); await gate.set(d, data: blue)
            let cache = MangaPageCache(loader: { try await gate.load($0) })
            let model = MangaPageImageModel(cache: cache)
            try check(await model.load(a) && model.image?.size == CGSize(width: 3, height: 5), "valid page decodes")
            let bTask = Task { await model.load(b) }
            try await wait { await gate.waiting(b) }
            try check(model.image == nil && !model.failure && model.resourceKey == b.key, "switching resource clears previous image before request completes")
            await gate.finish(b, .failure(URLError(.notConnectedToInternet)))
            try check(!(await bTask.value) && model.failure && model.image == nil, "failed new page exposes retry instead of old image")
            let retry = Task { await model.load(b) }
            try await wait { await gate.waiting(b) }
            model.cancel(keepingImage: false)
            await gate.finish(b, .success(red))
            try check(!(await retry.value) && model.image == nil && model.resourceKey == nil, "late retry completion after disappearance is ignored")
            try check(await model.load(b) && model.image?.size == CGSize(width: 3, height: 5), "reappearing page can load again")
            let old = Task { await model.load(c) }
            try await wait { await gate.waiting(c) }
            try check(await model.load(d) && model.image?.size == CGSize(width: 7, height: 9), "newer page completes independently")
            await gate.finish(c, .success(red))
            try check(!(await old.value) && model.resourceKey == d.key && model.image?.size == CGSize(width: 7, height: 9), "uncanceled old response cannot overwrite newer page")
            model.cancel(keepingImage: true)
            try check(model.image?.size == CGSize(width: 7, height: 9), "continuous scrolling retains completed image and height")
            let retained = await model.load(d), dCount = await gate.count(d)
            try check(retained && dCount == 1, "retained continuous page does not refetch")
            await gate.set(e, data: Data("<html>HTTP 200 error page</html>".utf8))
            try check(!(await model.load(e)) && model.image == nil && model.failure, "non-image response is rejected")
            await gate.set(e, data: blue)
            let recovered = await model.load(e), eCount = await gate.count(e)
            try check(recovered && eCount == 2 && !model.failure, "decode failure invalidates bytes so retry reaches loader")
        } catch { failure = error.localizedDescription; print("MANGA_IMAGE FAIL " + error.localizedDescription) }
        await gate.close()
        let report: [String: Any] = ["success": failure == nil, "passed": checks, "error": failure ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appending(path: "LuoyeMangaPageImageVerification.json"), options: .atomic)
        }
        print("MANGA_IMAGE RESULT passed=\(checks.count) success=\(failure == nil)")
    }
    private static func wait(_ predicate: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(10)
        while !(await predicate()) {
            if Date() > end { throw Failure.check("timed out waiting for controlled image loader") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif
