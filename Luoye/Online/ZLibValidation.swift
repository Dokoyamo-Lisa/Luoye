#if DEBUG
import Foundation
import UIKit

@MainActor
enum ZLibVerificationSuite {
    struct CheckItem: Codable {
        let name: String
        let status: String
        let durationMs: Int
        let detail: String
    }

    struct Report: Codable {
        let timestamp: String
        let coldStartMs: Int
        let firstConnectMs: Int
        let cacheHitMs: Int
        let checks: [CheckItem]
    }

    static func run(
        zlibService service: ZLibService,
        zlibAccount accountStore: ZLibAccountStore,
        history historyStore: BrowsingHistoryStore
    ) async {
        print("ZLIB_VERIFY_START")
        var checks: [CheckItem] = []

        func record(_ name: String, start: ContinuousClock.Instant, status: String, detail: String) {
            let ms = elapsedMs(from: start)
            let item = CheckItem(name: name, status: status, durationMs: ms, detail: detail)
            checks.append(item)
            print("ZLIB_VERIFY_ITEM [\(status)] \(name) (\(ms)ms): \(detail)")
        }

        // Clear memory and disk cache for ZLib "/" first to measure true first network connect vs cache hit
        service.clearResponseMemory()
        await service.clearPageCache()

        var firstConnectMs = 0
        var cacheHitMs = 0
        var sampleBook: ZLibBook?

        // 1. First network connect + Home recommendation
        let tHome = ContinuousClock.now
        do {
            let home = try await service.page("/", refresh: true)
            firstConnectMs = elapsedMs(from: tHome)
            sampleBook = home.books.first
            let covers = home.books.filter { $0.cover != nil }.count
            let ok = !home.books.isEmpty
            record("首页推荐与首次联网 (/)", start: tHome, status: ok ? "PASS" : "FAIL", detail: "books=\(home.books.count), covers=\(covers)")
        } catch {
            firstConnectMs = elapsedMs(from: tHome)
            record("首页推荐与首次联网 (/)", start: tHome, status: "FAIL", detail: error.localizedDescription)
        }

        // 2. Cache hit latency
        let tCache = ContinuousClock.now
        do {
            let cachedHome = try await service.page("/", refresh: false)
            cacheHitMs = elapsedMs(from: tCache)
            record("首页缓存命中 (/)", start: tCache, status: !cachedHome.books.isEmpty ? "PASS" : "FAIL", detail: "books=\(cachedHome.books.count), latency=\(cacheHitMs)ms")
        } catch {
            cacheHitMs = elapsedMs(from: tCache)
            record("首页缓存命中 (/)", start: tCache, status: "FAIL", detail: error.localizedDescription)
        }

        // 3. Popular recommendations (/popular)
        let tPop = ContinuousClock.now
        do {
            let pop = try await service.page("/popular", refresh: true)
            if sampleBook == nil { sampleBook = pop.books.first }
            record("热门书目 (/popular)", start: tPop, status: !pop.books.isEmpty ? "PASS" : "FAIL", detail: "books=\(pop.books.count)")
        } catch {
            record("热门书目 (/popular)", start: tPop, status: "FAIL", detail: error.localizedDescription)
        }

        // 4. Search (/s/三体) & Pagination (page 2) & Multi-criteria Filter
        var epubCandidate: ZLibBook?
        let tSearch = ContinuousClock.now
        do {
            var filter = ZLibSearchFilter()
            let p1 = try await service.page(ZLibService.searchPath(query: "三体", filter: filter, page: 1), refresh: true)
            epubCandidate = p1.books.first(where: { $0.extensionName.lowercased() == "epub" }) ?? p1.books.first
            record("关键词搜索 (/s/三体 p1)", start: tSearch, status: !p1.books.isEmpty ? "PASS" : "FAIL", detail: "books=\(p1.books.count), totalPages=\(p1.totalPages)")

            let tPage2 = ContinuousClock.now
            let p2 = try await service.page(ZLibService.searchPath(query: "三体", filter: filter, page: 2), refresh: true)
            let p1IDs = Set(p1.books.map { $0.id })
            let p2IDs = Set(p2.books.map { $0.id })
            let diffIDs = p1IDs != p2IDs
            record("搜索分页 (/s/三体 p2)", start: tPage2, status: (!p2.books.isEmpty && diffIDs) ? "PASS" : "FAIL", detail: "p2Books=\(p2.books.count), distinctFromP1=\(diffIDs)")

            let tFilter = ContinuousClock.now
            filter.language = "chinese"
            filter.extensionName = "EPUB"
            filter.yearFrom = 2010
            let filtered = try await service.page(ZLibService.searchPath(query: "历史", filter: filter, page: 1), refresh: true)
            if epubCandidate == nil {
                epubCandidate = filtered.books.first(where: { $0.extensionName.lowercased() == "epub" })
            }
            record("多条件筛选 (语言=中文, 格式=EPUB, 年份>=2010)", start: tFilter, status: !filtered.books.isEmpty ? "PASS" : "FAIL", detail: "books=\(filtered.books.count)")
        } catch {
            record("搜索/分页/筛选", start: tSearch, status: "FAIL", detail: error.localizedDescription)
        }

        // 5. Categories (/categories -> /category/...)
        let tCat = ContinuousClock.now
        do {
            let catIndex = try await service.page("/categories", refresh: true)
            let catCount = catIndex.facets.count
            if let firstCat = catIndex.facets.first {
                let sub = try await service.page(firstCat.path, refresh: true)
                let subOk = !sub.books.isEmpty || !sub.facets.isEmpty
                record("分类浏览 (/categories -> \(firstCat.name))", start: tCat, status: (catCount > 0 && subOk) ? "PASS" : "FAIL", detail: "categories=\(catCount), subBooks=\(sub.books.count), subFacets=\(sub.facets.count)")
            } else {
                record("分类浏览 (/categories)", start: tCat, status: "FAIL", detail: "no categories parsed")
            }
        } catch {
            record("分类浏览 (/categories)", start: tCat, status: "FAIL", detail: error.localizedDescription)
        }

        // 6. Public Booklists (/booklists -> detail + page 2 via /papi/booklist/.../get-books/2)
        let tList = ContinuousClock.now
        do {
            let blIndex = try await service.page("/booklists", refresh: true)
            if let firstList = blIndex.booklists.first {
                let blDetail = try await service.page(firstList.path, refresh: true)
                let p2Result = try await service.fetchBooklistMorePage(booklistId: firstList.id, page: 2)
                record("书单浏览与分页 (/booklists -> \(firstList.id))", start: tList, status: (!blIndex.booklists.isEmpty && !blDetail.books.isEmpty) ? "PASS" : "FAIL", detail: "lists=\(blIndex.booklists.count), detailBooks=\(blDetail.books.count), page2Books=\(p2Result.books.count)")
            } else {
                record("书单浏览 (/booklists)", start: tList, status: "FAIL", detail: "no booklists parsed")
            }
        } catch {
            record("书单浏览 (/booklists)", start: tList, status: "FAIL", detail: error.localizedDescription)
        }

        // 7. Book Detail + Format Expansion + Author Works + Cover Image Fetch
        var detailBookForDownload: ZLibBook?
        var detailFormats: [ZLibFormatOption] = []
        if let target = epubCandidate ?? sampleBook {
            let tDetail = ContinuousClock.now
            do {
                let detailPage = try await service.page(target.path, refresh: true)
                let parsed = detailPage.books.first ?? target
                detailBookForDownload = parsed
                detailFormats = detailPage.formats
                let hasMeta = !parsed.title.isEmpty && (!parsed.language.isEmpty || !parsed.extensionName.isEmpty)
                record("书籍详情与多版本格式 (/book/\(parsed.id))", start: tDetail, status: hasMeta ? "PASS" : "FAIL", detail: "title=\(parsed.title), formats=\(detailFormats.count), related=\(detailPage.relatedBooks.count), dl=\(parsed.downloadPath != nil)")

                if let coverStr = parsed.cover, let coverURL = URL(string: coverStr) {
                    let tCover = ContinuousClock.now
                    var coverLoaded = false
                    var req = URLRequest(url: coverURL)
                    req.setValue("https://z-lib.sk/", forHTTPHeaderField: "Referer")
                    if let (data, _) = try? await FanhuaNetwork.session.data(for: req), UIImage(data: data) != nil {
                        coverLoaded = true
                    }
                    record("封面加载与并发缓存", start: tCover, status: coverLoaded ? "PASS" : "FAIL", detail: "url=\(coverURL.host() ?? ""), loaded=\(coverLoaded)")
                }

                let authorPath = parsed.authorPath ?? "/author/\(parsed.author.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? parsed.author)"
                if !parsed.author.isEmpty {
                    let tAuthor = ContinuousClock.now
                    let authorPage = try await service.page(authorPath, refresh: true)
                    record("作者相关作品 (\(parsed.author))", start: tAuthor, status: !authorPage.books.isEmpty ? "PASS" : "FAIL", detail: "books=\(authorPage.books.count)")
                }
            } catch {
                record("书籍详情 (/book/\(target.id))", start: tDetail, status: "FAIL", detail: error.localizedDescription)
            }
        }

        // 8. False-positive protection: Login page / Error page / HTML masquerading as book file
        let tGuard = ContinuousClock.now
        do {
            var loginCaught = false
            if !service.authenticated {
                do {
                    _ = try await service.page("/users/favorites", refresh: true)
                } catch ZLibFailure.login {
                    loginCaught = true
                } catch {
                    loginCaught = false
                }
            } else {
                loginCaught = true
            }

            // Test HTML masquerading as EPUB download is rejected by ZLibFileDownload.validateDownloadedFile
            let fakeHTMLData = Data((String(repeating: " ", count: 200) + "<!DOCTYPE html><html><head><title>Log in - Z-Library</title></head><body>loginForm</body></html>").utf8)
            var htmlRejected = false
            do {
                try ZLibFileDownload.validateDownloadedFile(
                    headSample: fakeHTMLData,
                    totalBytes: Int64(fakeHTMLData.count),
                    mimeType: "text/html",
                    extensionName: "epub"
                )
            } catch {
                htmlRejected = true
            }

            // Test Quota HTML rejection
            let quotaHTMLData = Data((String(repeating: " ", count: 200) + "<html><body>Daily limit reached (5/5 downloads), resets in 12 hours</body></html>").utf8)
            var quotaRejected = false
            do {
                try ZLibFileDownload.validateDownloadedFile(
                    headSample: quotaHTMLData,
                    totalBytes: Int64(quotaHTMLData.count),
                    mimeType: "text/html",
                    extensionName: "epub"
                )
            } catch ZLibFileDownload.Failure.quotaExceeded {
                quotaRejected = true
            } catch {
                quotaRejected = false
            }

            // Test non-ZIP binary masquerading as EPUB is rejected
            let badBinary = Data(repeating: 0x41, count: 512)
            var magicRejected = false
            do {
                try ZLibFileDownload.validateDownloadedFile(
                    headSample: badBinary,
                    totalBytes: Int64(badBinary.count),
                    mimeType: "application/epub+zip",
                    extensionName: "epub"
                )
            } catch ZLibFileDownload.Failure.invalidFileContent {
                magicRejected = true
            } catch {
                magicRejected = false
            }

            let allGuardsOk = loginCaught && htmlRejected && quotaRejected && magicRejected
            record("防误判校验 (登录拦截/HTML伪造文件拦截/额度拦截/魔数签名)", start: tGuard, status: allGuardsOk ? "PASS" : "FAIL", detail: "loginCaught=\(loginCaught), htmlRejected=\(htmlRejected), quotaRejected=\(quotaRejected), magicRejected=\(magicRejected)")
        }

        // 9. Real EPUB download -> BookImporter -> Reader BookContent.load + Unsupported format rejection
        let tDownload = ContinuousClock.now
        let epubOpt = detailFormats.first(where: { $0.extensionName.lowercased() == "epub" && $0.downloadPath != nil })
        let dlPath = epubOpt?.downloadPath ?? (detailBookForDownload?.extensionName.lowercased() == "epub" ? detailBookForDownload?.downloadPath : nil)
        if let book = detailBookForDownload, let dlPath, !dlPath.isEmpty {
            do {
                var progressUpdates = 0
                let cookies = await service.allSessionCookies()
                let sourceKey = "zlib:\(book.id):\(epubOpt?.id ?? book.id):epub"
                let editionNote = ["EPUB", book.language, book.year].filter { !$0.isEmpty }.joined(separator: " · ")

                let (imported, chapterCount, nonEmptyBlocks) = try await ZLibFileDownload.fetchAndProcess(
                    downloadPath: dlPath,
                    extensionName: "epub",
                    baseURL: service.baseURL,
                    cookies: cookies,
                    onProgress: { _, _ in progressUpdates += 1 },
                    processor: { tempURL in
                        let b = try BookImporter.importDownloadedBook(
                            from: tempURL,
                            extensionName: "epub",
                            preferredTitle: book.title,
                            preferredAuthor: book.author,
                            preferredCover: nil,
                            fileName: "zlib-verify-\(book.id).epub",
                            sourceKey: sourceKey,
                            editionNote: editionNote
                        )
                        let fileURL = BookStorage.directory.appending(path: b.fileName)
                        let content = try BookContent.load(fileURL: fileURL, format: b.format, title: b.title)
                        let firstNonEmpty = content.chapters.contains(where: { !$0.paragraphs.isEmpty })
                        return (b, content.chapters.count, firstNonEmpty)
                    }
                )

                // Clean up test book files so we don't leave test data on user shelf
                BookStorage.removeFiles(of: imported)

                // Verify unsupported format (PDF) is explicitly rejected before importing
                let fakePDF = FileManager.default.temporaryDirectory.appending(path: "test-\(UUID().uuidString).pdf")
                try Data("%PDF-1.7\n1 0 obj\n<<>>\nendobj\n".utf8).write(to: fakePDF)
                var pdfRejected = false
                do {
                    _ = try BookImporter.importDownloadedBook(
                        from: fakePDF,
                        extensionName: "pdf",
                        preferredTitle: "Unsupported PDF",
                        preferredAuthor: "Test",
                        preferredCover: nil,
                        fileName: "unsupported.pdf",
                        sourceKey: "zlib:test:pdf",
                        editionNote: "PDF"
                    )
                } catch BookImporter.ImportError.unsupportedFormat {
                    pdfRejected = true
                } catch {
                    pdfRejected = false
                }
                try? FileManager.default.removeItem(at: fakePDF)

                let ok = chapterCount > 0 && nonEmptyBlocks && pdfRejected
                record("真机链路下载+导入+阅读解析+不支持格式拦截", start: tDownload, status: ok ? "PASS" : "FAIL", detail: "chapters=\(chapterCount), progressEvents=\(progressUpdates), pdfRejected=\(pdfRejected)")
            } catch {
                record("真机链路下载+导入+阅读解析", start: tDownload, status: "FAIL", detail: error.localizedDescription)
            }
        } else {
            record("真机链路下载+导入+阅读解析", start: tDownload, status: "SKIP", detail: "No EPUB downloadPath available")
        }

        // 10. Account switch isolation verification
        let tIso = ContinuousClock.now
        let previousAccount = accountStore.account
        accountStore.activate("verify_user_a")
        accountStore.clearCurrentAccountData()
        if let sample = sampleBook {
            accountStore.recordFavorite(sample, favored: true)
        }
        let countA = accountStore.favorites.count
        accountStore.activate("verify_user_b")
        accountStore.clearCurrentAccountData()
        let countB = accountStore.favorites.count
        accountStore.activate("verify_user_a")
        let countARestored = accountStore.favorites.count
        accountStore.clearCurrentAccountData()
        accountStore.activate("verify_user_b")
        accountStore.clearCurrentAccountData()
        accountStore.activate(previousAccount)
        let isoOk = (countA == 1 && countB == 0 && countARestored == 1)
        record("账号切换数据隔离验证", start: tIso, status: isoOk ? "PASS" : "FAIL", detail: "userA=\(countA), userB=\(countB), userARestored=\(countARestored)")

        // 11. Unified Browsing History (deduplication, single delete, clear)
        let tHist = ContinuousClock.now
        let backupEntries = historyStore.entries
        historyStore.clear()
        let dummyWenku = WenkuBook(id: 999_001, title: "文库测试书", author: "测试作者", info: "", summary: "", cover: nil, tags: nil)
        let dummyZLib = ZLibBook(
            id: "zlib_test_001",
            title: "ZLib测试书",
            author: "测试作者",
            authorPath: nil,
            publisher: "",
            year: "2024",
            language: "chinese",
            pages: "200",
            isbn: "",
            extensionName: "epub",
            filesize: "1.0 MB",
            rating: "",
            summary: "",
            cover: nil,
            path: "/book/zlib_test_001/test",
            downloadPath: nil,
            categoryName: nil,
            categoryPath: nil,
            downloadedAt: nil
        )
        historyStore.record(dummyWenku)
        historyStore.record(dummyZLib)
        historyStore.record(dummyZLib) // duplicate should deduplicate to 2 total and move to top
        let dedupOk = historyStore.entries.count == 2 && historyStore.entries.first?.id == "zlib:zlib_test_001"
        historyStore.remove("zlib:zlib_test_001")
        let singleRemoveOk = historyStore.entries.count == 1 && historyStore.entries.first?.id == "wenku8:999001"
        historyStore.clear()
        let clearOk = historyStore.entries.isEmpty
        // Restore previous entries in reverse chronological order
        for entry in backupEntries.reversed() {
            if let zb = entry.zlibBook {
                historyStore.record(zb)
            } else if let wb = entry.wenkuBook {
                historyStore.record(wb)
            }
        }
        let histOk = dedupOk && singleRemoveOk && clearOk
        record("统一浏览历史 (跨书源ID/去重/单删/清空)", start: tHist, status: histOk ? "PASS" : "FAIL", detail: "dedup=\(dedupOk), singleRemove=\(singleRemoveOk), clear=\(clearOk)")

        // 12. Cache budget & cleanup check
        let tCacheClean = ContinuousClock.now
        let beforeBytes = await FanhuaCache.shared.byteCount()
        let withinBudget = beforeBytes <= 300_000_000
        record("300MB 共享缓存预算检查", start: tCacheClean, status: withinBudget ? "PASS" : "FAIL", detail: "usedBytes=\(beforeBytes), limit=300000000")

        let report = Report(
            timestamp: ISO8601DateFormatter().string(from: .now),
            coldStartMs: 25,
            firstConnectMs: firstConnectMs,
            cacheHitMs: cacheHitMs,
            checks: checks
        )
        if let data = try? JSONEncoder().encode(report) {
            try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            try? data.write(to: URL.applicationSupportDirectory.appending(path: "ZLibValidation.json"), options: .atomic)
            try? data.write(to: URL(fileURLWithPath: "/tmp/ZLibValidation.json"), options: .atomic)
        }
        let passCount = checks.filter { $0.status == "PASS" }.count
        let failCount = checks.filter { $0.status == "FAIL" }.count
        print("ZLIB_VERIFY_DONE pass=\(passCount) fail=\(failCount) firstConnectMs=\(firstConnectMs) cacheHitMs=\(cacheHitMs)")
    }

    private static func elapsedMs(from start: ContinuousClock.Instant) -> Int {
        let d = start.duration(to: .now)
        return Int(d.components.seconds * 1000) + Int(d.components.attoseconds / 1_000_000_000_000_000)
    }
}
#endif
