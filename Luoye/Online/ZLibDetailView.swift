import SwiftUI
import SwiftData
import UIKit

struct ZLibDetailView: View {
    let book: ZLibBook
    @Environment(BrowsingHistoryStore.self) private var history
    @Environment(ZLibAccountStore.self) private var accountStore
    @Environment(ZLibService.self) private var service
    @Environment(\.modelContext) private var modelContext
    @Query private var savedBooks: [Book]

    @State private var details: ZLibBook?
    @State private var formats: [ZLibFormatOption] = []
    @State private var selectedFormatID: String = ""
    @State private var relatedBooks: [ZLibBook] = []
    @State private var booklists: [ZLibBooklist] = []
    @State private var isFavorite = false
    @State private var loading = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadRequest = UUID()
    @State private var downloadedBytes: Int64 = 0
    @State private var expectedBytes: Int64?
    @State private var error: String?
    @State private var errorRequiresLogin = false
    @State private var errorRequiresChallenge = false
    @State private var notice: String?
    @State private var readingBook: Book?
    @State private var loginSheet = false
    @State private var challengeSheet = false

    private var display: ZLibBook { details ?? book }
    private var isDownloading: Bool { downloadTask != nil }

    private var availableFormats: [ZLibFormatOption] {
        if !formats.isEmpty { return formats }
        if !display.extensionName.isEmpty {
            return [
                ZLibFormatOption(
                    id: display.id,
                    extensionName: display.extensionName.lowercased(),
                    filesize: display.filesize,
                    downloadPath: display.downloadPath,
                    isLowQuality: false,
                    isPrimary: true
                )
            ]
        }
        return []
    }

    private var selectedOption: ZLibFormatOption? {
        availableFormats.first { $0.id == selectedFormatID } ?? availableFormats.first
    }

