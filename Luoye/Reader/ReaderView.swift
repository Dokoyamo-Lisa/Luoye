import SwiftData
import SwiftUI

/// 阅读页：全屏正文，左右翻页或自动滚动；点中间呼出菜单。
struct ReaderView: View {
    let book: Book
    private let bodyFontName: String?
    private let bodyFontURL: URL?
    private let providedChapter: Chapter?
    private let isInteractionSuspended: Bool
    private let onForwardBoundary: ((AutoMode?) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// 窗口的深浅色（不受本页强制配色影响），「跟随系统」就跟它走
    @Environment(\.systemColorScheme) private var systemScheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("reader.fontSize") private var fontSize = 19.0
    @AppStorage("reader.lineHeight") private var lineHeight = ReaderLineHeight.comfortable
    @AppStorage("reader.theme") private var theme = ReaderTheme.system
    /// 自动滚动的速度：每分钟走过几行
    @AppStorage("reader.scrollLines") private var scrollLines = 30.0
    /// 自动翻页的速度：每页停留几秒
    @AppStorage("reader.pageSeconds") private var pageSeconds = 15.0
    @AppStorage("reader.menuStyle") private var menuStyle = ReaderMenuStyle.capsule
    @AppStorage("reader.pageMode") private var pageMode = ReaderPageMode.paged

    @State private var content: BookContent?
    @State private var failed = false
    @State private var position: ReadingPosition
    @State private var showingChrome = false
    /// 菜单上方弹出的卡片
    @State private var panel: ReaderPanel?
    /// 折叠菜单是否展开
    @State private var menuExpanded = false
    @Namespace private var menuGlass
    /// 底部胶囊上方那张卡片当前的高度；换卡片时由它带着卡片平滑地变高变矮
    @State private var cardHeight: CGFloat?
    /// 卡片已经开着、只是换成另一张（目录 ↔ 显示 ↔ 自动阅读）；刚打开时里面的内容不用再等着淡入
    @State private var cardSwitching = false
    /// 屏幕上正在显示的菜单样式；跟着设置走，但切换时一定带动画
    @State private var shownMenuStyle: ReaderMenuStyle?
    @State private var autoMode: AutoMode?
    @State private var boundaryHandled = false
    @State private var forwardTurns = 0
    @State private var pageInteractionID: UUID?
    @State private var pageInteractionRevision = 0
    @State private var scrollInteractionID: UUID?
    @State private var adjustingScrollSpeed = false
    @State private var pageShownAt = Date.now
    @State private var showingSpeedDial = false
    /// 翻页模式下当前页的字符范围；书签落在这里就算在这一页
    @State private var pageRange = 0 ..< 0
    @State private var renderedLengths: [Int: Int] = [:]
    /// 点注释标号后弹出的注释全文
    @State private var noteText: String?
    /// 阅读页的安全区。iPhone 有灵动岛和较高的底部横条，iPad 隐藏状态栏后顶部几乎没有，菜单位置要按它算。
    @State private var safeInsets = EdgeInsets()
    /// 整个阅读区（含安全区）的大小；滚动模式的上下渐隐、页脚按它算出的正文边距摆放
    @State private var viewportSize = CGSize.zero
    @Query private var bookmarks: [Bookmark]

    /// 从书籍详情的目录点进来时要直接打开的章节：章名，以及它在网页目录里的序号（按章名找不到时用）
    private let startChapter: (title: String, index: Int)?

    init(book: Book, startChapter: (title: String, index: Int)? = nil, bodyFontName: String? = nil, bodyFontURL: URL? = nil, providedChapter: Chapter? = nil, initialAutoMode: AutoMode? = nil, isInteractionSuspended: Bool = false, onForwardBoundary: ((AutoMode?) -> Void)? = nil) {
        self.book = book
        self.bodyFontName = bodyFontName
        self.bodyFontURL = bodyFontURL
        self.providedChapter = providedChapter
        self.onForwardBoundary = onForwardBoundary
        self.isInteractionSuspended = isInteractionSuspended
        _autoMode = State(initialValue: initialAutoMode)
        self.startChapter = startChapter
        _position = State(initialValue: ReadingPosition(chapter: book.readingChapter, offset: book.readingOffset))
        let id = book.id
        _bookmarks = Query(filter: #Predicate<Bookmark> { $0.bookID == id }, sort: \.createdAt, order: .reverse)
    }

    /// 正文是上下连续滚动的：选了上下滚动，或正在自动滚动（自动翻页时仍用左右翻页）。
    private var usesScroll: Bool {
        autoMode == .scroll || (autoMode == nil && pageMode == .scroll)
    }

    /// 落在当前这一页的书签（滚动时按屏幕顶端往后约 300 字算）
    private var bookmarkHere: Bookmark? {
        let range = usesScroll ? position.offset ..< position.offset + 300 : pageRange
        return bookmarks.first { $0.chapter == position.chapter && range.contains($0.offset) }
    }

    private func toggleBookmark(content: BookContent) {
        if let existing = bookmarkHere {
            modelContext.delete(existing)
        } else {
            let chapter = content.chapters[min(position.chapter, content.chapters.count - 1)]
            let text = style.attributedText(for: chapter).string
            // 翻页时记在这一页的页首，摘录从页首取。
            let offset = usesScroll || pageRange.isEmpty ? position.offset : pageRange.lowerBound
            modelContext.insert(Bookmark(
                bookID: book.id,
                chapter: position.chapter,
                offset: offset,
                chapterTitle: chapter.title,
                excerpt: Bookmark.excerpt(from: text, at: offset, skippingTitle: chapter.title)
            ))
        }
        try? modelContext.save()
    }

    private var automaticReadingPaused: Bool {
        if isInteractionSuspended || scenePhase != .active || noteText != nil { return true }
        if autoMode == .scroll {
            // A tap pauses reading through the open menu. The speed dial itself
            // still previews changes live while it is being dragged.
            return scrollInteractionID != nil || (showingChrome && !adjustingScrollSpeed)
        }
        return showingChrome || showingSpeedDial || pageInteractionID != nil
    }

    private var scheme: ColorScheme { theme.scheme(system: systemScheme) }


    private var style: ReaderStyle {
        ReaderStyle(fontSize: fontSize, lineHeight: lineHeight.multiplier, scheme: scheme, bodyFontName: bodyFontName, bodyFontURL: bodyFontURL, recognizesByline: providedChapter == nil)
    }

    var body: some View {
        ZStack {
            Color(style.background).ignoresSafeArea()

            if let content {
                GeometryReader { proxy in
                    let safe = proxy.safeAreaInsets
                    let size = CGSize(width: proxy.size.width + safe.leading + safe.trailing,
                                      height: proxy.size.height + safe.top + safe.bottom)
                    let spread = usesSpread(size: size)
                    let insets = pageInsets(size: size, safe: safe, spread: spread)
                    Group {
                        if usesScroll {
                            ScrollReader(
                                content: content,
                                style: style,
                                size: size,
                                insets: insets,
                                position: $position,
                                // 手动上下滚动时速度为 0，只跟着手指走。
                                speed: autoMode == .scroll && !automaticReadingPaused ? CGFloat(scrollLines) * style.linePitch / 60 : 0,
                                onTap: toggleChrome,
                                onReachEnd: reachEnd,
                                onChapterLength: recordChapterLength,
                                onManualScrollChanged: { owner, active in
                                    if active {
                                        scrollInteractionID = owner
                                        if autoMode == .scroll && showingChrome {
                                            withAnimation(.easeOut(duration: 0.18)) {
                                                showingChrome = false
                                                panel = nil
                                                menuExpanded = false
                                                showingSpeedDial = false
                                            }
                                        }
                                    } else if scrollInteractionID == owner {
                                        scrollInteractionID = nil
                                    }
                                }
                            )
                        } else {
                            PagedReader(
                                content: content,
                                style: style,
                                size: size,
                                insets: insets,
                                position: $position,
                                onTapCenter: toggleChrome,
                                onNote: { note in
                                    withAnimation(.spring(duration: 0.3)) { noteText = note }
                                },
                                onPageRange: { pageRange = $0 },
                                onChapterLength: recordChapterLength,
                                // 自动阅读时左下角让给小胶囊；菜单打开、小胶囊收起时，章名回到页脚。
                                showsFooterTitle: autoMode == nil || showingChrome,
                                menuShown: showingChrome,
                                forwardTurns: forwardTurns,
                                onReachEnd: reachEnd,
                                onInteractionChanged: { owner, active in
                                    if active { pageInteractionID = owner }
                                    else if pageInteractionID == owner {
                                        pageInteractionID = nil
                                        pageInteractionRevision += 1
                                    }
                                },
                                columns: spread ? 2 : 1,
                                columnGap: spread ? Self.spreadGap : 0
                            )
                        }
                    }
                    // 翻页和滚动互换时：旧的正文先淡到纸色，新的再从纸色里浮出来。
                    // 两种排法的行位置不完全一样，同时叠着淡入淡出会出现重影，所以前后错开、不重叠。
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.14)),
                        removal: .opacity.animation(.easeIn(duration: 0.12))
                    ))
                    .ignoresSafeArea()
                }
                .transition(.opacity)

                if autoMode == .pages && !automaticReadingPaused {
                    AutoPageLine(start: pageShownAt, interval: pageSeconds)
                }
                if usesScroll {
                    ScrollEdges(background: Color(style.background), insets: readerInsets, safeTop: safeInsets.top)
                }
                if usesScroll {
                    // 自动滚动且菜单收起时，左下角是自动阅读小胶囊（后面跟着章名），这里只留右边的进度和时间。
                    ScrollFooter(chapterTitle: ChapterTitle.parts(content.chapters[min(position.chapter, content.chapters.count - 1)].title).name,
                                 progress: progressText(content), color: Color(style.secondary), side: readerInsets.left,
                                 showsTitle: autoMode == nil || showingChrome,
                                 bottom: Self.footerCenter(safeBottom: safeInsets.bottom) - 7.5)
                }
            } else if failed {
                VStack(spacing: 10) {
                    Text("这本书打不开")
                        .font(.serif(18, medium: true))
                    Text("文件可能已损坏，或编码暂不支持。")
                        .font(.serif(14))
                        .foregroundStyle(.secondary)
                    Button("返回书斋") { dismiss() }
                        .font(.serif(15))
                        .padding(.top, 12)
                }
            } else {
                ProgressView()
            }

