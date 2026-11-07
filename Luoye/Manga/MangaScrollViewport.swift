import SwiftUI
import Observation

/// Own the initial target for each reading layout; resolve it after lazy targets exist.
struct MangaScrollViewport<Content: View>: View {
    @State private var anchorPage: Int
    let mode: MangaReadingMode
    @Binding var visiblePage: Int?
    @State private var target: Int?
    // A user gesture or automatic movement releases initial layout correction.
    @State private var positioned = false
    @State private var interaction = MangaScrollInteraction()
    private let content: Content

    init(initialPage: Int, mode: MangaReadingMode, visiblePage: Binding<Int?>, @ViewBuilder content: () -> Content) {
        _anchorPage = State(initialValue: initialPage)
        self.mode = mode
        _visiblePage = visiblePage
        _target = State(initialValue: initialPage)
        self.content = content()
    }
    private var anchor: UnitPoint { mode.isVertical ? .top : (mode.isRTL ? .trailing : .leading) }
    var body: some View {
        ScrollViewReader { proxy in
            content
                .environment(\.mangaScrollInteraction, interaction)
                .scrollPosition(id: $target, anchor: anchor)
                .onChange(of: target) { _, value in if visiblePage != value { visiblePage = value } }
                .onChange(of: visiblePage) { _, value in
                    guard target != value else { return }
                    if let value {
                        anchorPage = value
                        positioned = false
                        interaction.advanced = false
                    }
                    target = value
                }
                .onDisappear { positioned = true }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting { positioned = true }
                }
                .onScrollGeometryChange(for: CGSize.self) { $0.contentSize } action: { _, size in
                    guard !positioned, !interaction.advanced, size.width > 0, size.height > 0 else { return }
                    DispatchQueue.main.async {
                        guard !positioned, !interaction.advanced else { return }
                        proxy.scrollTo(anchorPage, anchor: anchor)
                    }
                }
        }
    }
}

extension EnvironmentValues {
    @Entry var mangaScrollInteraction: MangaScrollInteraction? = nil
}

@MainActor @Observable final class MangaScrollInteraction {
    var advanced = false
}
