import SwiftUI
import UIKit

/// 阅读页菜单弹出的卡片。
enum ReaderPanel {
    case contents, display, auto
}

/// 菜单统一的玻璃：可按压的液态玻璃里掺一点纸色，底下正文不至于透得太花。
extension View {
    func paperGlass(_ paper: Color, in shape: some Shape = .capsule, interactive: Bool = false) -> some View {
        glassEffect(interactive ? .regular.tint(paper.opacity(0.8)).interactive() : .regular.tint(paper.opacity(0.8)), in: shape)
    }
}

/// 底部居中的一条小胶囊：目录、显示、自动、书签。前三个在胶囊上方弹出卡片，书签直接加减。
struct ReaderToolbar: View {
    @Binding var panel: ReaderPanel?
    @Namespace private var highlight
    let isBookmarked: Bool
    let autoMode: AutoMode?
    let paper: Color
    var onToggleBookmark: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            item(.contents) { Image(systemName: "list.bullet").font(.system(size: 16, weight: .medium)) }
            item(.display) { Text("Aa").font(.serif(16, medium: true)) }
            item(.auto) {
                Image(systemName: autoMode == nil ? "play.circle" : "play.circle.fill")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(autoMode == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accent))
            }
            Button(action: onToggleBookmark) {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isBookmarked ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.primary))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: isBookmarked)
                    .frame(width: 52, height: 44)
                    .contentShape(.capsule)
            }
            .accessibilityLabel(isBookmarked ? "移除书签" : "加书签")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .frame(height: 52)
        .paperGlass(paper)
        .sensoryFeedback(.selection, trigger: panel)
    }

    private func item(_ target: ReaderPanel, @ViewBuilder label: () -> some View) -> some View {
        let selected = panel == target
        return Button {
            withAnimation(.spring(duration: 0.32)) { panel = selected ? nil : target }
        } label: {
            label()
                .frame(width: 52, height: 44)
                .background {
                    if selected {
                        Capsule()
                            .fill(Color.accent.opacity(0.16))
                            .matchedGeometryEffect(id: "highlight", in: highlight)
                    }
                }
                .contentShape(.capsule)
        }
        .accessibilityLabel(target == .contents ? "目录与书签" : target == .display ? "显示设置" : "自动阅读")
    }
}

/// 弹出卡片的外框：统一圆角、留白和玻璃。
struct ReaderCard<Content: View>: View {
    let paper: Color
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: 400)
            .paperGlass(paper, in: .rect(cornerRadius: 26))
    }
}

/// 显示：亮度、字号、配色、行距。
struct DisplayCard: View {
    @Binding var fontSize: Double
    @Binding var lineHeight: ReaderLineHeight
    @Binding var theme: ReaderTheme
    @Binding var menuStyle: ReaderMenuStyle
    @Binding var pageMode: ReaderPageMode
    let paper: Color

    @State private var brightness = Self.screen?.brightness ?? 0.5

    private static var screen: UIScreen? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
    }

    var body: some View {
        ReaderCard(paper: paper) {
            VStack(spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "sun.min").font(.system(size: 13))
                    Slider(value: $brightness, in: 0 ... 1)
                        .tint(Color.accent)
                        .onChange(of: brightness) { _, value in Self.screen?.brightness = value }
                    Image(systemName: "sun.max").font(.system(size: 15))
                }
                .foregroundStyle(.secondary)

                HStack {
                    label("字号")
                    stepper
                    Spacer(minLength: 12)
                    HStack(spacing: 10) {
                        ForEach(ReaderTheme.allCases) { option in
                            ThemeSwatch(option: option, selected: theme == option) { withAnimation(.spring(duration: 0.3)) { theme = option } }
                        }
                    }
                }

                HStack {
                    label("行距")
                    choices(ReaderLineHeight.allCases, selection: $lineHeight) { $0.label }
                }

                HStack {
                    label("翻页")
                    choices(ReaderPageMode.allCases, selection: $pageMode) { $0.label }
                }

                HStack {
                    label("菜单")
                    choices(ReaderMenuStyle.allCases, selection: $menuStyle) { $0.label }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.serif(12))
            .foregroundStyle(.secondary)
            .frame(width: 36, alignment: .leading)
    }

    private var stepper: some View {
        HStack(spacing: 0) {
            Button { withAnimation(.snappy) { fontSize = max(ReaderStyle.fontSizes.lowerBound, fontSize - 1) } } label: {
                Text("A").font(.serif(12)).frame(width: 34, height: 30).contentShape(.rect)
            }
            .disabled(fontSize <= ReaderStyle.fontSizes.lowerBound)
            Text("\(Int(fontSize))")
                .font(.serif(14))
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(minWidth: 26)
            Button { withAnimation(.snappy) { fontSize = min(ReaderStyle.fontSizes.upperBound, fontSize + 1) } } label: {
                Text("A").font(.serif(18)).frame(width: 34, height: 30).contentShape(.rect)
            }
            .disabled(fontSize >= ReaderStyle.fontSizes.upperBound)
        }
        .background(Capsule().fill(.primary.opacity(0.06)))
    }

    private func choices<Option: Hashable & Identifiable>(_ options: [Option], selection: Binding<Option>,
                                                          title: @escaping (Option) -> String) -> some View {
        ChoiceRow(options: options, selection: selection, fontSize: 13, title: title)
    }
}

