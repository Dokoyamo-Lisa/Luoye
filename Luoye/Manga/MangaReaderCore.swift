import Foundation
import SwiftUI

struct MangaImagePage: View {
    let resource: MangaPageResource
    var fitWidth = false
    var onLoading: () -> Void = {}
    var onLoaded: () -> Void = {}
    let onTap: () -> Void
    @State private var model = MangaPageImageModel()
    @State private var retryID = UUID()
    private struct LoadIdentity: Hashable { let resource: String; let retry: UUID }

    var body: some View {
        Group {
            if model.resourceKey == resource.key, let image = model.image {
                if fitWidth {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .onTapGesture(perform: onTap)
                } else {
                    MangaZoomableImage(image: image, onTap: onTap)
                }
            } else if model.resourceKey == resource.key && model.failure {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("图片加载失败")
                    Button("重新加载") { retryID = UUID() }
                    Button("阅读菜单", action: onTap)
                }
                .font(.serif(12))
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: fitWidth ? 240 : nil)
            } else {
                ProgressView().tint(Color.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: fitWidth ? 240 : nil)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
            }
        }
        .task(id: LoadIdentity(resource: resource.key, retry: retryID)) {
            guard !Task.isCancelled else { return }
            if model.resourceKey != resource.key || model.image == nil { onLoading() }
            if await model.load(resource), !Task.isCancelled { onLoaded() }
        }
        .onDisappear { model.cancel(keepingImage: fitWidth) }
    }

}

extension View {
    @ViewBuilder
    func mangaPageSnapping(_ enabled: Bool) -> some View {
        if enabled { self.scrollTargetBehavior(.paging) }
        else { self }
    }
}

struct MangaReaderSettingsView: View {
    var inNavigationStack = false
    @AppStorage("manga.reader.theme") private var theme = ReaderTheme.paper
    @AppStorage("manga.reader.menuStyle") private var menuStyle = ReaderMenuStyle.capsule
    @Environment(\.dismiss) private var dismiss
    @AppStorage("manga.reader.mode") private var mode = MangaReadingMode.pageLeftToRight
    @AppStorage("manga.reader.showPageNumber") private var showPageNumber = true
    @AppStorage("manga.reader.preloadCount") private var preloadCount = 2
    @AppStorage("manga.reader.twoPage") private var twoPage = false
    @AppStorage("manga.reader.coverAlone") private var coverAlone = true
    @AppStorage("manga.reader.autoPageSeconds") private var autoPageSeconds = 8.0
    @AppStorage("manga.reader.autoMode") private var autoKind = AutoMode.pages
    @AppStorage("manga.reader.scrollLines") private var scrollLines = 30.0

    var body: some View {
        if inNavigationStack { settings }
        else {
            NavigationStack {
                settings.toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.font(.serif(14)) } }
            }
        }
    }
    private var settings: some View {
        LuoyeSettingsPage(title: "阅读设置") {
            LuoyeSettingsSection(title: "界面") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("配色").font(.serif(12)).foregroundStyle(.secondary)
                    ChoiceRow(options: ReaderTheme.allCases, selection: $theme) { $0.label }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("阅读菜单").font(.serif(12)).foregroundStyle(.secondary)
                    ChoiceRow(options: ReaderMenuStyle.allCases, selection: $menuStyle) { $0.label }
                }
            }
            LuoyeSettingsSection(title: "阅读方式") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(MangaReadingMode.allCases) { option in
                        Button { mode = option } label: {
                            HStack(spacing: 7) {
                                Text(option.title).font(.serif(13, medium: mode == option))
                                Spacer(minLength: 0)
                                if mode == option { Image(systemName: "checkmark").font(.system(size: 11, weight: .medium)) }
                            }
                            .foregroundStyle(mode == option ? Color.accent : Color.ink)
                            .padding(.horizontal, 12).frame(minHeight: 46)
                            .background(mode == option ? Color.accent.opacity(0.13) : Color.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
                        }.buttonStyle(.plain).accessibilityAddTraits(mode == option ? .isSelected : [])
                    }
                }
            }
            LuoyeSettingsSection(title: "页面") {
                Toggle("双页展开", isOn: $twoPage).frame(minHeight: 36)
                    .disabled(mode != .pageLeftToRight && mode != .pageRightToLeft)
                if twoPage { Toggle("封面单页", isOn: $coverAlone).frame(minHeight: 36) }
                Toggle("显示页码", isOn: $showPageNumber).frame(minHeight: 36)
                Stepper("预加载 \(preloadCount) 页", value: $preloadCount, in: 1...4).frame(minHeight: 36)
            }
            LuoyeSettingsSection(title: "自动阅读", footnote: "在阅读菜单中开始或停止自动阅读。") {
                LuoyeSegmentBar(items: [.init(value: AutoMode.pages, title: "自动翻页"), .init(value: AutoMode.scroll, title: "自动下拉")], selection: $autoKind)
                if autoKind == .pages {
                    SpeedDial(speed: Binding(get: { AutoMode.speed(forPageSeconds: autoPageSeconds) }, set: { autoPageSeconds = AutoMode.pageSeconds(atSpeed: $0) }),
                              title: "翻页间隔", reading: String(format: "%.1f", autoPageSeconds), unit: "秒 / 页") { String(format: "%.0f", AutoMode.pageSeconds(atSpeed: $0)) }
                } else {
                    SpeedDial(speed: Binding(get: { AutoMode.speed(forScrollLines: scrollLines) }, set: { scrollLines = AutoMode.scrollLines(atSpeed: $0) }),
                              title: "下拉速度", reading: String(format: "%.1f", scrollLines * 24 / 60), unit: "点 / 秒") { String(format: "%.0f", AutoMode.scrollLines(atSpeed: $0) * 24 / 60) }
                }
            }
        }
    }
}
