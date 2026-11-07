import SwiftUI

/// 落叶（Luoye）全站统一视觉组件库：纸白、墨色、藕粉与思源宋体。
struct LuoyeSegmentItem<Value: Hashable>: Identifiable {
    var id: Value { value }
    let value: Value
    let title: String
    var badge: String? = nil
}

/// 统一的分段切换条，替代系统默认灰色 Segmented Picker，保持全应用色调与宋体气质一致。
struct LuoyeSegmentBar<Value: Hashable>: View {
    let items: [LuoyeSegmentItem<Value>]
    @Binding var selection: Value
    var compact: Bool = false
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                let selected = selection == item.value
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selection = item.value
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(item.title)
                            .font(.serif(compact ? 12 : 13, medium: selected))
                            .lineLimit(1)
                        if let badge = item.badge, !badge.isEmpty {
                            Text(badge)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(selected ? Color.accent : .secondary)
                        }
                    }
                    .foregroundStyle(selected ? Color.accent : .secondary)
                    .frame(maxWidth: compact ? nil : .infinity)
                    .padding(.horizontal, compact ? 11 : 10)
                    .padding(.vertical, compact ? 7 : 8)
                    .fixedSize(horizontal: compact, vertical: false)
                    .background {
                        if selected {
                            Capsule().fill(Color.accent.opacity(0.14))
                                .matchedGeometryEffect(id: "selection", in: highlight)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3.5)
        .fixedSize(horizontal: compact, vertical: false)
        .background(Color.ink.opacity(0.045), in: Capsule())
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// 统一的胶囊筛选标签（用于榜单切换、搜索维度、语言/格式筛选等）。
struct LuoyeChip: View {
    let title: String
    let active: Bool
    var icon: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                }
                Text(title)
                    .font(.serif(13, medium: active))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? Color.accent : .secondary)
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(
                active ? Color.accent.opacity(0.14) : Color.ink.opacity(0.04),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }
}

/// 统一的搜索输入框容器。
struct LuoyeSearchBar<Trailing: View>: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    var onClear: () -> Void = {}
    @ViewBuilder var trailing: Trailing
    @FocusState private var focused: Bool

    init(
        placeholder: String,
        text: Binding<String>,
        onSubmit: @escaping () -> Void = {},
        onClear: @escaping () -> Void = {},
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.placeholder = placeholder
        self._text = text
        self.onSubmit = onSubmit
        self.onClear = onClear
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .font(.serif(15))
                .focused($focused)
                .submitLabel(.search)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
            trailing
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .background(Color.ink.opacity(focused ? 0.07 : 0.045), in: Capsule())
        .animation(.easeOut(duration: 0.2), value: focused)
    }
}

/// 统一的纸感卡片面板（用于「我的」、账号设置、缓存管理、书籍元数据等）。
struct LuoyePanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct LuoyePanelDivider: View {
    var leadingInset: CGFloat = 50
    var body: some View {
        Divider()
            .opacity(0.45)
            .padding(.leading, leadingInset)
            .padding(.trailing, 17)
    }
}

struct LuoyeSectionHeader: View {
    let title: String
    var trailing: String = ""

    var body: some View {
        HStack {
            Text(title)
                .font(.serif(17, medium: true))
                .foregroundStyle(Color.ink)
            Spacer()
            if !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 3)
    }
}

/// 统一的空状态视图，替代系统默认 San Francisco 字体的 ContentUnavailableView。
struct LuoyeEmptyState: View {
    let icon: String
    let title: String
    var message: String = ""
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accent.opacity(0.11))
                    .frame(width: 58, height: 58)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Color.accent)
            }
            .padding(.bottom, 2)

            Text(title)
                .font(.serif(19, medium: true))
                .tracking(1.5)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)

            if !message.isEmpty {
                Text(message)
                    .font(.serif(13))
                    .lineSpacing(4)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.serif(14, medium: true))
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Color.accent.opacity(0.22), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(Color.accent.opacity(0.5), lineWidth: 0.75)
                        }
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

/// 统一的在线书籍封面卡片，带细微纸张描边、柔和书脊阴影与格式角标。
struct LuoyeRemoteCover: View {
    let title: String
    let coverURLString: String?
    var badge: String = ""

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GeometryReader { proxy in
                let unit = max(0.75, proxy.size.width / 107)
                ZStack(alignment: .topTrailing) {
                    Color.paper
                    Color.accent.opacity(0.08)

                    HStack(alignment: .top, spacing: 10 * unit) {
                        Rectangle()
                            .fill(.tint)
                            .frame(width: max(1, unit), height: 28 * unit)
                            .padding(.top, 2 * unit)
                        VStack(spacing: 2 * unit) {
                            ForEach(Array(title.prefix(8).enumerated()), id: \.offset) { _, character in
                                Text(String(character))
                            }
                        }
                        .font(.serif(14 * unit, medium: true))
                        .foregroundStyle(Color.ink)
                    }
                    .padding(.top, 14 * unit)
                    .padding(.trailing, 14 * unit)

                    if let url = coverURLString.flatMap(URL.init(string:)) {
                        WenkuRemoteImage(url: url)
                    }
                }
            }
            if !badge.isEmpty {
                Text(badge.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 2)
                    .background(Color.ink.opacity(0.72), in: Capsule())
                    .padding(6)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.ink.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: Color.ink.opacity(0.09), radius: 6, x: 1, y: 3)
    }
}