            // 书签丝带：翻到有书签的页时从上方垂下，离开时收回。
            ZStack {
                if bookmarkHere != nil {
                    BookmarkRibbon()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.4, bounce: 0.25), value: bookmarkHere != nil)

            if let content {
                chrome(content: content)
            }
            if !showingChrome, let autoMode, let content {
                miniAutoControl(autoMode)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if showingSpeedDial, let autoMode {
                floatingSpeedDial(autoMode)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let noteText {
                NoteCard(text: noteText, paper: Color(style.background)) {
                    withAnimation(.spring(duration: 0.3)) { self.noteText = nil }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // 菜单、目录也跟着正文配色走。总是给出明确的深浅色，不传 nil（传 nil 有时恢复不了）。
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { safeInsets = $0 }
        .onGeometryChange(for: CGSize.self) { proxy in
            CGSize(width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                   height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
        } action: { viewportSize = $0 }
        .modifier(ReaderMotionScope())
        .preferredColorScheme(scheme)
        .eyeCareFilter()
        .statusBarHidden()
        .task { await load() }
        // 菜单和手动拖动时暂缓自动阅读；结束后从完整间隔重新计时。
        .task(id: "\(autoMode == .pages)-\(position.chapter)-\(position.offset)-\(pageSeconds)-\(automaticReadingPaused)-\(pageInteractionRevision)") {
            guard autoMode == .pages, !automaticReadingPaused else { return }
            pageShownAt = .now
            try? await Task.sleep(for: .seconds(pageSeconds))
            if !Task.isCancelled { forwardTurns += 1 }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: bookmarks.count)
        .modifier(ReaderWakeLock(enabled: autoMode != nil))
        // 换配色、换翻页方式（含开始/停止自动滚动）：整屏淡入淡出，不生硬地一下子跳过去。
        .onChange(of: theme) { crossfadeWindow() }
        // 翻页方式、菜单样式存在 AppStorage 里，改动时不一定带着动画；这里统一补上。
        .animation(.easeInOut(duration: 0.25), value: usesScroll)
        .onChange(of: menuStyle) { _, style in
            withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
                shownMenuStyle = style
                // 换了菜单样式，上一种样式里打开的卡片一并收起。
                panel = nil
                menuExpanded = false
            }
        }
        .onChange(of: position) { _, new in
            book.readingChapter = new.chapter
            book.readingOffset = new.offset
            if let content, renderedLengths[new.chapter] != nil { book.progress = progress(content) }
            book.lastOpenedAt = .now
            // 每翻一页（滚动时每半秒）就存，App 被直接关掉也不会丢进度。
            try? modelContext.save()
        }
    }

    /// 正文边距。宽度取整到「一行正好 N 个字」，高度取整到「一页正好 N 行」，
    /// 这样每行字距一致、行与行对齐。iPad 上另外限制一行的宽度。
    /// 页脚那一行（章名、页码/进度、时间）的中线离屏幕底边多远；与翻页模式里每页的页脚算法一致。
    static func footerCenter(safeBottom: CGFloat) -> CGFloat {
        max(safeBottom, 20) + 14
    }

    /// 当前的正文边距（与阅读区里实际排版用的同一套算法）
    private var readerInsets: UIEdgeInsets {
        guard viewportSize.width > 0 else { return UIEdgeInsets(top: 86, left: 31, bottom: 80, right: 31) }
        return pageInsets(size: viewportSize, safe: safeInsets, spread: usesSpread(size: viewportSize))
    }

    /// 书脊两侧正文之间的留白
    private static let spreadGap: CGFloat = 96

    /// iPad 横屏翻页：摊开成左右两页，像一本书。竖屏、手机、分屏变窄时仍是一页。
    private func usesSpread(size: CGSize) -> Bool {
        !usesScroll && sizeClass == .regular && size.width > size.height && size.width >= 960
    }

    private func pageInsets(size: CGSize, safe: EdgeInsets, spread: Bool = false) -> UIEdgeInsets {
        let regular = sizeClass == .regular
        let side: CGFloat
        if spread {
            // 每栏一行正好 N 个字，最多约 560 点宽；两栏加书脊留白后左右居中。
            let available = (size.width - 64 * 2 - Self.spreadGap) / 2
            let characters = floor(min(available, 560) / style.fontSize)
            side = (size.width - characters * style.fontSize * 2 - Self.spreadGap) / 2
        } else {
            let maxLineWidth: CGFloat = 680
            let minimumSide = max(regular ? 64 : 28, (size.width - maxLineWidth) / 2)
            let columns = floor((size.width - minimumSide * 2) / style.fontSize)
            side = (size.width - columns * style.fontSize) / 2
        }

        let top = max(safe.top, 20) + (regular ? 40 : 24)
        let minimumBottom = max(safe.bottom, 16) + (regular ? 52 : 40)
        let pitch = style.linePitch
        let rows = floor((size.height - top - minimumBottom) / pitch)
        // 多出的零头留在底部；加 1 点余量，免得最后一行因为小数误差被挤到下一页。
        let bottom = size.height - top - rows * pitch - 1
        return UIEdgeInsets(top: top, left: side, bottom: bottom, right: side)
    }

    /// 点中间呼出的菜单：顶部左边返回、正中一行淡淡的书名；底部按设置用小胶囊或折叠菜单。
    private func chrome(content: BookContent) -> some View {
        let paper = Color(style.background)
        let current = min(position.chapter, content.chapters.count - 1)
        // 常驻在最上层；收起时里面是空的，点击会直接落到正文上。
        return VStack(spacing: 12) {
            if showingChrome {
                // 只有返回：放在灵动岛左侧那一行，不压正文。章名和进度在页脚。
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 40, height: 40)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .paperGlass(paper, in: .circle, interactive: true)
                    .accessibilityLabel("关闭阅读")
                    Spacer()
                }
                .padding(.horizontal, 20)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer(minLength: 0)

            if showingChrome {
                VStack(spacing: 12) {
                    // 换菜单样式：底部胶囊往下沉着收起，右下角的 ⋯ 从角落里长出来；反过来亦然。
                    switch shownMenuStyle ?? menuStyle {
                    case .capsule:
                        VStack(spacing: 12) {
                            capsuleMenu(content: content, current: current, paper: paper)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)).combined(with: .offset(y: 20)))
                    case .folding:
                        VStack(spacing: 12) {
                            foldingMenu(content: content, current: current, paper: paper)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.5, anchor: .bottomTrailing)))
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // 有灵动岛时稍稍上移，返回按钮落在灵动岛下方、正文第一行之上；
        // iPad 这类顶部没有安全区的屏幕，离上边留出一点距离，不被切掉。
        .padding(.top, safeInsets.top >= 40 ? -14 : max(14 - safeInsets.top, 0))
        // 菜单停在页脚（章名、页码，离屏幕底边 33 点）上方，不压住它们；底部安全区较矮的 iPad 也一样。
        .padding(.bottom, max(26, 60 - safeInsets.bottom))
        .tint(Color(style.text))
        .foregroundStyle(Color(style.text))
        .background {
            // 菜单背后用纸色轻轻晕开，菜单不与正文相叠。不拦触摸：空白处仍可上下滑动正文、收起菜单。
            if showingChrome {
                MenuEdges(background: paper)
                    .transition(.opacity)
            }
        }
    }

    /// 读到全书的几成（0…1，按章和章内位置估算）。
    private func progress(_ content: BookContent) -> Double {
        ReaderProgress.fraction(position: position, chapters: content.chapters, renderedLength: renderedLengths[position.chapter])
    }

    private func recordChapterLength(_ chapter: Int, _ length: Int) {
        guard renderedLengths[chapter] != length else { return }
        renderedLengths[chapter] = length
        if chapter == position.chapter, let content {
            book.progress = progress(content)
            try? modelContext.save()
        }
    }

    private func progressText(_ content: BookContent) -> String {
        "\(Int((progress(content) * 100).rounded(.down)))%"
    }

    private func contentsPanel(content: BookContent, current: Int, paper: Color) -> some View {
        ContentsPanel(
            chapters: content.chapters,
            current: current,
            bookmarks: bookmarks,
            paper: paper,
            onSelect: { chapter, offset in
                position = ReadingPosition(chapter: chapter, offset: offset)
                withAnimation(.easeOut(duration: 0.2)) {
                    panel = nil
                    showingChrome = false
                }
            },
            onStep: { chapter in
                withAnimation(.smooth(duration: 0.35)) { position = ReadingPosition(chapter: chapter, offset: 0) }
            },
            onDelete: { bookmark in
                withAnimation(.spring(duration: 0.35)) {
                    modelContext.delete(bookmark)
                    try? modelContext.save()
                }
            }
        )
        .frame(maxWidth: 460)
    }

    /// 底部胶囊：点图标在它上方弹出卡片。
    @ViewBuilder
    private func capsuleMenu(content: BookContent, current: Int, paper: Color) -> some View {
        // 卡片挂在胶囊上方（overlay），不参与外层排版：打开卡片时外层高度不变，
        // 卡片就不会被外层「长高」的动画从胶囊下面带着往上滑，只在原地从按钮里鼓出来。
        ReaderToolbar(
            panel: Binding(get: { panel }, set: { new in
                cardSwitching = panel != nil && new != nil
                panel = new
            }),
            isBookmarked: bookmarkHere != nil,
            autoMode: autoMode,
            paper: paper,
            onToggleBookmark: {
                withAnimation(.spring(duration: 0.3)) { toggleBookmark(content: content) }
            }
        )
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            // 卡片本身只在打开、收起时出现和消失；在目录、显示、自动阅读之间切换时卡片一直在，
            // 只是高度平滑地变到新内容的高度，旧内容先淡出、新内容随后淡入，都裁在卡片里。
            if let panel {
                ZStack(alignment: .top) {
                    panelContent(panel, content: content, current: current, paper: paper)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(panel)
                        .transition(cardSwitching
                            ? .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.06)),
                                          removal: .opacity.animation(.easeOut(duration: 0.1)))
                            : .identity)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            // 正在淡出的旧内容不再左右卡片高度。
                            guard self.panel == panel else { return }
                            if let old = cardHeight, abs(old - height) > 0.5 {
                                withAnimation(.spring(duration: 0.38, bounce: 0.06)) { cardHeight = height }
                            } else if cardHeight == nil {
                                cardHeight = height
                            }
                        }
                }
                .frame(maxWidth: 440)
                .frame(height: cardHeight, alignment: .top)
                .clipShape(.rect(cornerRadius: 26))
                .paperGlass(paper, in: .rect(cornerRadius: 26))
                .environment(\.readerCardChromeless, true)
                .padding(.horizontal, 16)
                .fixedSize(horizontal: false, vertical: true)
                // 从被点的那个按钮里鼓出来，收起时缩回那个按钮；底边停在胶囊上方 12 点（胶囊高 52）。
                .transition(.cardBloom(anchor: cardAnchor(for: panel), lift: 52 + 12))
                .onDisappear { cardHeight = nil }
            }
        }
    }

    /// 卡片底边上、正对着某个按钮的那一点（卡片最宽 440，左右各留 16）
    private func cardAnchor(for panel: ReaderPanel) -> UnitPoint {
        let width = min(440, max(viewportSize.width - 32, 1))
        return UnitPoint(x: 0.5 + ReaderToolbar.buttonOffset(of: panel) / width, y: 1)
    }

    @ViewBuilder
    private func panelContent(_ panel: ReaderPanel, content: BookContent, current: Int, paper: Color) -> some View {
        switch panel {
        case .contents:
            contentsPanel(content: content, current: current, paper: paper)
        case .display:
            DisplayCard(fontSize: $fontSize, lineHeight: $lineHeight, theme: $theme, menuStyle: $menuStyle, pageMode: $pageMode, paper: paper)
        case .auto:
            AutoCard(autoMode: autoMode, paper: paper, onStart: startAuto, onStop: stopAuto) {
                if let autoMode { speedDial(autoMode) }
            }
        }
    }

    /// 折叠菜单：右下角 ⋯，点开向上长出一串胶囊；自动阅读进行中时左下角有调速和停止。
    @ViewBuilder
    private func foldingMenu(content: BookContent, current: Int, paper: Color) -> some View {
        if panel == .contents {
            contentsPanel(content: content, current: current, paper: paper)
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }

        HStack(alignment: .bottom) {
            if let autoMode, !dimmedFolding {
                autoControl(autoMode, paper: paper)
                    .transition(.opacity)
            }
            Spacer()
            GlassEffectContainer(spacing: 14) {
                VStack(alignment: .trailing, spacing: 12) {
                    if menuExpanded {
                        FoldingMenuItems(
                            namespace: menuGlass,
                            paper: paper,
                            chapterCount: content.chapters.count,
                            currentChapter: current,
                            onJumpToChapter: { chapter in
                                withAnimation(.smooth(duration: 0.35)) { position = ReadingPosition(chapter: chapter, offset: 0) }
                            },
                            isBookmarked: bookmarkHere != nil,
                            onToggleBookmark: {
                                withAnimation(.spring(duration: 0.3)) { toggleBookmark(content: content) }
                            },
                            fontSize: $fontSize,
                            lineHeight: $lineHeight,
                            theme: $theme,
                            menuStyle: $menuStyle,
                            pageMode: $pageMode,
                            autoMode: autoMode,
                            onToggleAuto: toggleAuto,
                            onContents: {
                                withAnimation(.spring(duration: 0.35)) {
                                    menuExpanded = false
                                    panel = .contents
                                }
                            }
                        )
                    }

                    Button {
                        if dimmedFolding {
                            collapse()
                        } else {
                            withAnimation(.spring(duration: 0.35)) { menuExpanded = true }
                        }
                    } label: {
                        Image(systemName: dimmedFolding ? "xmark" : "ellipsis")
                            .font(.system(size: 17, weight: .medium))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 48, height: 48)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(paper.opacity(0.8)).interactive(), in: .circle)
                    .glassEffectID("toggle", in: menuGlass)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private var dimmedFolding: Bool { panel != nil || menuExpanded }

    /// 折叠菜单里的「自动滚动」「自动翻页」：点一下开始并收起菜单，正在进行的那一项再点就停。
    private func toggleAuto(_ mode: AutoMode) {
        if autoMode == mode {
            stopAuto()
            withAnimation(.spring(duration: 0.3)) { menuExpanded = false }
        } else {
            withAnimation(.easeOut(duration: 0.25)) { menuExpanded = false }
            startAuto(mode)
        }
    }

    /// 折叠菜单打开时左下角的自动阅读控制：点速度弹出拨盘，旁边是停止。
    private func autoControl(_ mode: AutoMode, paper: Color) -> some View {
        HStack(spacing: 2) {
            Button(action: toggleSpeedDial) {
                HStack(spacing: 8) {
                    Image(systemName: "dial.medium")
                        .font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(shortSpeed(mode))
                            .font(.serif(13))
                            .monospacedDigit()
                        Text("\(mode.label)中")
                            .font(.serif(10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 6)
                .frame(height: 48)
                .contentShape(.rect)
            }

            Button(action: stopAuto) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12))
                    .frame(width: 44, height: 48)
                    .contentShape(.rect)
            }
        }
        .padding(.trailing, 4)
        .buttonStyle(.plain)
        .paperGlass(paper)
    }

    /// 卡片里选一种自动阅读：开始后收起菜单，直接读。
    private func startAuto(_ mode: AutoMode) {
        withAnimation(.easeOut(duration: 0.25)) {
            autoMode = mode
            panel = nil
            showingChrome = false
        }
    }

    /// 菜单收起时，左下角页脚里的小胶囊：显示模式和速度，点速度弹出拨盘，点 ■ 停止。
    private func miniAutoControl(_ mode: AutoMode) -> some View {
        // 只放小胶囊，不跟章名：右边是进度和时间，胶囊的中线和它们平齐。
        miniAutoPill(mode)
            .fixedSize()
        // 与页脚那一行（章名、页码）对齐。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        // 和正文左边对齐（胶囊自带一点内边距，往外让一些）；iPad 横屏正文居中时不会孤零零地贴在屏幕边上。
        .padding(.leading, max(22, readerInsets.left - 8))
        // 右边留给页脚的进度和时间（滚动模式）或页码和时间（翻页模式）。
        .padding(.trailing, max(130, readerInsets.right + 110))
        // 胶囊（高约 30）的中线与页脚那一行的中线对齐：离底边 max(安全区, 20) + 14。
        .padding(.bottom, Self.footerCenter(safeBottom: safeInsets.bottom) - 15)
        .ignoresSafeArea()
    }

    private func miniAutoPill(_ mode: AutoMode) -> some View {
        HStack(spacing: 0) {
            Button(action: toggleSpeedDial) {
                HStack(spacing: 5) {
                    Image(systemName: mode == .scroll ? "text.line.first.and.arrowtriangle.forward" : "book.pages")
                        .font(.system(size: 10, weight: .semibold))
                    Text(shortSpeed(mode))
                        .font(.serif(11))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: shortSpeed(mode))
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(height: 30)
                .contentShape(.rect)
            }

            Rectangle()
                .fill(.secondary.opacity(0.4))
                .frame(width: 0.5, height: 14)

            Button(action: stopAuto) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9))
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(style.secondary))
        .paperGlass(Color(style.background))
    }

    private func toggleSpeedDial() {
        withAnimation(.spring(duration: 0.3)) { showingSpeedDial.toggle() }
    }

    /// 浮在左下角控制上方的一条玻璃拨盘；点拨盘以外的地方收起。
    private func floatingSpeedDial(_ mode: AutoMode) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { toggleSpeedDial() }

            speedDial(mode)
                .foregroundStyle(Color.primary)
                .frame(maxWidth: 300)
                .paperGlass(Color(style.background), in: .rect(cornerRadius: 26))
                .padding(.horizontal, 16)
                // 菜单打开时浮在左下角控制上方，收起时浮在页脚的小胶囊上方。
                // 底部安全区比 iPhone 矮（iPad）时一并抬高，和上移后的菜单、页脚保持同样的间距。
                .padding(.bottom, (showingChrome ? 96 : 40) + max(0, 34 - safeInsets.bottom))
        }
    }

    /// 小胶囊里的简短速度，如「45 行/分」「15 秒/页」。
    private func shortSpeed(_ mode: AutoMode) -> String {
        switch mode {
        case .scroll: "\(Int(scrollLines.rounded())) 行/分"
        case .pages: "\(Int(pageSeconds.rounded())) 秒/页"
        }
    }

    @ViewBuilder
    private func speedDial(_ mode: AutoMode) -> some View {
        switch mode {
        case .scroll:
            SpeedDial(
                speed: Binding(get: { AutoMode.speed(forScrollLines: scrollLines) },
                               set: { scrollLines = AutoMode.scrollLines(atSpeed: $0) }),
                title: "滚动速度",
                reading: scrollLines.formatted(.number.precision(.fractionLength(1))),
                unit: "行 / 分钟",
                label: { "\(Int(AutoMode.scrollLines(atSpeed: $0).rounded()))" },
                onAdjustmentChanged: { adjustingScrollSpeed = $0 }
            )
        case .pages:
            SpeedDial(
                speed: Binding(get: { AutoMode.speed(forPageSeconds: pageSeconds) },
                               set: { pageSeconds = AutoMode.pageSeconds(atSpeed: $0) }),
                title: "翻页速度",
                reading: pageSeconds.formatted(.number.precision(.fractionLength(1))),
                unit: "秒 / 页",
                label: { "\(Int(AutoMode.pageSeconds(atSpeed: $0).rounded()))s" }
            )
        }
    }

    private func reachEnd() {
        let mode = autoMode
        stopAuto()
        guard !boundaryHandled else { return }
        boundaryHandled = true
        onForwardBoundary?(mode)
    }

    private func stopAuto() {
        withAnimation(.easeOut(duration: 0.25)) {
            autoMode = nil
            showingSpeedDial = false
        }
    }

    private func crossfadeWindow() {
        guard !UIAccessibility.isReduceMotionEnabled,
              let window = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow else { return }
        UIView.transition(with: window, duration: 0.32, options: [.transitionCrossDissolve, .allowUserInteraction], animations: nil)
    }

    private func toggleChrome() {
        withAnimation(.spring(duration: 0.35, bounce: 0.12)) {
            showingSpeedDial = false
            showingChrome.toggle()
            panel = nil
            menuExpanded = false
        }
    }

    private func collapse() {
        withAnimation(.spring(duration: 0.3)) {
            panel = nil
            menuExpanded = false
        }
    }

    /// 按章名在书里找章节：去掉空白后完全一样的优先，其次是互相包含的；都找不到就按序号。
    private static func chapterIndex(for start: (title: String, index: Int), in chapters: [Chapter]) -> Int {
        func normalized(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        let target = normalized(start.title)
        if !target.isEmpty {
            if let exact = chapters.firstIndex(where: { normalized($0.title) == target }) { return exact }
            if let near = chapters.firstIndex(where: {
                let title = normalized($0.title)
                return !title.isEmpty && (title.hasSuffix(target) || target.hasSuffix(title))
            }) { return near }
        }
        return min(max(start.index, 0), max(chapters.count - 1, 0))
    }

    private func load() async {
        let url = book.fileURL, format = book.format, title = book.title
        let result: BookContent?
        if let providedChapter {
            result = BookContent(chapters: [providedChapter], image: { _ in nil })
        } else {
            result = await Task.detached(priority: .userInitiated) {
                try? BookContent.load(fileURL: url, format: format, title: title)
            }.value
        }
        guard !Task.isCancelled else { return }
        if let result {
            if let startChapter {
                position = ReadingPosition(chapter: Self.chapterIndex(for: startChapter, in: result.chapters), offset: 0)
            }
            position.chapter = min(max(position.chapter, 0), result.chapters.count - 1)
            position.offset = max(0, position.offset)
            book.lastOpenedAt = .now
            try? modelContext.save()
            withAnimation(.easeOut(duration: 0.3)) { content = result }
        } else {
            withAnimation(.easeOut(duration: 0.3)) { failed = true }
        }
    }
}

