import SwiftUI
import UniformTypeIdentifiers

struct MangaSourcesView: View {
    @Environment(MangaSourceStore.self) private var store
    @State private var address = ""
    @State private var query = ""
    @State private var importing = false
    @State private var busy = false
    @State private var notice: String?
    @State private var catalogue: [SourceCatalogueEntry] = []
    @State private var catalogueURL = "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json"

    var body: some View {
        LuoyeSettingsPage(title: "漫画源管理") {
            LuoyeSettingsSection(title: "本地漫画源", detail: "\(store.sources.count) 个已缓存", footnote: "启动时使用本地缓存，手动刷新才检查更新。") {
                LuoyeSettingsAction(title: store.refreshingSources ? "正在刷新…" : "刷新漫画源", icon: "arrow.clockwise", prominent: true) {
                    Task { await store.refreshAllSources() }
                }.disabled(store.refreshingSources || store.installingDefaults || busy)
                if store.refreshingSources { ProgressView(value: Double(store.refreshProgress), total: Double(max(store.refreshTotal, 1))) }
                if let message = store.refreshMessage { LuoyeNotice(message: message) }
                HStack { Label("MangaDex", systemImage: "books.vertical"); Spacer(); Text("内置").font(.serif(12)).foregroundStyle(.secondary) }
            }
            LuoyeSettingsSection(title: "添加与导入") {
                DisclosureGroup("导入漫画源") {
                    VStack(spacing: 14) {
                        TextField("HTTPS 脚本地址", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).luoyeSettingsInput()
                        LuoyeSettingsAction(title: "从地址导入", icon: "link") {
                            guard let url = URL(string: address) else { notice = "地址无效"; return }
                            perform { try await store.install(url: url); notice = "漫画源已导入"; address = "" }
                        }.disabled(busy || address.isEmpty)
                        LuoyeSettingsAction(title: "导入本地文件", icon: "doc.badge.plus") { importing = true }.disabled(busy)
                    }.padding(.top, 14)
                }
                DisclosureGroup("默认漫画源") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("补齐缺失的默认漫画源，已安装的配置会保留。").font(.serif(12)).foregroundStyle(.secondary)
                        LuoyeSettingsAction(title: store.installingDefaults ? "正在补齐…" : "补齐默认漫画源", icon: "square.stack.3d.up.badge.plus") {
                            Task { await store.installDefaultsIfNeeded(retry: true) }
                        }.disabled(store.installingDefaults || store.refreshingSources || busy)
                        if store.installingDefaults { ProgressView(value: Double(store.defaultProgress), total: Double(max(store.defaultTotal, 1))) }
                        ForEach(store.defaultFailures.keys.sorted(), id: \.self) { key in Text("\(key)：\(store.defaultFailures[key] ?? "")").font(.serif(11)).foregroundStyle(.secondary) }
                    }.padding(.top, 14)
                }
                DisclosureGroup("漫画源仓库") {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("仓库 index.json 地址", text: $catalogueURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).luoyeSettingsInput()
                        LuoyeSettingsAction(title: "读取仓库", icon: "tray.and.arrow.down") { perform { catalogue = try await SourceCatalogueEntry.load(from: catalogueURL) } }.disabled(busy)
                        ForEach(catalogue) { entry in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.name)
                                    if let description = entry.description { Text(description).font(.serif(11)).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Button(store.sources.contains(where: { $0.key == entry.key }) ? "更新" : "安装") {
                                    perform { try await store.install(url: entry.scriptURL); notice = "已安装 \(entry.name)" }
                                }.buttonStyle(LuoyeActionStyle()).disabled(busy)
                            }
                        }
                    }.padding(.top, 14)
                }
            }
            if busy { ProgressView("正在处理漫画源…").font(.serif(12)) }
            if let notice { LuoyeNotice(message: notice) }
            VStack(alignment: .leading, spacing: 12) {
                LuoyeSectionHeader(title: "已安装漫画源")
                LuoyeSearchBar(placeholder: "查找漫画源", text: $query)
                LazyVStack(spacing: 12) {
                    ForEach(store.sources.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.key.localizedCaseInsensitiveContains(query) }) { source in
                        LuoyePanel {
                            Toggle(isOn: Binding(get: { store.sources.first(where: { $0.key == source.key })?.enabled ?? false }, set: { store.setEnabled(source.key, enabled: $0) })) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(source.name).font(.serif(15, medium: true))
                                    Text("v" + source.version).font(.serif(11)).foregroundStyle(.secondary)
                                }
                            }.padding(17)
                            LuoyePanelDivider(leadingInset: 17)
                            HStack(spacing: 0) {
                                NavigationLink { MangaSourceConfigurationView(descriptor: source) } label: {
                                    LuoyeSettingsRow(title: "账户与设置", icon: "person.crop.circle", arrow: true)
                                }.buttonStyle(.plain)
                                Menu {
                                    if let url = source.updateURL { Button("更新漫画源", systemImage: "arrow.clockwise") { perform { try await store.install(url: url); notice = "漫画源已更新" } } }
                                    Button("移除漫画源", systemImage: "trash", role: .destructive) { store.remove(source.key) }
                                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                                    .padding(.trailing, 8).disabled(busy || store.refreshingSources || store.installingDefaults)
                                    .accessibilityLabel(source.name + "的更多操作")
                            }
                        }
                    }
                }
                if !query.isEmpty && !store.sources.contains(where: { $0.name.localizedCaseInsensitiveContains(query) || $0.key.localizedCaseInsensitiveContains(query) }) {
                    LuoyeEmptyState(icon: "magnifyingglass", title: "没有找到漫画源", message: "试试其他名称。")
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "js") ?? .plainText]) { result in
            if case .success(let url) = result {
                perform {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let script = try String(contentsOf: url, encoding: .utf8)
                    try await store.install(script: script)
                    notice = "漫画源已导入"
                }
            }
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true; notice = nil
        Task {
            defer { busy = false }
            do { try await operation() } catch { notice = error.localizedDescription }
        }
    }
}

