import SwiftUI

// 全 App 共用的界面零件：页头、玻璃圆按钮、书格、标签流、选项条。
// 书斋、发现、详情、分类、历史、我的都用这一套，字体、留白、圆角保持一致。

/// 页面左上角的标题：宋体大字，下面一道藕粉短线，可带一行小字。
struct PageHeader: View {
    let title: String
    var caption: String?
    var titleSize: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: caption == nil ? 6 : 4) {
            Text(title)
                .font(.serif(titleSize))
                .tracking(2)
                .foregroundStyle(Color.ink)
            if let caption {
                HStack(spacing: 8) {
                    Capsule()
                        .fill(.tint)
                        .frame(width: 14, height: 1.5)
                    Text(caption)
                        .font(.serif(13))
                        .tracking(1)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 18)
            } else {
                // 没有小字时，短线紧贴在标题下面，不单独悬着。
                Capsule()
                    .fill(.tint)
                    .frame(width: 14, height: 1.5)
            }
        }
    }
}

/// 页头右侧的玻璃圆按钮的外观（放进 Button 或 NavigationLink 的 label 里）。
struct GlassCircleLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.tint)
            .frame(width: 40, height: 40)
            .contentShape(.circle)
            .glassEffect(.regular.interactive(), in: .circle)
    }
}

/// 小节标题：宋体中号，右边可放一个小字。
struct SectionTitle: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.serif(17, medium: true))
                .foregroundStyle(Color.ink)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.serif(12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 淡淡的纸色面板，设置项、状态提示都放在里面。
struct PaperPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.ink.opacity(0.035), in: .rect(cornerRadius: 20))
    }
}

/// 按住时轻轻缩小，松手弹回。书格、卡片通用。
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
    }
}

/// iPhone 和 iPad 上书格的尺寸。iPhone 17 一行三本，iPad Pro 11 英寸竖屏一行五本、横屏七本左右。
struct ShelfMetrics {
    let margin: CGFloat
    let titleSize: CGFloat
    let headerGap: CGFloat
    let coverWidth: ClosedRange<CGFloat>
    let columnGap: CGFloat
    let rowGap: CGFloat

    static let phone = ShelfMetrics(
        margin: 20, titleSize: 28, headerGap: 18, coverWidth: 96 ... 130, columnGap: 14, rowGap: 20
    )
    static let pad = ShelfMetrics(
        margin: 40, titleSize: 34, headerGap: 28, coverWidth: 128 ... 160, columnGap: 24, rowGap: 30
    )

    static func of(_ sizeClass: UserInterfaceSizeClass?) -> ShelfMetrics {
        sizeClass == .regular ? .pad : .phone
    }

    var columns: [GridItem] {
        [GridItem(.adaptive(minimum: coverWidth.lowerBound, maximum: coverWidth.upperBound), spacing: columnGap, alignment: .top)]
    }
}

/// 书格：封面，下面书名（一行）和作者；读过的书再加一行进度。
struct ShelfTile<Cover: View>: View {
    let title: String
    let author: String
    var large = false
    /// 读到全书的几成（0…1）；nil 或 0 表示还没读，不显示
    var progress: Double?
    @ViewBuilder var cover: Cover

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 8 : 6) {
            cover
            VStack(alignment: .leading, spacing: 1) {
                // 书名只占一行，放不下的用省略号收尾，各格高度一致、排得齐。
                Text(title)
                    .font(.serif(large ? 15 : 13, medium: true))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                if !author.isEmpty {
                    Text(author)
                        .font(.serif(large ? 13 : 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let progress, progress > 0 {
                    ReadingProgress(value: progress, large: large)
                        .padding(.top, large ? 5 : 4)
                }
            }
        }
    }
}

/// 一根短短的进度条加百分比；读完了写「读毕」。
struct ReadingProgress: View {
    let value: Double
    var large = false

    private var finished: Bool { value >= 0.995 }

    var body: some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(Color.ink.opacity(0.1))
                .frame(width: large ? 44 : 34, height: 2.5)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.accent)
                        .frame(width: (large ? 44 : 34) * min(max(value, 0.04), 1), height: 2.5)
                }
            Text(finished ? "读毕" : "\(Int((value * 100).rounded(.down)))%")
                .font(.serif(large ? 12 : 10))
                .monospacedDigit()
                .foregroundStyle(finished ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.secondary))
                .contentTransition(.numericText())
        }
        .animation(.smooth(duration: 0.5), value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(finished ? "已读完" : "已读 \(Int(value * 100))%")
    }
}

