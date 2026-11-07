import SwiftUI

struct MangaSourcePickerView: View {
    @Environment(MangaSourceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("manga.activeSource") private var selectedSource = "mangadex"
    @State private var query = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LuoyeSearchBar(placeholder: "查找漫画源", text: $query)
                    LuoyePanel {
                        if query.isEmpty || "MangaDex".localizedCaseInsensitiveContains(query) { row("mangadex", name: "MangaDex") }
                        ForEach(store.sources.filter { $0.enabled && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }) { source in
                            LuoyePanelDivider()
                            row(source.key, name: source.name)
                        }
                    }
                    NavigationLink { MangaSourcesView() } label: { LuoyeSettingsRow(title: "漫画源管理", icon: "slider.horizontal.3") }
                        .buttonStyle(.plain).background(Color.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
                }.luoyeContentMargins(top: 16, maximumWidth: 820)
            }
            .background(Color.paper).navigationTitle("切换漫画源").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
    private func row(_ id: String, name: String) -> some View {
        Button { selectedSource = id; dismiss() } label: {
            HStack(spacing: 12) {
                Text(name).font(.serif(15)).foregroundStyle(Color.ink)
                Spacer()
                if selectedSource == id { Image(systemName: "checkmark").font(.system(size: 14, weight: .medium)).foregroundStyle(.tint) }
            }.padding(.horizontal, 17).frame(minHeight: 54).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selectedSource == id ? [.isSelected] : [])
    }
}
