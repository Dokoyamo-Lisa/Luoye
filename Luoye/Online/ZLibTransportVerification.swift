#if DEBUG
import Foundation

@MainActor enum ZLibTransportVerification {
    private struct Payload: Sendable { let count: Int; let temporary: URL }
    private final class Progress { var received: Int64 = 0 }
    static func run() async {
        let base = URL(string: "http://127.0.0.1:18864")!
        let cookie = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "luoye_fixture", .value: "ready"])!
        var results: [String: Bool] = [:]
        func record(_ name: String, _ success: Bool) { results[name] = success; print("ZLIB_TRANSPORT \(success ? "PASS" : "FAIL") " + name) }
        do {
            let result = try await ZLibFileDownload.fetchAndProcess(downloadPath: "/book.txt", extensionName: "txt", baseURL: base, cookies: [cookie], onProgress: { _, _ in }, processor: { temp in
                Payload(count: try Data(contentsOf: temp).count, temporary: temp)
            })
            record("private download session sends supplied cookie", result.count > 128)
            record("successful transport removes its temporary file", !FileManager.default.fileExists(atPath: result.temporary.path))
        } catch { record("private download session sends supplied cookie", false) }
        do {
            _ = try await ZLibFileDownload.fetchAndProcess(downloadPath: "/book.txt", extensionName: "txt", baseURL: base, cookies: [], onProgress: { _, _ in }, processor: { _ in true })
            record("independent download does not inherit previous cookies", false)
        } catch ZLibFileDownload.Failure.loginRequired { record("independent download does not inherit previous cookies", true) }
        catch { record("independent download does not inherit previous cookies", false) }
        do {
            _ = try await ZLibFileDownload.fetchAndProcess(downloadPath: "/unauthorized", extensionName: "txt", baseURL: base, cookies: [], onProgress: { _, _ in }, processor: { _ in true })
            record("HTTP 401 requests login", false)
        } catch ZLibFileDownload.Failure.loginRequired { record("HTTP 401 requests login", true) }
        catch { record("HTTP 401 requests login", false) }
        do {
            _ = try await ZLibFileDownload.fetchAndProcess(downloadPath: "/redirect", extensionName: "txt", baseURL: base, cookies: [], onProgress: { _, _ in }, processor: { _ in true })
            record("login redirect is not processed as a book", false)
        } catch ZLibFileDownload.Failure.loginRequired { record("login redirect is not processed as a book", true) }
        catch { record("login redirect is not processed as a book", false) }
        do {
            _ = try await ZLibFileDownload.fetchAndProcess(downloadPath: "/challenge", extensionName: "txt", baseURL: base, cookies: [], onProgress: { _, _ in }, processor: { _ in true })
            record("verification response requests website challenge", false)
        } catch ZLibFileDownload.Failure.challengeRequired { record("verification response requests website challenge", true) }
        catch { record("verification response requests website challenge", false) }
        let before = Set(((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("zlib-dl-") })
        let progress = Progress()
        let task = Task { @MainActor in
            do {
                _ = try await ZLibFileDownload.fetchAndProcess(downloadPath: "/slow", extensionName: "txt", baseURL: base, cookies: [cookie], onProgress: { received, _ in progress.received = received }, processor: { _ in true })
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let end = Date().addingTimeInterval(10)
        while progress.received < 65_536 && Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        record("controlled transport reached in-flight byte progress", progress.received >= 65_536)
        task.cancel()
        record("mid-transfer cancellation propagates", await task.value)
        let after = Set(((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("zlib-dl-") })
        record("canceled transport leaves no partial file", before == after)
        let report: [String: Any] = ["checks": results, "success": results.values.allSatisfy { $0 }]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appending(path: "LuoyeZLibTransportVerification.json"), options: .atomic)
        }
    }
}
#endif
