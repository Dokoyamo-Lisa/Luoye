import SwiftUI

/// Layout values follow the current Fanhua bookshelf on compact and regular widths.
private struct LuoyeContentMargins: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    var top: CGFloat
    var maximumWidth: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, ShelfMetrics.of(sizeClass).margin)
            .padding(.top, top)
            .padding(.bottom, 30)
            .frame(maxWidth: maximumWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

extension View {
    func luoyeContentMargins(top: CGFloat = 8, maximumWidth: CGFloat = 1120) -> some View {
        modifier(LuoyeContentMargins(top: top, maximumWidth: maximumWidth))
    }
    func luoyeRootSurface() -> some View {
        background(Color.paper)
            .scrollEdgeEffectHidden(true, for: .top)
            .scrollEdgeEffectHidden(true, for: .bottom)
            .paperTopEdge()
            .toolbar(.hidden, for: .navigationBar)
    }
    func luoyeFormStyle() -> some View {
        font(.serif(14))
            .scrollContentBackground(.hidden)
            .background(Color.paper)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// 一行一本书的列表：手机上一列；iPad 上两列并排，宽屏不再是一条条拉得很长的横条。
struct LuoyeRowGrid<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewBuilder var content: Content
    var body: some View {
        if sizeClass == .regular {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)],
                      alignment: .leading, spacing: 16) { content }
        } else {
            VStack(alignment: .leading, spacing: 12) { content }
        }
    }
}

struct LuoyeModeHeading: View {
    @AppStorage("luoye.mode") private var mode = "haiku"
    @Environment(\.horizontalSizeClass) private var sizeClass
    let caption: String
    var compact = false
    var body: some View {
        Menu {
            Button { mode = "haiku" } label: { Label("Haiku · 小说", systemImage: "leaf") }
            Button { mode = "manga" } label: { Label("Manga · 漫画", systemImage: "photo.on.rectangle.angled") }
        } label: {
            if compact {
                HStack(spacing: 6) {
                    Image(systemName: mode == "manga" ? "photo.on.rectangle.angled" : "leaf")
                    Text(mode == "manga" ? "Manga" : "Haiku").font(.serif(13))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                }.foregroundStyle(Color.accent).padding(.horizontal, 12).frame(height: 34)
                    .background(Color.accent.opacity(0.08), in: Capsule())
            } else {
            HStack(alignment: .top, spacing: 7) {
                PageHeader(title: mode == "manga" ? "Manga" : "Haiku", caption: caption, titleSize: ShelfMetrics.of(sizeClass).titleSize)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).padding(.top, 13)
            }
            .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("切换阅读空间，当前\(mode == "manga" ? "Manga 漫画" : "Haiku 小说")")
    }
}

struct LuoyeSettingsRow: View {
    let title: String
    let icon: String
    var detail = ""
    var arrow = true
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon).font(.system(size: 17, weight: .light))
                .foregroundStyle(Color.accent).frame(width: 25)
            Text(title).font(.serif(15)).foregroundStyle(Color.ink)
            Spacer(minLength: 8)
            if !detail.isEmpty { Text(detail).font(.serif(12)).foregroundStyle(.secondary).lineLimit(1) }
            if arrow { Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary) }
        }
        .frame(minHeight: 58).padding(.horizontal, 17).contentShape(Rectangle())
    }
}

struct LuoyeNotice: View {
    let message: String
    var icon = "info.circle"
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).foregroundStyle(Color.accent)
            Text(message).font(.serif(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct LuoyeActionStyle: ButtonStyle {
    var prominent = false
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.serif(14, medium: prominent || selected))
            .foregroundStyle(prominent || selected ? Color.accent : Color.ink)
            .padding(.horizontal, 16).frame(minHeight: 44)
            .background(Color.accent.opacity(prominent || selected ? 0.15 : 0.06), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}