struct SourceCatalogueEntry: Identifiable {
    var id: String { scriptURL.absoluteString }
    let key: String
    let name: String
    let description: String?
    let scriptURL: URL
    static func load(from raw: String) async throws -> [Self] {
        guard let url = URL(string: raw), url.scheme == "https" else { throw MangaScriptRuntime.RuntimeError.message("仓库地址必须为 HTTPS") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4_000_000,
              let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw MangaScriptRuntime.RuntimeError.message("漫画源仓库格式无效") }
        return entries.compactMap { entry in
            guard let name = entry["name"] as? String,
                  let file = entry["url"] as? String ?? entry["fileName"] as? String ?? entry["filename"] as? String,
                  let scriptURL = URL(string: file, relativeTo: url)?.absoluteURL, scriptURL.scheme == "https" else { return nil }
            return Self(key: entry["key"] as? String ?? "", name: name, description: entry["description"] as? String, scriptURL: scriptURL)
        }
    }
}

struct MangaSourceConfigurationView: View {
    @Environment(MangaSourceStore.self) private var store
    let descriptor: MangaSourceDescriptor
    @State private var account = ""
    @State private var password = ""
    @State private var loggedIn = false
    @State private var passwordLogin = false
    @State private var webURL: URL?
    @State private var webLogin = false
    @State private var cookieFields: [String] = []
    @State private var cookieValues: [String: String] = [:]
    @State private var settings: [String: [String: Any]] = [:]
    @State private var values: [String: Any] = [:]
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        LuoyeSettingsPage(title: descriptor.name) {
            LuoyeSettingsSection(title: "源账户") {
                if loggedIn {
                    Text("已登录")
                    LuoyeSettingsAction(title: "退出登录", icon: "rectangle.portrait.and.arrow.right") { action { runtime in _ = try await runtime.call("__logout"); loggedIn = false } }
                } else {
                    if passwordLogin {
                    TextField("账号", text: $account).textInputAutocapitalization(.never).autocorrectionDisabled().luoyeSettingsInput()
                    SecureField("密码", text: $password).luoyeSettingsInput()
                    LuoyeSettingsAction(title: "登录", icon: "person.crop.circle", prominent: true) {
                        action { runtime in
                            _ = try await runtime.call("__login", arguments: [account, password])
                            password = ""; loggedIn = true
                        }
                    }.disabled(busy || account.isEmpty || password.isEmpty)
                    }
                    if webURL != nil { LuoyeSettingsAction(title: "使用网页登录", icon: "globe") { webLogin = true } }
                    if !cookieFields.isEmpty {
                        ForEach(cookieFields, id: \.self) { field in
                            SecureField(field, text: Binding(get: { cookieValues[field] ?? "" }, set: { cookieValues[field] = $0 })).luoyeSettingsInput()
                        }
                        LuoyeSettingsAction(title: "使用 Cookie 登录", icon: "key") {
                            action { runtime in
                                _ = try await runtime.call("__cookieLogin", arguments: [cookieFields.map { cookieValues[$0] ?? "" }])
                                cookieValues = [:]; loggedIn = true
                            }
                        }.disabled(busy)
                    }
                    if !passwordLogin && webURL == nil && cookieFields.isEmpty { Text("此漫画源无需账户登录").foregroundStyle(.secondary) }
                }
            }
            if !settings.isEmpty {
            LuoyeSettingsSection(title: "漫画源设置") {
                ForEach(settings.keys.sorted(), id: \.self) { key in
                    let config = settings[key] ?? [:]
                    let title = config["title"] as? String ?? key
                    switch config["type"] as? String {
                    case "switch":
                        Toggle(title, isOn: Binding(get: { values[key] as? Bool ?? false }, set: { save(key, value: $0) }))
                    case "select":
                        let options = config["options"] as? [[String: Any]] ?? []
                        let selectedValue = String(describing: values[key] ?? "")
                        let selectedTitle = options.first { String(describing: $0["value"] ?? "") == selectedValue }?["text"] as? String ?? selectedValue
                        Menu {
                            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                                let value = String(describing: option["value"] ?? "")
                                Button { save(key, value: value) } label: {
                                    if value == selectedValue { Label(option["text"] as? String ?? value, systemImage: "checkmark") }
                                    else { Text(option["text"] as? String ?? value) }
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Text(title).font(.serif(14)).foregroundStyle(Color.ink)
                                Spacer(minLength: 8)
                                Text(selectedTitle).font(.serif(13)).foregroundStyle(Color.accent).lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.disabled(busy)
                    case "callback":
                        LuoyeSettingsAction(title: title, icon: "slider.horizontal.3") { action { runtime in _ = try await runtime.call("settings.\(key).callback") } }
                    default:
                        TextField(title, text: Binding(get: { values[key] as? String ?? "" }, set: { values[key] = $0 })).luoyeSettingsInput()
                            .onSubmit { save(key, value: values[key] ?? "") }
                    }
                }
            }
            }
            if busy { ProgressView() }
            if let notice { LuoyeNotice(message: notice) }
        }
        .sheet(isPresented: $webLogin) {
            if let url = webURL, let runtime = try? store.runtime(for: descriptor) {
                MangaSourceWebLogin(runtime: runtime, url: url) { loggedIn = true }
            }
        }
        .task {
            do {
                let runtime = try store.runtime(for: descriptor)
                let object = try JSONSerialization.jsonObject(with: await runtime.metadata()) as? [String: Any] ?? [:]
                let modes = object["accountModes"] as? [String: Any] ?? [:]
                passwordLogin = modes["password"] as? Bool ?? false
                webURL = (modes["webURL"] as? String).flatMap(URL.init(string:))
                cookieFields = modes["cookieFields"] as? [String] ?? []
                settings = object["settings"] as? [String: [String: Any]] ?? [:]
                let data = try await runtime.call("__currentSettings")
                values = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                loggedIn = object["logged"] as? Bool ?? false
            } catch { notice = error.localizedDescription }
        }
    }
    private func save(_ key: String, value: Any) {
        action { runtime in _ = try await runtime.call("__setSetting", arguments: [key, value]); values[key] = value }
    }
    private func action(_ operation: @escaping @MainActor (MangaScriptRuntime) async throws -> Void) {
        busy = true; notice = nil
        Task {
            defer { busy = false }
            do { try await operation(store.runtime(for: descriptor)) } catch { notice = error.localizedDescription }
        }
    }
}