/// 一排文字选项，选中的衬一层藕粉；换选项时这层底色滑过去。
struct ChoiceRow<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    var fontSize: CGFloat = 13
    let title: (Option) -> String

    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = selection == option
                Button {
                    withAnimation(.spring(duration: 0.3, bounce: 0.15)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.serif(fontSize, medium: selected))
                        .foregroundStyle(selected ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color.accent.opacity(0.14))
                                    .matchedGeometryEffect(id: "highlight", in: highlight)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// 自动阅读：两种方式二选一；进行中的那一种下方出现调速拨盘和停止。
struct AutoCard<Dial: View>: View {
    let autoMode: AutoMode?
    let paper: Color
    var onStart: (AutoMode) -> Void
    var onStop: () -> Void
    @ViewBuilder var dial: Dial

    var body: some View {
        ReaderCard(paper: paper) {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    option(.scroll, systemImage: "text.line.first.and.arrowtriangle.forward")
                    option(.pages, systemImage: "book.pages")
                }
                if autoMode != nil {
                    dial
                    Button(action: onStop) {
                        Label("停止", systemImage: "stop.fill")
                            .font(.serif(13))
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(Capsule().fill(.primary.opacity(0.06)))
                            .contentShape(.capsule)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func option(_ mode: AutoMode, systemImage: String) -> some View {
        let active = autoMode == mode
        return Button { if !active { onStart(mode) } } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 16))
                    .frame(height: 22)
                Text(mode.label)
                    .font(.serif(13, medium: active))
            }
            .foregroundStyle(active ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(active ? Color.accent.opacity(0.14) : Color.primary.opacity(0.05))
            }
            .contentShape(.rect(cornerRadius: 16))
        }
    }
}

/// 菜单样式：底部居中的小胶囊，或右下角 ⋯ 折叠展开的一串胶囊。
enum ReaderMenuStyle: String, CaseIterable, Identifiable {
    case capsule, folding

    var id: String { rawValue }

    var label: String {
        switch self {
        case .capsule: "底部胶囊"
        case .folding: "右下折叠"
        }
    }
}

/// 折叠菜单：点右下角 ⋯ 后，从按钮里长出的一张玻璃卡片。
/// 一级是章节切换和四行选项；「显示」「自动阅读」点进去在同一张卡片里换成二级，顶部「‹」回到一级。
/// 需要放在 GlassEffectContainer 里，卡片才会从按钮里长出、收回。
struct FoldingMenuItems: View {
    let namespace: Namespace.ID
    let paper: Color
    let chapterCount: Int
    let currentChapter: Int
    var onJumpToChapter: (Int) -> Void
    let isBookmarked: Bool
    var onToggleBookmark: () -> Void

    @Binding var fontSize: Double
    @Binding var lineHeight: ReaderLineHeight
    @Binding var theme: ReaderTheme
    @Binding var menuStyle: ReaderMenuStyle
    @Binding var pageMode: ReaderPageMode
    let autoMode: AutoMode?
    var onToggleAuto: (AutoMode) -> Void
    var onContents: () -> Void

    private enum Page {
        case main, display, auto
    }

    @State private var page = Page.main
    @State private var brightness = Self.screen?.brightness ?? 0.5

    private static let width: CGFloat = 248

