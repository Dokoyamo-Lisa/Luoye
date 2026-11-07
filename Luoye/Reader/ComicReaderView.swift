import SwiftUI

struct ComicReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(MangaLibrary.self) private var library
    let comic: MangaComic
    @Environment(\.systemColorScheme) private var systemScheme
    @AppStorage("manga.reader.theme") private var readerTheme = ReaderTheme.paper

    @AppStorage("manga.reader.mode") private var mode = MangaReadingMode.pageLeftToRight
    @AppStorage("manga.reader.showPageNumber") private var showPageNumber = true
    @AppStorage("manga.reader.preloadCount") private var preloadCount = 2
    @AppStorage("manga.reader.twoPage") private var twoPage = false
    @AppStorage("manga.reader.coverAlone") private var coverAlone = true
    @AppStorage("manga.reader.autoPageSeconds") private var autoPageSeconds = 8.0
    @State private var autoPlay = false
    @State private var pageShownAt = Date()
    @State private var loadedPageKeys: Set<String> = []
    @AppStorage("manga.reader.autoMode") private var autoKind = AutoMode.pages
    @AppStorage("manga.reader.scrollLines") private var scrollLines = 30.0
    @State private var page = 0
    @State private var visiblePage: Int?
    @State private var pageCount = 0
    @State private var showsControls = false
    @State private var showsSettings = false
    @State private var error: String?

    private var currentPagesReady: Bool {
        let indexes = MangaReadingNavigation.visiblePages(at: page, count: pageCount, mode: mode, twoPage: twoPage, coverAlone: coverAlone)
        return !indexes.isEmpty && indexes.allSatisfy { loadedPageKeys.contains(resource($0).key) }
    }

    private var autoPageClock: MangaAutoPageClock {
        MangaAutoPageClock(active: autoPlay && autoKind == .pages && scenePhase == .active,
                           paused: showsControls || showsSettings || !currentPagesReady, chapterID: comic.id.uuidString, page: page, count: pageCount,
                           mode: mode, twoPage: twoPage, coverAlone: coverAlone, seconds: autoPageSeconds)
    }

    private func resource(_ index: Int) -> MangaPageResource {
        .local(comic.fileURL, comic.format, index, revision: comic.contentRevision)
    }

    var body: some View {
        ZStack {
            Color.paper.ignoresSafeArea()
            if pageCount > 0 {
                if mode == .pageLeftToRight || mode == .pageRightToLeft {
                    horizontalPages
                } else {
                    scrollingPages
                }
            } else if let error {
                LuoyeEmptyState(icon: "exclamationmark.triangle", title: "这本漫画暂时打不开", message: error,
                                actionTitle: "返回书斋", action: { dismiss() })
            } else {
                ProgressView().tint(Color.accent)
            }
            if showPageNumber && pageCount > 0 { VStack { Spacer(); MangaReaderFooter(title: comic.title, page: page, count: pageCount) } }
            if autoPageClock.active && !autoPageClock.paused {
                AutoPageLine(start: pageShownAt, interval: max(3, autoPageSeconds))
            }
            Group {
                if !showsControls && autoPlay {
                    VStack { Spacer(); HStack { MangaAutoReadingControl(kind: autoKind, onShowControls: { showsControls = true }, onStop: { autoPlay = false }); Spacer(minLength: 0) } }
                }
                if showsControls || pageCount == 0 { controls }
            }.animation(.easeInOut(duration: 0.2), value: showsControls)
        }
        .environment(\.colorScheme, readerTheme.scheme(system: systemScheme))
        .tint(Color.accent)
        .modifier(ReaderMotionScope())
        .modifier(ReaderWakeLock(enabled: autoPlay))
        .sheet(isPresented: $showsSettings) { MangaReaderSettingsView() }
        .task(id: [comic.id.uuidString, resource(0).key]) {
            guard !Task.isCancelled else { return }
            pageCount = 0; loadedPageKeys = []; visiblePage = nil; error = nil
            do {
                let count = try await ComicArchive.loadPageCount(fileURL: comic.fileURL, format: comic.format)
                try Task.checkCancellation()
                pageCount = count
                page = min(max(0, comic.page), pageCount - 1)
                visiblePage = page
                library.recordPage(page, for: comic.id)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) {
                    self.error = "漫画文件已丢失或被移动，请返回书斋重新导入。"
                } else if let archiveError = error as? ComicArchive.ArchiveError {
                    self.error = archiveError.localizedDescription
                } else {
                    self.error = "漫画文件无法读取，可能已损坏或格式暂不支持。请返回书斋重新导入。"
                }
            }
        }
        .task(id: [resource(page).key, String(pageCount), String(preloadCount)]) {
            guard pageCount > 0 else { return }
            let next = (1...max(1, preloadCount)).compactMap { step -> MangaPageResource? in
                let index = page + step
                return index < pageCount ? resource(index) : nil
            }
            await MangaPageCache.shared.prefetch(next)
        }
        .onChange(of: mode) { _, _ in visiblePage = page }
        .task(id: autoPageClock) {
            let clock = autoPageClock
            guard clock.active, !clock.paused, clock.count > 0 else { return }
            pageShownAt = Date()
            do { try await Task.sleep(for: .seconds(max(3, clock.seconds))); try Task.checkCancellation() }
            catch { return }
            guard autoPageClock == clock else { return }
            guard let next = MangaReadingNavigation.nextPage(after: page, count: pageCount, mode: mode, twoPage: twoPage, coverAlone: coverAlone) else { autoPlay = false; return }
            record(next); visiblePage = page
        }
        .onDisappear { autoPlay = false }
    }

    private var horizontalPages: some View {
        let rtl = mode == .pageRightToLeft
        let layout = MangaSpreadLayout(imageCount: pageCount, coverAlone: coverAlone)
        let spreads = twoPage ? layout.spreads : (0..<pageCount).map { [$0] }
        let selected = twoPage ? layout.spread(for: page) : page
        return TabView(selection: Binding(
            get: { rtl ? spreads.count - 1 - selected : selected },
            set: { physical in
                let logical = rtl ? spreads.count - 1 - physical : physical
                if spreads.indices.contains(logical), let first = spreads[logical].first { record(first) }
            }
        )) {
            ForEach(Array(spreads.indices).sorted(by: { rtl ? $0 > $1 : $0 < $1 }), id: \.self) { spread in
                GeometryReader { viewport in
                    HStack(spacing: 0) {
                        ForEach(rtl ? Array(spreads[spread].reversed()) : spreads[spread], id: \.self) { index in
                            MangaImagePage(resource: resource(index), onLoading: { loadedPageKeys.remove(resource(index).key) }, onLoaded: { loadedPageKeys.insert(resource(index).key) }) { showsControls.toggle() }
                                .frame(width: viewport.size.width / CGFloat(spreads[spread].count), height: viewport.size.height)
                        }
                    }
                }
                .tag(rtl ? spreads.count - 1 - spread : spread)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private var scrollingPages: some View {
        GeometryReader { viewport in
            let vertical = mode.isVertical
            let indexes = Array(0..<pageCount).sorted(by: { mode.isRTL ? $0 > $1 : $0 < $1 })
            MangaScrollViewport(initialPage: page, mode: mode, visiblePage: $visiblePage) {
                ScrollView(vertical ? .vertical : .horizontal) {
                    Group {
                        if vertical {
                            LazyVStack(spacing: 0) {
                                ForEach(indexes, id: \.self) { index in
                                    MangaImagePage(resource: resource(index), fitWidth: mode.isContinuous, onLoading: { loadedPageKeys.remove(resource(index).key) }, onLoaded: { loadedPageKeys.insert(resource(index).key) }) { showsControls.toggle() }
                                        .frame(height: mode.isContinuous ? nil : viewport.size.height)
                                        .id(index)
                                        .accessibilityElement(children: .contain)
                                        .accessibilityIdentifier("manga.reader.page.\(index)")
                                }
                            }.scrollTargetLayout()
                        } else {
                            LazyHStack(spacing: 3) {
                                ForEach(indexes, id: \.self) { index in
                                    MangaImagePage(resource: resource(index), onLoading: { loadedPageKeys.remove(resource(index).key) }, onLoaded: { loadedPageKeys.insert(resource(index).key) }) { showsControls.toggle() }
                                        .frame(width: viewport.size.width, height: viewport.size.height)
                                        .id(index)
                                        .accessibilityElement(children: .contain)
                                        .accessibilityIdentifier("manga.reader.page.\(index)")
                                }
                            }.scrollTargetLayout()
                        }
                    }
                    .background(MangaAutoScrollDriver(pointsPerSecond: autoPlay && autoKind == .scroll && mode == .continuousTopToBottom && scenePhase == .active && !showsControls && !showsSettings ? scrollLines * 24 / 60 : 0, readyToScroll: currentPagesReady, contentReady: pageCount > 0 && loadedPageKeys.contains(resource(pageCount - 1).key), onReachEnd: {
                                autoPlay = false
                            }))
                }
                .mangaPageSnapping(!mode.isContinuous)
                .onChange(of: visiblePage) { _, value in if let value { record(value) } }
            }.id(mode)
        }
    }

    private var controls: some View {
        MangaReaderChrome(title: comic.title, subtitle: comic.format.uppercased(),
                          position: Binding(get: { Double(page) }, set: { record(Int($0)); visiblePage = page }),
                          pageCount: pageCount, showPageNumber: showPageNumber, autoPlay: $autoPlay,
                          onClose: { dismiss() }, onSettings: { showsSettings = true }, readingKey: comic.id.uuidString,
                          onStartAuto: { showsControls = false }, onDismiss: { showsControls = false })
    }

    private func record(_ index: Int) {
        guard index >= 0, index < pageCount, page != index else { return }
        page = index
        visiblePage = index
        library.recordPage(index, for: comic.id)
    }
}