/// 目录：浮在底栏上方的液态玻璃面板，可上下滚动。
/// 顶部是阅读进度；每行左边小字章号、右边章名；读过的章节淡一些，当前章节衬一层藕粉。
private struct ContentsPanel: View {
    let chapters: [Chapter]
    let current: Int
    let bookmarks: [Bookmark]
    let paper: Color
    /// 跳到第几章、章内第几个字（并收起菜单）
    var onSelect: (Int, Int) -> Void
    /// 上一章、下一章（菜单不收起）
    var onStep: (Int) -> Void
    var onDelete: (Bookmark) -> Void

    private enum Tab { case contents, bookmarks }
    @State private var tab = Tab.contents
    /// 当前章那层藕粉底色：换章时从旧的一行滑到新的一行
    @Namespace private var currentRow

    private static let rowHeight: CGFloat = 38

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Group {
                switch tab {
                case .contents: chapterList
                case .bookmarks: bookmarkList
                }
            }
            .transition(.opacity)
            .id(tab)
        }
        // 内容少时贴合，多时最高约半屏，其余滚动查看。
        .frame(height: panelHeight)
        // 切换目录、书签时，列表淡入淡出也只在卡片里，不伸出去。
        .clipShape(.rect(cornerRadius: 26))
        .cardGlass(paper, in: .rect(cornerRadius: 26))
    }

    private var panelHeight: CGFloat {
        switch tab {
        case .contents: min(CGFloat(chapters.count) * Self.rowHeight + 76, 360)
        case .bookmarks: bookmarks.isEmpty ? 190 : min(CGFloat(bookmarks.count) * 64 + 84, 360)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                tabButton("目录", .contents)
                tabButton("书签\(bookmarks.isEmpty ? "" : " \(bookmarks.count)")", .bookmarks)
                Spacer()
                HStack(spacing: 0) {
                    step("chevron.left", to: current - 1)
                    Text("\(current + 1) / \(chapters.count)")
                        .font(.serif(12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: Double(current)))
                        .fixedSize()
                    step("chevron.right", to: current + 1)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule().fill(Color.accent)
                        .frame(width: proxy.size.width * CGFloat(current + 1) / CGFloat(max(chapters.count, 1)))
                }
            }
            .frame(height: 2)
            .animation(.smooth(duration: 0.4), value: current)
        }
    }

    /// 章号两边的 ‹ ›：翻到上一章、下一章。
    private func step(_ systemImage: String, to chapter: Int) -> some View {
        let disabled = !chapters.indices.contains(chapter)
        return Button { onStep(chapter) } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
    }

    private func tabButton(_ title: String, _ target: Tab) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { tab = target }
        } label: {
            Text(title)
                // 选中的一项字号、字距平滑地放大，不是一下子跳过去。
                .modifier(TabTitleStyle(size: tab == target ? 17 : 14, tracking: tab == target ? 2 : 0, medium: tab == target))
                .foregroundStyle(tab == target ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
    }

    private var chapterList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(chapters) { chapter in
                        // 卷名变了就插一行小标题，各章只写章名。
                        let volume = ChapterTitle.parts(chapter.title).volume
                        if let volume, chapter.id == 0 || ChapterTitle.parts(chapters[chapter.id - 1].title).volume != volume {
                            Text(volume)
                                .font(.serif(12, medium: true))
                                .foregroundStyle(.tint)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.top, chapter.id == 0 ? 4 : 14)
                                .padding(.bottom, 4)
                        }
                        row(chapter)
                            .id(chapter.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            // 用 ‹ › 换章时，列表跟着滑到当前章。
            .onChange(of: current) { _, chapter in
                withAnimation(.smooth(duration: 0.35)) { proxy.scrollTo(chapter, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private var bookmarkList: some View {
        if bookmarks.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "bookmark")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Color.accent)
                Text("还没有书签")
                    .font(.serif(14))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 12)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(bookmarks) { bookmark in
                        bookmarkRow(bookmark)
                            .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .leading))))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .vertical)
        }
    }

    private func bookmarkRow(_ bookmark: Bookmark) -> some View {
        Button { onSelect(bookmark.chapter, bookmark.offset) } label: {
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(Color.accent)
                    .frame(width: 2, height: 30)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bookmark.excerpt.isEmpty ? bookmark.chapterTitle : bookmark.excerpt)
                        .font(.serif(13))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack {
                        Text(bookmark.chapterTitle)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(bookmark.createdAt, format: .dateTime.month().day())
                    }
                    .font(.serif(10))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除书签", systemImage: "trash", role: .destructive) { onDelete(bookmark) }
        }
    }

    private func row(_ chapter: Chapter) -> some View {
        let isCurrent = chapter.id == current
        let (number, name) = Self.split(ChapterTitle.parts(chapter.title).name, index: chapter.id)
        return Button { onSelect(chapter.id, 0) } label: {
            HStack(spacing: 8) {
                Text(number)
                    .font(.serif(12))
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.tertiary))
                    .frame(width: 46, alignment: .leading)
                Text(name)
                    .font(.serif(14, medium: isCurrent))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.primary)
                        : chapter.id < current ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.rowHeight)
            .background {
                if isCurrent {
                    Capsule().fill(Color.accent.opacity(0.16))
                        .matchedGeometryEffect(id: "current", in: currentRow)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    /// 把「第12章 春日」拆成「第12章」和「春日」；没有章号的用序号代替。
    private static func split(_ title: String, index: Int) -> (String, String) {
        let pattern = /^(第[0-9０-９零〇一二三四五六七八九十百千万两]+[章回节卷集部篇幕话])\s*(.*)$/
        if let match = title.wholeMatch(of: pattern) {
            let name = String(match.2)
            return (String(match.1), name.isEmpty ? String(match.1) : name)
        }
        return (String(format: "%02d", index + 1), title)
    }
}

/// 字号、字距可以随动画逐帧变化的标签字体。
private struct TabTitleStyle: ViewModifier, Animatable {
    var size: CGFloat
    var tracking: CGFloat
    var medium: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(size, tracking) }
        set { size = newValue.first; tracking = newValue.second }
    }

    func body(content: Content) -> some View {
        content
            .font(.serif(size, medium: medium))
            .tracking(tracking)
    }
}