    private func existingShelfBook(for option: ZLibFormatOption) -> Book? {
        let key = "zlib:\(option.id)"
        let ext = option.extensionName.lowercased()
        let expectedFile = "zlib-\(option.id).\(ext)"
        return savedBooks.first { ($0.sourceKey == key || $0.fileName == expectedFile) && BookImportCommit.hasLocalFile($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                actionSection
                metadataSection
                Divider()
                summarySection
                if !booklists.isEmpty {
                    Divider()
                    booklistsSection
                }
                if !relatedBooks.isEmpty {
                    Divider()
                    relatedSection
                }
            }
            .luoyeContentMargins(top: 16, maximumWidth: 900)
        }
        .background(Color.paper)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .navigationTitle("书籍详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await toggleFavorite() }
                } label: {
                    Image(systemName: isFavorite ? "bookmark.fill" : "bookmark")
                }
                .accessibilityLabel(isFavorite ? "移出账号书库" : "加入账号书库")
            }
        }
        .navigationDestination(for: ZLibFacet.self) { ZLibCollectionView(facet: $0) }
        .navigationDestination(for: ZLibBooklist.self) { ZLibBooklistDetailView(booklist: $0) }
        .navigationDestination(for: ZLibBook.self) { ZLibDetailView(book: $0) }
        .task(id: "\(book.id)|\(service.authenticated)") {
            await load()
        }
        .onDisappear { cancelDownload() }
        .onChange(of: service.accountKey) { old, _ in if old != nil { cancelDownload() } }
        .sheet(isPresented: $loginSheet) { ZLibLoginView() }
        .sheet(isPresented: $challengeSheet, onDismiss: { Task { await service.refreshSession(); await load(refresh: true) } }) {
            ZLibVerificationView()
        }
        .fullScreenCover(item: $readingBook) { ReaderView(book: $0) }
    }

    // MARK: - Subviews

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 20) {
            coverView
                .frame(width: 112, height: 163)
            VStack(alignment: .leading, spacing: 10) {
                Text(display.title)
                    .font(.serif(21, medium: true))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if display.author.isEmpty {
                    Text("Z-Library")
                        .font(.serif(14))
                        .foregroundStyle(.secondary)
                } else {
                    let authorPath = display.authorPath ?? "/author/\(display.author.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? display.author)"
                    NavigationLink(value: ZLibFacet(name: display.author, group: "作者作品", count: nil, path: authorPath)) {
                        Label(display.author, systemImage: "person")
                            .font(.serif(14))
                            .multilineTextAlignment(.leading)
                    }
                }

                HStack(spacing: 8) {
                    Text("Z-LIB · \(display.id)")
                        .font(.system(size: 10, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(.secondary)
                    if !display.rating.isEmpty {
                        Label(display.rating, systemImage: "star.fill")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tint)
                    }
                }

                if !display.briefInfo.isEmpty {
                    Text(display.briefInfo)
                        .font(.serif(12))
                        .foregroundStyle(.secondary)
                }
                if let quota = service.quota {
                    Text(quota.summaryText)
                        .font(.serif(11))
                        .foregroundStyle(quota.isExhausted ? .red : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !availableFormats.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("版本与格式")
                            .font(.serif(14, medium: true))
                            .foregroundStyle(Color.ink)
                        Spacer()
                        Text("支持 \(BookImporter.supportedExtensionsDisplay)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(availableFormats) { option in
                                let selected = selectedOption?.id == option.id
                                let inShelf = existingShelfBook(for: option) != nil
                                Button {
                                    selectedFormatID = option.id
                                    error = nil
                                    notice = nil
                                } label: {
                                    HStack(spacing: 6) {
                                        if inShelf {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 11))
                                        } else if !option.isSupportedByReader {
                                            Image(systemName: "exclamationmark.circle")
                                                .font(.system(size: 11))
                                        }
                                        Text(option.displayLabel)
                                            .font(.serif(12, medium: selected))
                                        if option.isPrimary && availableFormats.count > 1 {
                                            Text("当前版")
                                                .font(.system(size: 9))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Color.ink.opacity(0.08), in: Capsule())
                                        }
                                    }
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 8)
                                    .foregroundStyle(
                                        selected ? Color.ink : (option.isSupportedByReader ? Color.ink : .secondary)
                                    )
                                    .background(
                                        selected ? Color.accentColor.opacity(0.24) : Color.ink.opacity(0.045),
                                        in: Capsule()
                                    )
                                    .overlay {
                                        if selected {
                                            Capsule().stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(isDownloading)
                            }
                        }
                    }
                }
            }

            if let option = selectedOption, !option.isSupportedByReader {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "当前阅读器暂不支持 \(option.extensionName.uppercased()) 格式，无法直接导入阅读。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    if let readable = availableFormats.first(where: \.isSupportedByReader) {
                        Button("切换到 \(readable.displayLabel)") {
                            selectedFormatID = readable.id
                        }
                        .font(.footnote)
                        .buttonStyle(.bordered)
                    } else {
                        Text("可点击作者或搜索书名，查找 \(BookImporter.supportedExtensionsDisplay) 版本的同书条目。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            }

            if isDownloading {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if let expectedBytes, expectedBytes > 0 {
                            let fraction = min(1.0, max(0.0, Double(downloadedBytes) / Double(expectedBytes)))
                            Text("正在下载 · \(Int(fraction * 100))%")
                                .font(.serif(13, medium: true))
                            Spacer()
                            Text("\(Self.formatBytes(downloadedBytes)) / \(Self.formatBytes(expectedBytes))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("正在获取书籍文件…")
                                .font(.serif(13, medium: true))
                            Spacer()
                            if downloadedBytes > 0 {
                                Text(Self.formatBytes(downloadedBytes))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let expectedBytes, expectedBytes > 0 {
                        ProgressView(value: min(Double(downloadedBytes), Double(expectedBytes)), total: Double(expectedBytes))
                            .tint(.accentColor)
                    } else {
                        ProgressView().tint(.accentColor)
                    }
                    HStack {
                        Text("下载完成后将校验电子书结构并导入书斋")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("取消下载", role: .cancel) {
                            cancelDownload()
                        }
                        .font(.caption)
                    }
                }
                .padding(14)
                .background(Color.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            } else {
                let alreadySaved = selectedOption.flatMap(existingShelfBook(for:)) != nil
                let canDownload = selectedOption?.isSupportedByReader ?? false
                HStack(spacing: 12) {
                    Button {
                        startDownload(readAfterImport: true)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: alreadySaved ? "book" : "arrow.down.circle")
                            Text(alreadySaved ? "打开阅读" : "开始阅读")
                                .font(.serif(15, medium: true))
                        }
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            canDownload ? Color.accentColor.opacity(0.16) : Color.accentColor.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canDownload)

                    Button {
                        startDownload(readAfterImport: false)
                    } label: {
                        Image(systemName: alreadySaved ? "checkmark.circle" : "plus")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.ink)
                            .frame(width: 48, height: 48)
                            .background(Color.ink.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canDownload)
                    .accessibilityLabel(alreadySaved ? "已在书斋" : "加入书斋")
                }
            }

            if let notice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.tint)
            }

            if let error {
                VStack(alignment: .leading, spacing: 10) {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        if errorRequiresLogin || !service.authenticated {
                            Button("登录 Z-Library") { loginSheet = true }
                                .buttonStyle(.borderedProminent)
                        }
                        if errorRequiresChallenge {
                            Button("完成安全验证") { challengeSheet = true }
                                .buttonStyle(.bordered)
                        }
                        Button("重试") {
                            if details == nil {
                                Task { await load(refresh: true) }
                            } else {
                                startDownload(readAfterImport: false)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    @ViewBuilder
    private var metadataSection: some View {
        let rows: [(String, String)] = [
            ("出版社", display.publisher),
            ("出版年份", display.year),
            ("语言", ZLibBook.localizedLanguage(display.language)),
            ("页数", display.pages),
            ("ISBN", display.isbn),
            ("文件格式", display.extensionName.uppercased()),
            ("文件大小", display.filesize)
        ].filter { !$0.1.isEmpty && $0.1 != "0" }

        VStack(alignment: .leading, spacing: 10) {
            if let catName = display.categoryName, !catName.isEmpty, let catPath = display.categoryPath, !catPath.isEmpty {
                NavigationLink(value: ZLibFacet(name: catName, group: "分类浏览", count: nil, path: catPath)) {
                    HStack(spacing: 6) {
                        Image(systemName: "tag")
                        Text(catName)
                        Image(systemName: "chevron.right").font(.system(size: 10))
                    }
                    .font(.serif(12))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if !rows.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(rows, id: \.0) { label, value in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(value)
                                .font(.serif(13))
                                .foregroundStyle(Color.ink)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(14)
                .background(Color.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("内容简介")
                .font(.serif(20, medium: true))
                .foregroundStyle(Color.ink)
            if loading && display.summary.isEmpty {
                ProgressView("正在读取书籍资料…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                Text(display.summary.isEmpty ? "暂无简介" : display.summary)
                    .font(.serif(16))
                    .lineSpacing(8)
                    .foregroundStyle(Color.ink)
                    .textSelection(.enabled)
            }
        }
    }

    private var booklistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("收录书单")
                    .font(.serif(20, medium: true))
                    .foregroundStyle(Color.ink)
                Spacer()
                Text("\(booklists.count) 个")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ZLibBooklistStack(booklists: Array(booklists.prefix(8)))
        }
    }

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("延伸阅读")
                .font(.serif(20, medium: true))
                .foregroundStyle(Color.ink)
            ZLibBookGrid(books: Array(relatedBooks.prefix(12)))
        }
    }

    private var coverView: some View {
        LuoyeRemoteCover(
            title: display.title,
            coverURLString: display.cover,
            badge: (selectedOption?.extensionName ?? display.extensionName)
        )
    }

    // MARK: - Actions

    private func load(refresh: Bool = false) async {
        history.record(display)
        if selectedFormatID.isEmpty {
            selectedFormatID = display.id
        }
        guard !display.path.isEmpty else { return }
        loading = true
        error = nil
        errorRequiresLogin = false
        errorRequiresChallenge = false
        defer { loading = false }

        do {
            let page = try await service.page(display.path, refresh: refresh)
            if var fetched = page.books.first {
                if fetched.cover == nil { fetched.cover = book.cover }
                if fetched.language.isEmpty { fetched.language = book.language }
                if fetched.year.isEmpty { fetched.year = book.year }
                if fetched.publisher.isEmpty { fetched.publisher = book.publisher }
                if fetched.extensionName.isEmpty { fetched.extensionName = book.extensionName }
                if fetched.filesize.isEmpty { fetched.filesize = book.filesize }
                if fetched.downloadPath == nil { fetched.downloadPath = book.downloadPath }
                details = fetched
                history.updateMetadata(fetched)
                accountStore.update(fetched)
            }
            if !page.formats.isEmpty {
                formats = page.formats
                if let current = selectedOption, current.isSupportedByReader {
                    selectedFormatID = current.id
                } else if let firstSupported = page.formats.first(where: \.isSupportedByReader) {
                    selectedFormatID = firstSupported.id
                } else if let first = page.formats.first {
                    selectedFormatID = first.id
                }
            }
            relatedBooks = page.relatedBooks
            booklists = page.booklists
            isFavorite = page.isFavorite
        } catch is CancellationError {
        } catch let failure as ZLibFailure {
            handleFailure(failure)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startDownload(readAfterImport: Bool) {
        guard downloadTask == nil else { return }
        guard let option = selectedOption else {
            error = "未找到可下载的版本信息。"
            return
        }
        guard option.isSupportedByReader else {
            error = BookImporter.ImportError.unsupportedFormat(option.extensionName).localizedDescription
            return
        }

        // 检查该具体版本是否已经在书斋中（区分同一本书的不同版本/格式/语言）
        if let saved = existingShelfBook(for: option) {
            if readAfterImport {
                readingBook = saved
            } else {
                notice = "该版本（\(option.displayLabel)）已经在书斋里了。"
            }
            return
        }

        guard let dlPath = option.downloadPath, !dlPath.isEmpty else {
            errorRequiresLogin = true
            error = "该版本需要登录 Z-Library 账号后获取。"
            loginSheet = true
            return
        }

        error = nil
        errorRequiresLogin = false
        errorRequiresChallenge = false
        notice = nil
        downloadedBytes = 0
        expectedBytes = nil

        let request = UUID(); downloadRequest = request
        downloadTask = Task { @MainActor in
            defer { if downloadRequest == request { downloadTask = nil } }
            do {
                await service.refreshSession()
                let account = service.accountKey
                let cookies = await service.allSessionCookies()
                let coverData = await fetchCoverData()
                try Task.checkCancellation()
                guard downloadRequest == request, service.accountKey == account else { throw CancellationError() }
                let editionParts = [
                    option.extensionName.uppercased(),
                    ZLibBook.localizedLanguage(display.language),
                    option.filesize
                ].filter { !$0.isEmpty }
                let editionNote = editionParts.joined(separator: " · ")
                let ext = option.extensionName.lowercased()
                let targetFileName = "zlib-\(option.id)-\(UUID().uuidString).\(ext)"
                let sourceKey = "zlib:\(option.id)"

                let title = display.title, author = display.author
                let prepared = try await ZLibFileDownload.fetchAndProcess(
                    downloadPath: dlPath,
                    extensionName: ext,
                    baseURL: service.baseURL,
                    cookies: cookies,
                    onProgress: { received, expected in
                        guard self.downloadRequest == request else { return }
                        self.downloadedBytes = received
                        self.expectedBytes = expected
                    },
                    processor: { tempURL in
                        PreparedBookImport(try BookImporter.importDownloadedBook(
                            from: tempURL,
                            extensionName: ext,
                            preferredTitle: title,
                            preferredAuthor: author,
                            preferredCover: coverData,
                            fileName: targetFileName,
                            sourceKey: sourceKey,
                            editionNote: editionNote
                        ))
                    }
                )

                guard downloadRequest == request, service.accountKey == account else { prepared.removeFiles(); throw CancellationError() }
                let importedBook = try BookImportCommit.commit(prepared, context: modelContext, legacyFileName: "zlib-\(option.id).\(ext)")

                accountStore.recordLocalDownload(display)
                notice = "已加入书斋（\(option.displayLabel)）"
                if readAfterImport {
                    readingBook = importedBook
                }
                Task { await service.refreshQuotaIfNeeded() }
            } catch is CancellationError {
                if downloadRequest == request { notice = "已取消下载" }
            } catch let dlFailure as ZLibFileDownload.Failure {
                guard downloadRequest == request, !Task.isCancelled else { return }
                switch dlFailure {
                case .loginRequired, .missingDownloadLink:
                    errorRequiresLogin = true
                case .challengeRequired:
                    errorRequiresChallenge = true
                default:
                    break
                }
                error = dlFailure.localizedDescription
            } catch let zFailure as ZLibFailure {
                guard downloadRequest == request, !Task.isCancelled else { return }
                handleFailure(zFailure)
            } catch {
                if downloadRequest == request && !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func cancelDownload() {
        let wasDownloading = downloadTask != nil
        downloadTask?.cancel(); downloadRequest = UUID(); downloadTask = nil
        if wasDownloading { notice = "已取消下载" }
    }

    private func toggleFavorite() async {
        await service.refreshSession()
        guard service.authenticated else {
            loginSheet = true
            return
        }
        let target = !isFavorite
        do {
            try await service.setFavorite(bookId: display.id, favorite: target)
            isFavorite = target
            accountStore.recordFavorite(display, favored: target)
            notice = target ? "已收藏至 Z-Library 账号书库" : "已从账号书库移除"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func fetchCoverData() async -> Data? {
        guard let raw = display.cover, let url = URL(string: raw), url.scheme == "https" else {
            return nil
        }
        if let cached = await FanhuaCache.shared.data(for: url.absoluteString), UIImage(data: cached) != nil {
            return cached
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("https://z-lib.sk/", forHTTPHeaderField: "Referer")
        if let (data, response) = try? await FanhuaNetwork.session.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           data.count < 5_000_000,
           UIImage(data: data) != nil {
            await FanhuaCache.shared.store(data, for: url.absoluteString)
            return data
        }
        return nil
    }

    private func handleFailure(_ failure: ZLibFailure) {
        switch failure {
        case .login:
            errorRequiresLogin = true
        case .challenge:
            errorRequiresChallenge = true
        default:
            break
        }
        error = failure.localizedDescription
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_048_576 {
            return String(format: "%.2f MB", Double(bytes) / 1_048_576.0)
        }
        return String(format: "%.0f KB", max(1, Double(bytes) / 1024.0))
    }
}