/// 一排可选的胶囊，如榜单、搜索范围；选中的衬藕粉底色，换选项时底色滑过去。
struct ChipBar<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    /// 页面左侧留白：这一排往左可以滑到屏幕边缘，静止时首项仍与页面内容左对齐
    var bleed: CGFloat = 0
    let title: (Option) -> String

    @Namespace private var highlight

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    let selected = option == selection
                    Button {
                        withAnimation(.spring(duration: 0.3, bounce: 0.15)) { selection = option }
                    } label: {
                        Text(title(option))
                            .font(.serif(14, medium: selected))
                            .foregroundStyle(selected ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.secondary))
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background {
                                if selected {
                                    Capsule()
                                        .fill(Color.accent.opacity(0.14))
                                        .matchedGeometryEffect(id: "highlight", in: highlight)
                                } else {
                                    Capsule().fill(Color.ink.opacity(0.04))
                                }
                            }
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
        // 左边可以滑到屏幕边缘；右边留在页边距以内，末端淡出，不顶到屏幕边、也不生硬截断。
        .contentMargins(.leading, bleed, for: .scrollContent)
        .contentMargins(.trailing, 12, for: .scrollContent)
        .padding(.leading, -bleed)
        .mask {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 28)
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// 一个标签：小号宋体，淡藕粉底。
struct TagLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.serif(12))
            .foregroundStyle(Color.ink.opacity(0.8))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Color.accent.opacity(0.1), in: .capsule)
    }
}

/// 标签流：一行放不下就换行，像文字一样从左往右排。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

extension View {
    /// 页顶一层纸色，下沿渐隐：滚动的内容不会压在状态栏（或导航栏的返回按钮）底下，也没有生硬的分隔线。
    /// `extra` 是状态栏以下还要遮住的高度，带导航栏的页面传导航栏的高度。
    func paperTopEdge(extra: CGFloat = 0) -> some View {
        overlay(alignment: .top) {
            GeometryReader { proxy in
                LinearGradient(stops: [.init(color: .paper, location: 0), .init(color: .paper, location: 0.72),
                                       .init(color: .paper.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: proxy.safeAreaInsets.top + extra + 16)
                    .ignoresSafeArea(edges: .top)
            }
            .allowsHitTesting(false)
        }
    }
}

/// 护眼模式：整个界面叠一层暖色，按「正片叠底」混合，削掉一部分蓝光、整体偏暖，而不是蒙一层灰。
/// 开关和强度存在设置里，下次打开 App 自动生效。App 主界面和全屏阅读页各叠一层（全屏弹出的页面在主界面之上）。
struct EyeCareFilter: ViewModifier {
    @AppStorage("app.eyeCare") private var enabled = false
    /// 0…1，越大越暖
    @AppStorage("app.eyeCareStrength") private var strength = 0.5

    func body(content: Content) -> some View {
        content
            .overlay {
                if enabled {
                    // 红色通道不动，绿、蓝按强度压低：强度 0.5 时蓝光约减三成。
                    Color(red: 1, green: 1 - 0.22 * strength, blue: 1 - 0.55 * strength)
                        .blendMode(.multiply)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: enabled)
            .animation(.easeInOut(duration: 0.2), value: strength)
    }
}

extension View {
    func eyeCareFilter() -> some View { modifier(EyeCareFilter()) }
}