/// 滚动正文上下两端的渐隐，像字幕从纸面里浮出、又隐没。
/// 顶部先实底遮住灵动岛一带再渐隐；底部同理，页脚（章名、进度、自动阅读胶囊）落在实底上，不与正文相叠。
private struct ScrollEdges: View {
    let background: Color
    /// 正文区的上下边距：只在边距里渐隐，正文第一行和最后一行完整可见
    let insets: UIEdgeInsets
    /// 顶部安全区：灵动岛那一行（返回按钮在这里）始终是实底，滚上去的字不会从按钮后面透出来
    var safeTop: CGFloat = 0

    var body: some View {
        let fade: CGFloat = 26
        let topSolid = min(max(insets.top - fade, safeTop + 10), insets.top - 12)
        VStack(spacing: 0) {
            background.frame(height: max(topSolid, 0))
            LinearGradient(colors: [background, background.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: insets.top - max(topSolid, 0))
            Spacer()
            LinearGradient(colors: [background.opacity(0), background], startPoint: .top, endPoint: .bottom)
                .frame(height: fade)
            // 底下至少盖住页脚那一行（离底边 33 点起），文字不会从章名、进度后面透出来。
            background.frame(height: max(insets.bottom - fade, 60))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// 注释：页面下方浮起一张小纸笺，点任意处收起。
private struct NoteCard: View {
    let text: String
    let paper: Color
    var onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .contentShape(.rect)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Capsule().fill(Color.accent).frame(width: 14, height: 1.5)
                    Text("注")
                        .font(.serif(12, medium: true))
                        .tracking(2)
                        .foregroundStyle(Color.accent)
                }
                // 短注释贴合内容；长注释限高，可上下滚动。
                ViewThatFits(in: .vertical) {
                    paragraph(text)
                    ScrollView { paragraph(text) }
                        .frame(height: 220)
                }
                .frame(maxHeight: 220)
            }
            .padding(20)
            .frame(maxWidth: 460)
            .glassEffect(.regular.tint(paper.opacity(0.7)), in: .rect(cornerRadius: 26))
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .onTapGesture(perform: onDismiss)
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.serif(15))
            .lineSpacing(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 上下滚动时的页脚：左边章名、右边进度，与翻页模式的页脚同一位置。
private struct ScrollFooter: View {
    let chapterTitle: String
    let progress: String
    let color: Color
    /// 与正文左右对齐
    var side: CGFloat = 31
    /// 左边的章名（自动滚动时让给小胶囊）
    var showsTitle = true
    /// 文字底边离屏幕底边多远（让这一行和翻页模式的页脚、自动阅读小胶囊在同一条线上）
    var bottom: CGFloat = 33

    var body: some View {
        HStack {
            Text(chapterTitle)
                .lineLimit(1)
                .contentTransition(.opacity)
                .opacity(showsTitle ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: showsTitle)
            Spacer(minLength: 12)
            Text(progress)
                .monospacedDigit()
                .contentTransition(.numericText())
            // 右下角的时间（只有时、分），整分钟时刷新。
            TimelineView(.everyMinute) { context in
                Text(ReaderClock.text(context.date))
                    .monospacedDigit()
            }
            .padding(.leading, 4)
            .accessibilityLabel("当前时间")
        }
        .font(.serif(11))
        .foregroundStyle(color)
        .animation(.smooth(duration: 0.3), value: progress)
        .animation(.easeInOut(duration: 0.3), value: chapterTitle)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, side)
        .padding(.bottom, bottom)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// 菜单出现时，底部菜单背后的纸色渐隐；最底下页脚那一条留空，章名和页码照常可见。
private struct MenuEdges: View {
    let background: Color

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            LinearGradient(stops: [.init(color: background.opacity(0), location: 0), .init(color: background, location: 0.4),
                                   .init(color: background, location: 0.6), .init(color: background.opacity(0), location: 0.64)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 170)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// 当前页有书签时，右上角垂下的一条藕粉丝带。
private struct BookmarkRibbon: View {
    var body: some View {
        Image(systemName: "bookmark.fill")
            .font(.system(size: 18))
            .foregroundStyle(Color.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 54)
            .padding(.trailing, 26)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}