    private static var screen: UIScreen? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
    }

    var body: some View {
        VStack(spacing: 0) {
            switch page {
            case .main: mainPage.transition(.pageSwap(forward: false))
            case .display: displayPage.transition(.pageSwap(forward: true))
            case .auto: autoPage.transition(.pageSwap(forward: true))
            }
        }
        .padding(6)
        .frame(width: Self.width)
        .clipShape(.rect(cornerRadius: 24))
        .glassEffect(.regular.tint(paper.opacity(0.8)), in: .rect(cornerRadius: 24))
        .glassEffectID("card", in: namespace)
        .buttonStyle(MenuRowStyle())
        .sensoryFeedback(.selection, trigger: page)
    }

    private func go(_ target: Page) {
        withAnimation(.spring(duration: 0.35, bounce: 0.1)) { page = target }
    }

    // MARK: 一级

    private var mainPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                chapterStep("chevron.left", disabled: currentChapter == 0) { onJumpToChapter(currentChapter - 1) }
                Text("第 \(currentChapter + 1) / \(chapterCount) 章")
                    .font(.serif(13))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity)
                chapterStep("chevron.right", disabled: currentChapter >= chapterCount - 1) { onJumpToChapter(currentChapter + 1) }
            }
            .frame(height: 40)

            divider

            row("显示", systemImage: "circle.lefthalf.filled", chevron: true) { go(.display) }
            row(autoMode.map { "\($0.label)中" } ?? "自动阅读", systemImage: "play.circle",
                chevron: true, active: autoMode != nil) { go(.auto) }
            row(isBookmarked ? "已加书签" : "加书签", systemImage: isBookmarked ? "bookmark.fill" : "bookmark",
                active: isBookmarked, action: onToggleBookmark)
            row("目录与书签", systemImage: "list.bullet", action: onContents)
        }
    }

    // MARK: 二级：显示

    private var displayPage: some View {
        VStack(spacing: 0) {
            header("显示")

            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "sun.min").font(.system(size: 12))
                    Slider(value: $brightness, in: 0 ... 1)
                        .tint(Color.accent)
                        .onChange(of: brightness) { _, value in Self.screen?.brightness = value }
                    Image(systemName: "sun.max").font(.system(size: 14))
                }
                .foregroundStyle(.secondary)

                HStack(spacing: 0) {
                    fontStepper
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        ForEach(ReaderTheme.allCases) { option in
                            ThemeSwatch(option: option, selected: theme == option, size: 18) {
                                withAnimation(.spring(duration: 0.3)) { theme = option }
                            }
                        }
                    }
                }

                ChoiceRow(options: ReaderLineHeight.allCases, selection: $lineHeight, fontSize: 12) { $0.label }
                ChoiceRow(options: ReaderPageMode.allCases, selection: $pageMode, fontSize: 12) { $0.label }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 10)

            divider

            row("改用底部胶囊菜单", systemImage: "capsule") {
                withAnimation(.spring(duration: 0.35)) { menuStyle = .capsule }
            }
        }
    }

    private var fontStepper: some View {
        HStack(spacing: 0) {
            Button { withAnimation(.snappy) { fontSize = max(ReaderStyle.fontSizes.lowerBound, fontSize - 1) } } label: {
                Text("A").font(.serif(12)).frame(width: 32, height: 30).contentShape(.rect)
            }
            .disabled(fontSize <= ReaderStyle.fontSizes.lowerBound)
            Text("\(Int(fontSize))")
                .font(.serif(13))
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(minWidth: 22)
            Button { withAnimation(.snappy) { fontSize = min(ReaderStyle.fontSizes.upperBound, fontSize + 1) } } label: {
                Text("A").font(.serif(17)).frame(width: 32, height: 30).contentShape(.rect)
            }
            .disabled(fontSize >= ReaderStyle.fontSizes.upperBound)
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(.primary.opacity(0.06)))
    }

    // MARK: 二级：自动阅读

    private var autoPage: some View {
        VStack(spacing: 0) {
            header("自动阅读")
            row(autoMode == .scroll ? "停止滚动" : "自动滚动",
                systemImage: autoMode == .scroll ? "stop.fill" : "text.line.first.and.arrowtriangle.forward",
                active: autoMode == .scroll) { onToggleAuto(.scroll) }
            row(autoMode == .pages ? "停止翻页" : "自动翻页",
                systemImage: autoMode == .pages ? "stop.fill" : "book.pages",
                active: autoMode == .pages) { onToggleAuto(.pages) }
        }
    }

    // MARK: 零件

    /// 二级页顶部：‹ 和页名，点整行回到一级。
    private func header(_ title: String) -> some View {
        Button { go(.main) } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.serif(14, medium: true))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(.rect)
        }
    }

    /// 一行选项：左边图标和文字，有下一级时右边一个 ›。
    private func row(_ title: String, systemImage: String, chevron: Bool = false,
                     active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .frame(width: 20)
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.serif(14))
                Spacer(minLength: 0)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(active ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .frame(height: 44)
            .contentShape(.rect)
        }
    }

    private func chapterStep(_ systemImage: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(.rect)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
    }

    private var divider: some View {
        Rectangle()
            .fill(.primary.opacity(0.08))
            .frame(height: 0.5)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
    }
}

/// 卡片里一行的按压效果：按下时衬一层淡淡的圆角底色。
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
            }
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private extension AnyTransition {
    /// 卡片里一、二级互换：进下一级从右边滑入，回上一级从左边滑入。
    static func pageSwap(forward: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: forward ? 24 : -24)),
            removal: .opacity.combined(with: .offset(x: forward ? -24 : 24))
        )
    }
}

/// 配色小圆点：跟随系统是一半纸白、一半夜读。
struct ThemeSwatch: View {
    let option: ReaderTheme
    let selected: Bool
    var size: CGFloat = 22
    var action: () -> Void

    var body: some View {
        let light = Color(ReaderStyle(fontSize: 1, lineHeight: 1, scheme: .light).background)
        let dark = Color(ReaderStyle(fontSize: 1, lineHeight: 1, scheme: .dark).background)
        Button(action: action) {
            ZStack {
                switch option {
                case .system:
                    Circle().fill(light)
                    Circle().fill(dark).mask(Rectangle().frame(width: size / 2).offset(x: size / 4))
                case .paper:
                    Circle().fill(light)
                case .night:
                    Circle().fill(dark)
                }
                Circle().stroke(Color.primary.opacity(0.2), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .padding(size > 18 ? 3 : 2.5)
            .overlay { Circle().stroke(Color.accent, lineWidth: selected ? 1.5 : 0) }
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
    }
}
