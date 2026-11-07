import SwiftUI

/// Uses the same ReaderToolbar, ReaderCard and paperGlass as Fanhua's text reader.
struct MangaReaderChrome: View {
    let title: String
    var subtitle = ""
    @Binding var position: Double
    let pageCount: Int
    let showPageNumber: Bool
    @Binding var autoPlay: Bool
    var onClose: () -> Void
    var onSettings: () -> Void
    var onComments: (() -> Void)? = nil
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil
    var previousEnabled = true
    var nextEnabled = true
    var message: String? = nil
    var readingKey = ""
    var chapters: [MangaOnlineChapter] = []
    var chapterID: String? = nil
    var onSelectChapter: ((MangaOnlineChapter) -> Void)? = nil
    var onStartAuto: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    @AppStorage("manga.reader.autoMode") private var autoKind = AutoMode.pages
    @AppStorage("manga.reader.scrollLines") private var scrollLines = 30.0
    @AppStorage("manga.reader.mode") private var mode = MangaReadingMode.pageLeftToRight
    @AppStorage("manga.reader.theme") private var theme = ReaderTheme.paper
    @AppStorage("manga.reader.menuStyle") private var menuStyle = ReaderMenuStyle.capsule
    @AppStorage("manga.reader.twoPage") private var twoPage = false
    @AppStorage("manga.reader.coverAlone") private var coverAlone = true
    @AppStorage("manga.reader.preloadCount") private var preloadCount = 2
    @AppStorage("manga.reader.autoPageSeconds") private var interval = 8.0
    @AppStorage("manga.reader.bookmarks") private var bookmarksData = Data()
    @State private var panel: ReaderPanel?
    @State private var expanded = false
    @State private var brightness = Self.currentScreen?.brightness ?? 0.5
    private static var currentScreen: UIScreen? { (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen }
    private var paper: Color { .paper }
    private var bookmarks: [String: [Int]] { (try? JSONDecoder().decode([String: [Int]].self, from: bookmarksData)) ?? [:] }
    private var savedPages: [Int] { bookmarks[readingKey] ?? [] }
    private var isBookmarked: Bool { savedPages.contains(Int(position)) }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .medium))
                        .frame(width: 40, height: 40).contentShape(.circle)
                }.buttonStyle(.plain).paperGlass(paper, in: .circle, interactive: true)
                    .accessibilityLabel("关闭阅读")
                Spacer()
                if let onComments {
                    Button(action: onComments) { Image(systemName: "text.bubble").frame(width: 40, height: 40) }
                        .buttonStyle(.plain).paperGlass(paper, in: .circle, interactive: true).accessibilityLabel("章节评论")
                }
            }.padding(.horizontal, 20)
            Spacer(minLength: 0)
            if let message { Text(message).font(.serif(12)).padding(14).background(paper, in: RoundedRectangle(cornerRadius: 16)) }
            if pageCount > 0 {
            VStack(spacing: 12) {
                if let panel { card(panel).padding(.horizontal, 16).transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity)) }
                if menuStyle == .capsule {
                    ReaderToolbar(panel: $panel, isBookmarked: isBookmarked, autoMode: autoPlay ? autoKind : nil, paper: paper, onToggleBookmark: toggleBookmark)
                } else {
                    HStack(alignment: .bottom) {
                        if autoPlay { Button { autoPlay = false } label: { Image(systemName: "pause").frame(width: 44, height: 44) }.buttonStyle(.plain).paperGlass(paper).accessibilityLabel("暂停自动翻页") }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 12) {
                            if expanded {
                                ReaderCard(paper: paper) {
                                    VStack(spacing: 0) {
                                        foldingRow("目录与书签", icon: "list.bullet", target: .contents)
                                        foldingRow("显示", icon: "circle.lefthalf.filled", target: .display)
                                        foldingRow("自动阅读", icon: "play.circle", target: .auto)
                                        Button(action: toggleBookmark) {
                                            Label(isBookmarked ? "移除书签" : "加书签", systemImage: isBookmarked ? "bookmark.fill" : "bookmark")
                                                .font(.serif(14)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        }.buttonStyle(.plain)
                                    }
                                }.frame(width: 248)
                            }
                            Button { withAnimation(.spring(duration: 0.3)) { expanded.toggle(); panel = nil } } label: {
                                Image(systemName: expanded ? "xmark" : "ellipsis").font(.system(size: 18)).frame(width: 44, height: 44)
                            }.buttonStyle(.plain).paperGlass(paper, in: .circle, interactive: true).accessibilityLabel("阅读菜单")
                        }
                    }.padding(.horizontal, 20)
                }
            }
            }
        }
        .padding(.top, -14).padding(.bottom, 26)
        .foregroundStyle(Color.ink).tint(Color.ink)
        .background {
            VStack {
                LinearGradient(colors: [paper, paper.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 60)
                Spacer()
            }.ignoresSafeArea().allowsHitTesting(false)
        }
        .background {
            if pageCount > 0 {
                Color.clear.contentShape(Rectangle()).ignoresSafeArea().onTapGesture {
                    withAnimation(.spring(duration: 0.3)) {
                        if panel != nil || expanded { panel = nil; expanded = false }
                        else { onDismiss?() }
                    }
                }
            }
        }
        .transition(.opacity)
        .onAppear { if autoPlay { panel = .auto } }
        .onChange(of: menuStyle) { panel = nil; expanded = false }
    }

    @ViewBuilder private func card(_ target: ReaderPanel) -> some View {
        switch target {
        case .contents:
            ReaderCard(paper: paper) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("目录与书签").font(.serif(17, medium: true))
                    HStack {
                        if let onPrevious { Button(action: onPrevious) { Image(systemName: "chevron.left").frame(width: 36, height: 36) }.disabled(!previousEnabled) }
                        Text(subtitle.isEmpty ? title : subtitle).font(.serif(13)).lineLimit(1).frame(maxWidth: .infinity)
                        if let onNext { Button(action: onNext) { Image(systemName: "chevron.right").frame(width: 36, height: 36) }.disabled(!nextEnabled) }
                    }.buttonStyle(.plain)
                    HStack {
                        Slider(value: $position, in: 0...Double(max(pageCount - 1, 1)), step: 1).disabled(pageCount <= 1).accessibilityLabel("阅读进度")
                        Text("\(Int(position) + 1) / \(pageCount)").font(.serif(12)).monospacedDigit().fixedSize()
                    }
                    if !savedPages.isEmpty {
                        ScrollView(.horizontal) {
                            HStack { ForEach(savedPages, id: \.self) { page in
                                Button("第 \(page + 1) 页") { position = Double(min(page, max(pageCount - 1, 0))); panel = nil }
                                    .font(.serif(12)).padding(9).background(Color.accent.opacity(0.1), in: Capsule())
                            } }
                        }.scrollIndicators(.hidden)
                    }
                    if let onSelectChapter, !chapters.isEmpty {
                        Divider().opacity(0.4)
                        ScrollView {
                            LazyVStack(spacing: 0) { ForEach(chapters) { chapter in
                                Button { onSelectChapter(chapter); panel = nil } label: {
                                    HStack {
                                        Text(chapter.title).font(.serif(13)).lineLimit(2)
                                        Spacer()
                                        Text(chapter.language).font(.serif(10)).foregroundStyle(.secondary)
                                        if chapter.id == chapterID { Image(systemName: "checkmark").foregroundStyle(Color.accent) }
                                    }.frame(minHeight: 44).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            } }
                        }.frame(maxHeight: 210)
                    }
                }
            }
        case .display:
            ReaderCard(paper: paper) {
                VStack(spacing: 16) {
                    HStack { Text("亮度").font(.serif(13)); Image(systemName: "sun.min"); Slider(value: $brightness, in: 0.05...1).onChange(of: brightness) { _, value in Self.currentScreen?.brightness = value }; Image(systemName: "sun.max") }.font(.system(size: 12))
                    HStack { Text("配色").font(.serif(13)); ChoiceRow(options: ReaderTheme.allCases, selection: $theme) { $0.label } }
                    HStack { Text("菜单").font(.serif(13)); ChoiceRow(options: ReaderMenuStyle.allCases, selection: $menuStyle) { $0.label } }
                    HStack { Text("翻页").font(.serif(13)); Spacer(); Picker("翻页方式", selection: $mode) { ForEach(MangaReadingMode.allCases) { Text($0.title).tag($0) } }.font(.serif(13)).labelsHidden() }
                    Toggle("双页展开", isOn: $twoPage).font(.serif(13)).disabled(mode != .pageLeftToRight && mode != .pageRightToLeft)
                    if twoPage { Toggle("封面单页", isOn: $coverAlone).font(.serif(13)) }
                    Stepper("预加载 \(preloadCount) 页", value: $preloadCount, in: 1...4).font(.serif(13))
                    Button("更多阅读设置", action: onSettings).font(.serif(12)).foregroundStyle(.secondary)
                }
            }
        case .auto:
            AutoCard(autoMode: autoPlay ? autoKind : nil, paper: paper, onStart: { selected in
                autoKind = selected
                if selected == .scroll { mode = .continuousTopToBottom }
                autoPlay = true
                onStartAuto?()
            }, onStop: { autoPlay = false }) {
                if autoKind == .pages {
                    SpeedDial(speed: Binding(get: { AutoMode.speed(forPageSeconds: interval) }, set: { interval = AutoMode.pageSeconds(atSpeed: $0) }),
                              title: "自动翻页", reading: String(format: "%.1f", interval), unit: "秒 / 页") { String(format: "%.0f", AutoMode.pageSeconds(atSpeed: $0)) }
                } else {
                    SpeedDial(speed: Binding(get: { AutoMode.speed(forScrollLines: scrollLines) }, set: { scrollLines = AutoMode.scrollLines(atSpeed: $0) }),
                              title: "自动下拉", reading: String(format: "%.1f", scrollLines * 24 / 60), unit: "点 / 秒") { String(format: "%.0f", AutoMode.scrollLines(atSpeed: $0) * 24 / 60) }
                }
            }
        }
    }
    private func foldingRow(_ title: String, icon: String, target: ReaderPanel) -> some View {
        Button { withAnimation(.spring(duration: 0.3)) { panel = target; expanded = false } } label: {
            HStack { Label(title, systemImage: icon); Spacer(); Image(systemName: "chevron.right").font(.system(size: 10)) }
                .font(.serif(14)).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func toggleBookmark() {
        guard pageCount > 0, !readingKey.isEmpty else { return }
        var values = bookmarks, pages = savedPages
        let page = Int(position)
        if let index = pages.firstIndex(of: page) { pages.remove(at: index) } else { pages.append(page); pages.sort() }
        values[readingKey] = pages
        if let encoded = try? JSONEncoder().encode(values) { bookmarksData = encoded }
    }
}

struct MangaReaderFooter: View {
    let title: String
    let page: Int
    let count: Int
    var body: some View {
        HStack {
            Text(title).lineLimit(1)
            Spacer(minLength: 16)
            Text("\(page + 1) / \(count)").monospacedDigit()
        }.font(.serif(10)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 6)
            .allowsHitTesting(false)
    }
}
