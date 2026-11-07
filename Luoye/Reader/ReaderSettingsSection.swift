import SwiftUI

/// 「我的」里的阅读设置：和阅读器菜单里的是同一份设置，两边改哪边都一样。
/// 上面一张预览卡片，按当前字号、行距、配色排一小段文字。
struct ReaderSettingsSection: View {
    @AppStorage("reader.fontSize") private var fontSize = 19.0
    @AppStorage("reader.lineHeight") private var lineHeight = ReaderLineHeight.comfortable
    @AppStorage("reader.theme") private var theme = ReaderTheme.system
    @AppStorage("reader.pageMode") private var pageMode = ReaderPageMode.paged
    @AppStorage("reader.menuStyle") private var menuStyle = ReaderMenuStyle.capsule
    @AppStorage(ChapterRules.customPatternKey) private var customPattern = ""
    @Environment(\.systemColorScheme) private var systemScheme

    private var style: ReaderStyle {
        ReaderStyle(fontSize: fontSize, lineHeight: lineHeight.multiplier, scheme: theme.scheme(system: systemScheme))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("阅读")
                .font(.serif(13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 3)

            preview

            PaperPanel {
                VStack(spacing: 16) {
                    row("字号") {
                        HStack(spacing: 10) {
                            Text("A").font(.serif(12)).foregroundStyle(.secondary)
                            Slider(value: $fontSize, in: ReaderStyle.fontSizes, step: 1)
                                .tint(Color.accent)
                            Text("A").font(.serif(18)).foregroundStyle(.secondary)
                            Text("\(Int(fontSize))")
                                .font(.serif(13))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .frame(width: 22, alignment: .trailing)
                        }
                    }
                    row("配色") {
                        HStack(spacing: 12) {
                            ForEach(ReaderTheme.allCases) { option in
                                HStack(spacing: 6) {
                                    ThemeSwatch(option: option, selected: theme == option, size: 18) {
                                        withAnimation(.spring(duration: 0.3)) { theme = option }
                                    }
                                    Text(option.label)
                                        .font(.serif(12))
                                        .foregroundStyle(theme == option ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.secondary))
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    row("行距") {
                        ChoiceRow(options: ReaderLineHeight.allCases, selection: $lineHeight) { $0.label }
                    }
                    row("翻页") {
                        ChoiceRow(options: ReaderPageMode.allCases, selection: $pageMode) { $0.label }
                    }
                    row("菜单") {
                        ChoiceRow(options: ReaderMenuStyle.allCases, selection: $menuStyle) { $0.label }
                    }
                }
                .padding(17)

                Divider().opacity(0.45).padding(.horizontal, 17)

                NavigationLink { ChapterRuleView() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "text.badge.checkmark")
                            .font(.system(size: 16))
                            .foregroundStyle(.tint)
                            .frame(width: 23)
                        Text("TXT 分章规则")
                            .font(.serif(15))
                            .foregroundStyle(Color.ink)
                        Spacer(minLength: 8)
                        Text(customPattern.trimmingCharacters(in: .whitespaces).isEmpty ? "自动识别" : "自定义")
                            .font(.serif(12))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 17)
                    .frame(minHeight: 52)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 按当前设置排的一小段文字，调什么立刻看得见。
    private var preview: some View {
        Text("\u{3000}\u{3000}林尽水源，便得一山，山有小口，仿佛若有光。便舍船，从口入。初极狭，才通人。")
            .font(.custom("NotoSerifSC-Regular", size: fontSize))
            .lineSpacing(style.linePitch - fontSize * 1.45)
            .foregroundStyle(Color(style.text))
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color(style.background), in: .rect(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20).stroke(Color.ink.opacity(0.08), lineWidth: 0.5)
            }
            .animation(.smooth(duration: 0.3), value: fontSize)
            .animation(.smooth(duration: 0.3), value: lineHeight)
            .animation(.smooth(duration: 0.3), value: theme)
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.serif(13))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            content()
        }
    }
}

/// TXT 分章规则：默认自动识别；也可以填一条正则表达式，整行匹配的就当作章节标题。
/// 改了规则，读过的书下次打开会按新规则重新分章（索引缓存会自动作废）。
struct ChapterRuleView: View {
    @AppStorage(ChapterRules.customPatternKey) private var savedPattern = ""
    @State private var pattern = ""
    @State private var sample = "第十二章 春日"

    private var trimmed: String { pattern.trimmingCharacters(in: .whitespaces) }

    /// nil：留空，用自动识别；否则是能不能编译
    private var compiled: NSRegularExpression?? {
        guard !trimmed.isEmpty else { return nil }
        return .some(try? NSRegularExpression(pattern: "^(?:\(trimmed))$"))
    }

    private var valid: Bool {
        if case .some(.none) = compiled { return false }
        return true
    }

    private var sampleMatches: Bool {
        let line = sample.trimmingCharacters(in: .whitespaces)
        switch compiled {
        case .none: return ChapterRules.isHeading(line, custom: nil)
        case .some(.some(let regex)): return ChapterRules.isHeading(line, custom: regex)
        case .some(.none): return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "规则")
                    TextField("留空则自动识别", text: $pattern)
                        .font(.system(size: 15, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 16)
                        .frame(height: 46)
                        .background(Color.ink.opacity(0.045), in: .rect(cornerRadius: 14))
                    Group {
                        if !valid {
                            Label("写法有误", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.red)
                        } else if trimmed.isEmpty {
                            Text("识别「第N章」「卷N」「序章」「楔子」「Chapter N」「【…】」等常见写法。")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("整行符合这条规则的，算作章节标题。")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.serif(12))
                    .animation(.smooth(duration: 0.2), value: valid)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "试一试")
                    HStack(spacing: 10) {
                        TextField("输入一行章名", text: $sample)
                            .font(.serif(15))
                        Image(systemName: sampleMatches ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(sampleMatches ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.tertiary))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 46)
                    .background(Color.ink.opacity(0.045), in: .rect(cornerRadius: 14))
                    Text(sampleMatches ? "会被认作章节标题" : "不会被认作章节标题")
                        .font(.serif(12))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button("保存") { savedPattern = trimmed }
                        .buttonStyle(.glassProminent)
                        .disabled(!valid || trimmed == savedPattern.trimmingCharacters(in: .whitespaces))
                    if !savedPattern.isEmpty {
                        Button("恢复自动识别") {
                            savedPattern = ""
                            pattern = ""
                        }
                        .buttonStyle(.glass)
                    }
                }
                .font(.serif(15))
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background(Color.paper)
        .scrollEdgeEffectHidden(true, for: .bottom).scrollEdgeEffectHidden(true, for: .top).paperTopEdge(extra: 52)
        .navigationTitle("分章规则")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { pattern = savedPattern }
    }
}
