import SwiftUI

struct MangaRemoteFavoriteSourcesView: View {
    @Environment(MangaSourceStore.self) private var store
    @State private var query = ""
    private var enabled: [MangaSourceDescriptor] {
        store.sources.filter { $0.enabled && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.key.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        LuoyeSettingsPage(title: "账户与收藏") {
            LuoyeSearchBar(placeholder: "查找漫画源", text: $query)
            Text("各漫画源的账户与收藏分别保存。").font(.serif(12)).foregroundStyle(.secondary)
            LazyVStack(spacing: 14) {
                ForEach(enabled) { descriptor in
                    if let source = store.source(for: descriptor.key) as? MangaScriptSource {
                        LuoyePanel {
                            Text(descriptor.name).font(.serif(16, medium: true)).frame(maxWidth: .infinity, alignment: .leading).padding(17)
                            LuoyePanelDivider(leadingInset: 17)
                            NavigationLink { MangaSourceConfigurationView(descriptor: descriptor) } label: {
                                LuoyeSettingsRow(title: "账户与设置", icon: "person.crop.circle")
                            }
                            LuoyePanelDivider()
                            NavigationLink { MangaRemoteFavoritesView(source: source) } label: {
                                LuoyeSettingsRow(title: "源站收藏", icon: "heart")
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            if enabled.isEmpty { LuoyeEmptyState(icon: "leaf", title: "暂无可用漫画源", message: "可以在漫画源管理中启用漫画源，或换个名称查找。") }
        }
    }
}

struct MangaRemoteFavoritesView: View {
    let source: MangaScriptSource
    var comic: MangaOnlineComic? = nil
    @State private var folders: [Folder] = []
    @State private var favorited: Set<String> = []
    @State private var busy = false
    @State private var error: String?
    @State private var newName = ""
    @State private var creating = false
    @State private var deleting: Folder?
    @State private var canCreate = false
    @State private var canDelete = false
    struct Folder: Identifiable { let id: String; let name: String }

    var body: some View {
        LuoyeSettingsPage(title: comic == nil ? "源站收藏" : "收藏到源站") {
            if let error {
                LuoyeNotice(message: error)
                if !busy { LuoyeSettingsAction(title: "重试", icon: "arrow.clockwise") { Task { await load() } } }
            }
            if busy { ProgressView().frame(maxWidth: .infinity) }
            VStack(alignment: .leading, spacing: 12) {
                LuoyeSectionHeader(title: source.displayName, trailing: "\(folders.count) 个收藏夹")
                ForEach(folders) { folder in
                    LuoyePanel {
                        HStack(spacing: 0) {
                            NavigationLink {
                                MangaSourceListingView(title: folder.name, source: source) { page in
                                    try await source.runtime.call("__favoriteList", arguments: [folder.id, page])
                                }
                            } label: { LuoyeSettingsRow(title: folder.name, icon: "folder") }.buttonStyle(.plain)
                            if let comic {
                                Button(favorited.contains(folder.id) ? "移出" : "加入") { Task { await changeFavorite(folder, comic: comic) } }
                                    .buttonStyle(LuoyeActionStyle(selected: favorited.contains(folder.id))).disabled(busy).padding(.trailing, 12)
                            }
                            if canDelete {
                                Menu { Button("删除收藏夹", systemImage: "trash", role: .destructive) { deleting = folder } } label: {
                                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                                }.padding(.trailing, 8).disabled(busy).accessibilityLabel("管理" + folder.name)
                            }
                        }
                    }
                }
                if folders.isEmpty && !busy && error == nil { LuoyeEmptyState(icon: "folder", title: "暂无收藏夹") }
                if canCreate { LuoyeSettingsAction(title: "新建收藏夹", icon: "folder.badge.plus") { creating = true }.disabled(busy) }
            }
            LuoyePanel {
                NavigationLink { MangaSourceConfigurationView(descriptor: source.descriptor) } label: {
                    LuoyeSettingsRow(title: "源账户与设置", icon: "person.crop.circle")
                }.buttonStyle(.plain)
            }
        }
        .task { await load() }.refreshable { await load() }
        .alert("新建收藏夹", isPresented: $creating) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                Task {
                    do { _ = try await source.runtime.call("favorites.addFolder",arguments:[newName]);newName="";await load() }
                    catch { self.error=error.localizedDescription }
                }
            }.disabled(newName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("删除这个源站收藏夹？", isPresented: Binding(get:{deleting != nil},set:{if !$0{deleting=nil}}), titleVisibility:.visible) {
            if let folder = deleting {
                Button("删除 \(folder.name)",role:.destructive) {
                    Task {
                        do { _=try await source.runtime.call("favorites.deleteFolder",arguments:[folder.id]);deleting=nil;await load() }
                        catch { self.error=error.localizedDescription }
                    }
                }
            }
        }
    }
    private func changeFavorite(_ folder: Folder, comic: MangaOnlineComic) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let adding = !favorited.contains(folder.id)
            let args: [Any] = [comic.id, folder.id, adding, comic.favoriteID as Any? ?? NSNull()]
            _ = try await source.runtime.call("__changeFavorite", arguments: args)
            if adding { favorited.insert(folder.id) } else { favorited.remove(folder.id) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func load() async {
        guard !busy else { return }
        busy=true
        defer {busy=false}
        do {
            let metadata=try JSONSerialization.jsonObject(with:await source.runtime.metadata()) as? [String:Any] ?? [:]
            let modes=metadata["favoriteModes"] as? [String:Bool] ?? [:]
            canCreate=modes["create"] ?? false;canDelete=modes["delete"] ?? false
            let data=try await source.runtime.call("__favoriteFolders",arguments:[comic?.id as Any? ?? NSNull()])
            let result=try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
            folders=(result["folders"] as? [[String:String]] ?? []).compactMap { value in
                guard let id=value["id"],let name=value["name"] else{return nil};return Folder(id:id,name:name)
            }
            favorited=Set(result["favorited"] as? [String] ?? [])
            if comic != nil, folders.count == 1, folders.first?.id == "" {
                let details=try JSONSerialization.jsonObject(with:await source.runtime.call("__details",arguments:[comic!.id])) as? [String:Any] ?? [:]
                if details["isFavorite"] as? Bool == true { favorited.insert("") }
            }
            error=nil
        }catch{self.error=error.localizedDescription}
    }
}
