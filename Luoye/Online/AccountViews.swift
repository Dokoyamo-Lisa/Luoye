import SwiftData
import SwiftUI

struct WenkuAccountView: View {
    @Environment(WenkuService.self) private var service
    @Environment(WebsiteShelfStore.self) private var shelf
    @Environment(ZLibService.self) private var zlibService
    @Environment(ZLibAccountStore.self) private var zlibAccount
    @Query private var books: [Book]
    @State private var wenkuLogin = false
    @State private var zlibLogin = false
    @AppStorage("wenku.autoSyncShelf") private var autoSync = true
    @AppStorage("app.appearance") private var appearance = AppAppearance.system
    @AppStorage("app.eyeCare") private var eyeCare = false
    @AppStorage("app.eyeCareStrength") private var eyeCareStrength = 0.5

    private var activeQuota: ZLibQuota? {
        zlibService.quota ?? zlibAccount.quota
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack { ArchiveHeading(title: "我的", subtitle: ""); Spacer(); LuoyeModeHeading(caption: "小说空间", compact: true) }

                    accountSummaryHeader

                    LuoyeSettingsSection(title: "番茄小说") {
                        NavigationLink { TomatoSettingsView() } label: { Label("服务、下载与阅读", systemImage: "books.vertical") }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        LuoyeSectionHeader(title: "Z-Library 书库与额度")
                        LuoyePanel {
                            HStack(spacing: 12) {
                                Image(systemName: zlibService.authenticated ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                                    .font(.system(size: 17))
                                    .foregroundStyle(.tint)
                                    .frame(width: 23)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(zlibService.authenticated ? (zlibService.username.isEmpty ? "Z-Library 读者" : zlibService.username) : "Z-Library 未登录")
                                        .font(.serif(15, medium: true))
                                        .foregroundStyle(Color.ink)
                                    Text(zlibService.authenticated ? (activeQuota?.summaryText ?? "账号已连接，同步后可查看今日下载额度") : "登录后可同步个人书库、下载历史与每日额度")
                                        .font(.serif(11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if zlibService.authenticated {
                                    NavigationLink { ZLibAccountSettingsView() } label: {
                                        Text("账号设置")
                                            .font(.serif(12, medium: true))
                                            .foregroundStyle(Color.ink)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Button {
                                        zlibLogin = true
                                    } label: {
                                        Text("登录")
                                            .font(.serif(12, medium: true))
                                            .foregroundStyle(Color.ink)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 6)
                                            .background(Color.accentColor.opacity(0.16), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 17)
                            .frame(minHeight: 64)

                            LuoyePanelDivider()

                            NavigationLink {
                                ZLibCloudLibraryView(initialTab: "favorites")
                            } label: {
                                SettingsLine(title: "账号书库 · 收藏", icon: "bookmark", value: "\(zlibAccount.favorites.count) 本", arrow: true)
                            }
                            .buttonStyle(.plain)

                            LuoyePanelDivider()

                            NavigationLink {
                                ZLibCloudLibraryView(initialTab: "downloads")
                            } label: {
                                SettingsLine(title: "下载历史", icon: "arrow.down.circle", value: "\(zlibAccount.downloads.count) 本", arrow: true)
                            }
                            .buttonStyle(.plain)

                            LuoyePanelDivider()

                            NavigationLink {
                                ZLibCloudLibraryView(initialTab: "booklists")
                            } label: {
                                SettingsLine(title: "个人书单", icon: "list.bullet.rectangle", value: "\(zlibAccount.booklists.count) 个", arrow: true)
                            }
                            .buttonStyle(.plain)

                            LuoyePanelDivider()

                            Button {
                                Task { await zlibAccount.sync(using: zlibService) }
                            } label: {
                                HStack {
                                    SettingsLine(
                                        title: "同步 Z-Library 书库与额度",
                                        icon: "arrow.triangle.2.circlepath",
                                        value: zlibAccount.syncing ? "同步中" : (activeQuota?.resetHint ?? "")
                                    )
                                    if zlibAccount.syncing { ProgressView().padding(.trailing, 17) }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!zlibService.authenticated || zlibAccount.syncing)
                        }

                        if let error = zlibAccount.error {
                            Text(error).font(.serif(12)).foregroundStyle(.red).padding(.horizontal, 4)
                        } else if let date = zlibAccount.syncedAt {
                            Text("Z-Library 上次同步 · " + date.formatted(date: .abbreviated, time: .shortened))
                                .font(.serif(11))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 4)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        LuoyeSectionHeader(title: "轻小说文库")
                        LuoyePanel {
                            HStack(spacing: 12) {
                                Image(systemName: service.authenticated ? "checkmark.seal" : "book.closed")
                                    .font(.system(size: 17))
                                    .foregroundStyle(.tint)
                                    .frame(width: 23)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(service.authenticated ? (service.username.isEmpty ? "文库读者" : service.username) : "轻小说文库未登录")
                                        .font(.serif(15, medium: true))
                                        .foregroundStyle(Color.ink)
                                    Text(service.authenticated ? "文库会话已连接" : "登录后可同步文库收藏书架")
                                        .font(.serif(11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if service.authenticated {
                                    NavigationLink { WenkuAccountSettingsView() } label: {
                                        Text("账号设置")
                                            .font(.serif(12, medium: true))
                                            .foregroundStyle(Color.ink)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Button {
                                        wenkuLogin = true
                                    } label: {
                                        Text("登录")
                                            .font(.serif(12, medium: true))
                                            .foregroundStyle(Color.ink)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 6)
                                            .background(Color.accentColor.opacity(0.16), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 17)
                            .frame(minHeight: 62)

                            LuoyePanelDivider()

                            NavigationLink { WenkuCloudShelfView() } label: {
                                SettingsLine(title: "文库官网书架", icon: "cloud", value: "\(shelf.books.count) 本", arrow: true)
                            }
                            .buttonStyle(.plain)

                            LuoyePanelDivider()

                            Button {
                                Task { await shelf.sync(using: service) }
                            } label: {
                                HStack {
                                    SettingsLine(title: "同步文库书架", icon: "arrow.triangle.2.circlepath", value: shelf.syncing ? "同步中" : "")
                                    if shelf.syncing { ProgressView().padding(.trailing, 17) }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!service.authenticated || shelf.syncing)

                            LuoyePanelDivider()

                            Toggle(isOn: $autoSync) {
                                Text("登录后自动同步书库").font(.serif(15))
                            }
                            .tint(.accentColor)
                            .padding(.horizontal, 17)
                            .frame(minHeight: 57)
                        }

                        if let error = shelf.error {
                            Text(error).font(.serif(12)).foregroundStyle(.red).padding(.horizontal, 4)
                        } else if let date = shelf.syncedAt {
                            Text("文库上次同步 · " + date.formatted(date: .abbreviated, time: .shortened))
                                .font(.serif(11))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 4)
                        }
                    }

                    ReaderSettingsSection()

                    VStack(alignment: .leading, spacing: 12) {
                        LuoyeSectionHeader(title: "通用")
                        LuoyePanel {
                            HStack(spacing: 12) {
                                Image(systemName: "circle.lefthalf.filled")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.tint)
                                    .frame(width: 23)
                                Text("外观").font(.serif(15)).foregroundStyle(Color.ink)
                                ChoiceRow(options: AppAppearance.allCases, selection: $appearance) { $0.label }
                                    .padding(.leading, 8)
                            }
                            .padding(.horizontal, 17)
                            .frame(minHeight: 56)

                            LuoyePanelDivider()

                            VStack(spacing: 0) {
                                Toggle(isOn: $eyeCare.animation(.smooth(duration: 0.3))) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "eye")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.tint)
                                            .frame(width: 23)
                                        Text("护眼模式").font(.serif(15)).foregroundStyle(Color.ink)
                                    }
                                }
                                .tint(.accentColor)
                                .frame(minHeight: 52)
                                if eyeCare {
                                    HStack(spacing: 10) {
                                        Text("暖").font(.serif(12)).foregroundStyle(.secondary).frame(width: 23)
                                        Slider(value: $eyeCareStrength, in: 0.2 ... 1)
                                            .tint(Color.accentColor)
                                    }
                                    .padding(.bottom, 12)
                                }
                            }
                            .padding(.horizontal, 17)

                            LuoyePanelDivider()

                            NavigationLink { CacheSettingsView() } label: {
                                SettingsLine(title: "缓存管理", icon: "internaldrive", value: "上限 300 MB", arrow: true)
                            }
                            .buttonStyle(.plain)

                            LuoyePanelDivider()

                            SettingsLine(title: "本地藏书", icon: "books.vertical", value: "\(books.count) 本")

                            LuoyePanelDivider()

                            SettingsLine(title: "版本", icon: "info.circle", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1")
                        }
                    }

                    VStack(spacing: 7) {
                        Image(systemName: "leaf")
                            .font(.system(size: 16, weight: .ultraLight))
                            .foregroundStyle(Color.accentColor.opacity(0.65))
                        Text("落叶 · 把故事留在手边")
                            .font(.serif(12))
                            .tracking(1)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
                .luoyeContentMargins()
            }
            .background(Color.paper)
            .scrollEdgeEffectHidden(true, for: .bottom)
            .toolbarBackground(.hidden, for: .tabBar)
            .luoyeRootSurface()
            .sheet(isPresented: $wenkuLogin) { WenkuLoginView() }
            .sheet(isPresented: $zlibLogin) { ZLibLoginView() }
        }
    }

    private var accountSummaryHeader: some View {
        let displayTitle: String = {
            if zlibService.authenticated && !zlibService.username.isEmpty {
                return zlibService.username
            }
            if service.authenticated && !service.username.isEmpty {
                return service.username
            }
            return (zlibService.authenticated || service.authenticated) ? "落叶读者" : "欢迎来到落叶"
        }()

        let avatarText: String = {
            if zlibService.authenticated || service.authenticated {
                return String(displayTitle.prefix(1))
            }
            return "叶"
        }()

        let statusSubtitle: String = {
            switch (service.authenticated, zlibService.authenticated) {
            case (true, true):
                return "轻小说文库 · Z-Library 均已连接"
            case (true, false):
                return "轻小说文库已连接 · Z-Library 未登录"
            case (false, true):
                return "Z-Library 已连接 · 轻小说文库未登录"
            case (false, false):
                return "在此安放你的阅读日常"
            }
        }()

        return HStack(spacing: 17) {
            Text(avatarText)
                .font(.serif(28))
                .foregroundStyle(.tint)
                .frame(width: 60, height: 60)
                .background(Color.accentColor.opacity(0.11), in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5)
                }
            VStack(alignment: .leading, spacing: 7) {
                Text(displayTitle)
                    .font(.serif(22, medium: true))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Label(statusSubtitle, systemImage: (service.authenticated || zlibService.authenticated) ? "checkmark.circle" : "book")
                    .font(.serif(12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }
}

private struct SettingsLine: View {
    let title: String
    let icon: String
    var value: String = ""
    var arrow = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 23)
            Text(title)
                .font(.serif(15))
                .foregroundStyle(Color.ink)
            Spacer(minLength: 8)
            if !value.isEmpty {
                Text(value)
                    .font(.serif(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if arrow {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 17)
        .frame(minHeight: 56)
    }
}

struct WenkuAccountSettingsView: View {
    @Environment(WenkuService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var login = false
    @State private var logout = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ArchiveHeading(title: "文库账号", subtitle: "WENKU8 / SESSION")

                VStack(alignment: .leading, spacing: 12) {
                    LuoyeSectionHeader(title: "账号状态")
                    LuoyePanel {
                        SettingsLine(
                            title: "当前账号",
                            icon: "person",
                            value: service.authenticated ? (service.username.isEmpty ? "文库读者" : service.username) : "未登录"
                        )
                        LuoyePanelDivider()
                        SettingsLine(
                            title: "连接状态",
                            icon: service.authenticated ? "checkmark.circle" : "exclamationmark.circle",
                            value: service.authenticated ? "已登录" : "需要登录"
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    if service.authenticated {
                        Button {
                            logout = true
                        } label: {
                            Text("退出轻小说文库账号")
                                .font(.serif(15, medium: true))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .disabled(service.checking)
                    } else {
                        Button {
                            login = true
                        } label: {
                            Text("登录轻小说文库")
                                .font(.serif(15, medium: true))
                                .foregroundStyle(Color.ink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }

                    Text("退出后清除本机登录会话。官网书架按账号隔离保存；本地原书和阅读记录独立保留。")
                        .font(.serif(12))
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .luoyeContentMargins(top: 16)
        }
        .background(Color.paper)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .navigationTitle("文库账号设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .sheet(isPresented: $login) { WenkuLoginView() }
        .confirmationDialog("退出轻小说文库账号？", isPresented: $logout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { Task { await service.logout(); dismiss() } }
        }
    }
}

struct ZLibAccountSettingsView: View {
    @Environment(ZLibService.self) private var service
    @Environment(ZLibAccountStore.self) private var accountStore
    @Environment(\.dismiss) private var dismiss
    @State private var login = false
    @State private var logout = false
    @State private var verifying = false

    private var activeQuota: ZLibQuota? {
        service.quota ?? accountStore.quota
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ArchiveHeading(title: "Z-Library 账号", subtitle: "Z-LIBRARY / SESSION")

                VStack(alignment: .leading, spacing: 12) {
                    LuoyeSectionHeader(title: "账号与额度")
                    LuoyePanel {
                        SettingsLine(
                            title: "当前账号",
                            icon: "person",
                            value: service.authenticated ? (service.username.isEmpty ? "Z-Library 读者" : service.username) : "未登录"
                        )
                        LuoyePanelDivider()
                        SettingsLine(
                            title: "连接状态",
                            icon: service.authenticated ? "checkmark.circle" : "exclamationmark.circle",
                            value: service.authenticated ? "已登录" : "需要登录"
                        )
                        LuoyePanelDivider()
                        SettingsLine(
                            title: "今日下载额度",
                            icon: "arrow.down.circle",
                            value: activeQuota?.summaryText ?? (service.authenticated ? "同步后显示" : "未登录")
                        )
                        if let resetHint = activeQuota?.resetHint, !resetHint.isEmpty {
                            LuoyePanelDivider()
                            SettingsLine(
                                title: "额度重置提示",
                                icon: "clock",
                                value: resetHint
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    LuoyeSectionHeader(title: "同步与安全验证")
                    LuoyePanel {
                        Button {
                            Task {
                                await service.refreshSession()
                                if service.authenticated {
                                    await accountStore.sync(using: service)
                                }
                            }
                        } label: {
                            SettingsLine(
                                title: "刷新登录状态与额度",
                                icon: "arrow.triangle.2.circlepath",
                                value: accountStore.syncing ? "同步中" : "",
                                arrow: true
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(service.checking || accountStore.syncing)

                        LuoyePanelDivider()

                        Button {
                            verifying = true
                        } label: {
                            SettingsLine(
                                title: "打开网站安全验证页",
                                icon: "shield.lefthalf.filled",
                                arrow: true
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    if service.authenticated {
                        Button {
                            logout = true
                        } label: {
                            Text("退出 Z-Library 账号")
                                .font(.serif(15, medium: true))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .disabled(service.checking)
                    } else {
                        Button {
                            login = true
                        } label: {
                            Text("登录 Z-Library 账号")
                                .font(.serif(15, medium: true))
                                .foregroundStyle(Color.ink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }

                    Text("退出或切换账号后，当前账号的收藏书库、个人书单和下载历史将自动隔离，不会混入其他账号的数据；已导入本地书斋的原书与阅读进度独立保留。")
                        .font(.serif(12))
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .luoyeContentMargins(top: 16)
        }
        .background(Color.paper)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .navigationTitle("Z-Library 账号")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .sheet(isPresented: $login) { ZLibLoginView() }
        .sheet(isPresented: $verifying) { ZLibVerificationView() }
        .confirmationDialog("退出 Z-Library 账号？", isPresented: $logout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                Task {
                    await service.logout()
                    accountStore.activate(nil)
                    dismiss()
                }
            }
        }
    }
}

struct ZLibCloudLibraryView: View {
    var initialTab = "favorites"
    @Environment(ZLibService.self) private var service
    @Environment(ZLibAccountStore.self) private var accountStore
    @State private var tab = "favorites"
    @State private var login = false
    @State private var verifying = false

    private var activeQuota: ZLibQuota? {
        service.quota ?? accountStore.quota
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ArchiveHeading(title: "Z-Library 书库", subtitle: "Z-LIBRARY / CLOUD LIBRARY")

                LuoyeSegmentBar(
                    items: [
                        .init(value: "favorites", title: "收藏书库", badge: "\(accountStore.favorites.count)"),
                        .init(value: "downloads", title: "下载历史", badge: "\(accountStore.downloads.count)"),
                        .init(value: "booklists", title: "个人书单", badge: "\(accountStore.booklists.count)")
                    ],
                    selection: $tab
                )

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activeQuota?.summaryText ?? (service.authenticated ? "点击右侧同步获取最新额度" : "登录后查看今日下载额度"))
                            .font(.serif(13, medium: true))
                            .foregroundStyle(Color.ink)
                        if let resetHint = activeQuota?.resetHint, !resetHint.isEmpty {
                            Text(resetHint)
                                .font(.serif(11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if accountStore.syncing {
                        ProgressView()
                    } else {
                        Button {
                            Task { await accountStore.sync(using: service) }
                        } label: {
                            Text("同步")
                                .font(.serif(12, medium: true))
                                .foregroundStyle(Color.ink)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.20), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!service.authenticated)
                    }
                }
                .padding(15)
                .background(Color.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.ink.opacity(0.06), lineWidth: 0.5)
                }

                if let error = accountStore.error {
                    ZLibStatusView(
                        message: error,
                        loading: accountStore.syncing,
                        login: !service.authenticated,
                        onLogin: { login = true },
                        onRetry: { Task { await accountStore.sync(using: service) } },
                        onChallenge: { verifying = true }
                    )
                }

                if !service.authenticated {
                    LuoyeEmptyState(
                        icon: "books.vertical",
                        title: "登录后查看 Z-Library 账号书库",
                        message: "登录后可同步收藏书目、下载历史、个人书单及每日额度。",
                        actionTitle: "登录 Z-Library",
                        action: { login = true }
                    )
                } else {
                    switch tab {
                    case "downloads":
                        if !accountStore.syncing && accountStore.downloads.isEmpty && accountStore.error == nil {
                            LuoyeEmptyState(
                                icon: "arrow.down.circle",
                                title: "暂无下载记录",
                                message: "在 Z-Library 下载过的书籍会记录在这里。"
                            )
                        } else {
                            ZLibBookGrid(books: accountStore.downloads)
                        }
                    case "booklists":
                        if !accountStore.syncing && accountStore.booklists.isEmpty && accountStore.error == nil {
                            LuoyeEmptyState(
                                icon: "list.bullet.rectangle",
                                title: "暂无个人书单",
                                message: "你在 Z-Library 创建或收藏的书单会显示在这里。"
                            )
                        } else {
                            ZLibBooklistStack(booklists: accountStore.booklists)
                        }
                    default:
                        if !accountStore.syncing && accountStore.favorites.isEmpty && accountStore.error == nil {
                            LuoyeEmptyState(
                                icon: "bookmark",
                                title: "收藏书库尚空",
                                message: "在书籍详情页点击收藏，或在官网保存的书籍会同步到这里；点击书籍可按需下载正文。"
                            )
                        } else {
                            ZLibBookGrid(books: accountStore.favorites)
                        }
                    }
                }
            }
            .luoyeContentMargins(top: 16)
        }
        .background(Color.paper)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .navigationTitle("Z-Library 书库")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ZLibBook.self) { ZLibDetailView(book: $0) }
        .navigationDestination(for: ZLibBooklist.self) { ZLibBooklistDetailView(booklist: $0) }
        .task {
            tab = initialTab
            if service.authenticated && accountStore.syncedAt == nil {
                await accountStore.sync(using: service)
            }
        }
        .refreshable {
            await accountStore.sync(using: service)
        }
        .sheet(isPresented: $login) { ZLibLoginView() }
        .sheet(isPresented: $verifying) { ZLibVerificationView() }
    }
}

struct CacheSettingsView: View {
    @Environment(WenkuService.self) private var service
    @Environment(ZLibService.self) private var zlibService
    @State private var bytes = 0
    @State private var clearing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ArchiveHeading(title: "缓存管理", subtitle: "STORAGE / 300 MB BUDGET")

                VStack(alignment: .leading, spacing: 12) {
                    LuoyeSectionHeader(title: "可淘汰缓存占用")
                    LuoyePanel {
                        SettingsLine(
                            title: "已用缓存",
                            icon: "internaldrive",
                            value: String(format: "%.1f MB", Double(bytes) / 1_000_000)
                        )
                        LuoyePanelDivider()
                        SettingsLine(
                            title: "最大缓存预算",
                            icon: "gauge.with.dots.needle.67percent",
                            value: "300 MB"
                        )
                        LuoyePanelDivider(leadingInset: 17)
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: min(Double(bytes) / 300_000_000, 1))
                                .tint(.accentColor)
                            Text("全部书源共用 300 MB 可淘汰缓存预算，达到上限后自动清理最久未使用的缓存。用户保存在书斋里的原书、书签和阅读进度独立保存，不计入缓存。")
                                .font(.serif(12))
                                .lineSpacing(3)
                                .foregroundStyle(.secondary)
                        }
                        .padding(17)
                    }
                }

                Button {
                    clearing = true
                    Task {
                        service.clearResponseMemory()
                        zlibService.clearResponseMemory()
                        WenkuRemoteImage.clearMemory()
                        await FanhuaCache.shared.clear()
                        await service.clearPageCache()
                        await zlibService.clearPageCache()
                        bytes = await FanhuaCache.shared.byteCount()
                        clearing = false
                    }
                } label: {
                    Text(clearing ? "正在清理缓存…" : "立即清理可淘汰缓存")
                        .font(.serif(15, medium: true))
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor.opacity(0.20), in: RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 0.75)
                        }
                }
                .buttonStyle(.plain)
                .disabled(clearing)
            }
            .luoyeContentMargins(top: 16)
        }
        .background(Color.paper)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .navigationTitle("缓存管理")
        .navigationBarTitleDisplayMode(.inline)
        .task { bytes = await FanhuaCache.shared.byteCount() }
    }
}

struct BrowsingHistoryView: View {
    @Environment(BrowsingHistoryStore.self) private var history
    @State private var sourceFilter = "all"
    @State private var clear = false

    private var filteredEntries: [BrowsingEntry] {
        switch sourceFilter {
        case BookSource.wenku8.rawValue:
            return history.entries.filter { $0.source == .wenku8 }
        case BookSource.zlib.rawValue:
            return history.entries.filter { $0.source == .zlib }
        case BookSource.tomato.rawValue:
            return history.entries.filter { $0.source == .tomato }
        default:
            return history.entries
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .bottom) {
                        ArchiveHeading(
                            title: "历史",
                            subtitle: "03 / FOOTPRINTS · \(history.entries.count) BOOKS"
                        )
                        if !history.entries.isEmpty {
                            Button {
                                clear = true
                            } label: {
                                Text("清空")
                                    .font(.serif(12, medium: true))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Color.ink.opacity(0.045), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !history.entries.isEmpty {
                        LuoyeSegmentBar(
                            items: [
                                .init(value: "all", title: "全部", badge: "\(history.entries.count)"),
                                .init(value: BookSource.wenku8.rawValue, title: "文库", badge: "\(history.entries.filter { $0.source == .wenku8 }.count)"),
                                .init(value: BookSource.zlib.rawValue, title: "Z-Lib", badge: "\(history.entries.filter { $0.source == .zlib }.count)"),
                                .init(value: BookSource.tomato.rawValue, title: "番茄", badge: "\(history.entries.filter { $0.source == .tomato }.count)")
                            ],
                            selection: $sourceFilter
                        )
                    }

                    if filteredEntries.isEmpty {
                        LuoyeEmptyState(
                            icon: "clock",
                            title: history.entries.isEmpty ? "还没有浏览足迹" : "该书源下暂无浏览记录",
                            message: "打开书籍详情后，会在这里按时间顺序留下记录，并自动去重。"
                        )
                        .padding(.top, 24)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(filteredEntries) { entry in
                                Group {
                                    if let tomatoBook = entry.tomatoBook {
                                        NavigationLink(value: tomatoBook) { historyCard(entry: entry) }.buttonStyle(.plain)
                                    } else if let zlibBook = entry.zlibBook {
                                        NavigationLink(value: zlibBook) {
                                            historyCard(entry: entry)
                                        }
                                        .buttonStyle(.plain)
                                    } else if let wenkuBook = entry.wenkuBook {
                                        NavigationLink(value: wenkuBook) {
                                            historyCard(entry: entry)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .contextMenu {
                                    Button("删除这条记录", systemImage: "trash", role: .destructive) {
                                        history.remove(entry.id)
                                    }
                                }
                            }
                        }

                        Text("统一记录轻小说文库、Z-Library 与番茄小说浏览足迹，按最近浏览排序并自动去重，保留最近 200 本书。")
                            .font(.serif(11))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.top, 4)
                    }
                }
                .luoyeContentMargins()
            }
            .background(Color.paper)
            .scrollEdgeEffectHidden(true, for: .bottom)
            .toolbarBackground(.hidden, for: .tabBar)
            .luoyeRootSurface()
            .navigationDestination(for: TomatoBook.self) { TomatoDetailView(book: $0) }
            .navigationDestination(for: WenkuBook.self) { WenkuDetailView(book: $0) }
            .navigationDestination(for: ZLibBook.self) { ZLibDetailView(book: $0) }
            .confirmationDialog("清空所有浏览历史？", isPresented: $clear, titleVisibility: .visible) {
                Button("清空浏览历史", role: .destructive) { history.clear() }
            }
        }
    }

    private func historyCard(entry: BrowsingEntry) -> some View {
        HStack(spacing: 14) {
            LuoyeRemoteCover(
                title: entry.title,
                coverURLString: entry.cover
            )
            .frame(width: 48, height: 68)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(entry.source.badgeText)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(Color.ink.opacity(0.8))
                    Text(entry.title)
                        .font(.serif(15, medium: true))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                }
                Text(entry.author.isEmpty ? entry.source.title : entry.author)
                    .font(.serif(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(entry.viewedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 6)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    history.remove(entry.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                    .background(Color.ink.opacity(0.04), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除记录")
        }
        .padding(13)
        .background(Color.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.ink.opacity(0.06), lineWidth: 0.5)
        }
    }
}

struct WenkuCloudShelfView: View {
    @Environment(WenkuService.self) private var service
    @Environment(WebsiteShelfStore.self) private var shelf
    @State private var login = false
    @State private var verifying = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ArchiveHeading(title: "文库官网书架", subtitle: "WENKU8 / CLOUD BOOKCASE")

                HStack {
                    Text("共 \(shelf.books.count) 本收藏书目")
                        .font(.serif(13, medium: true))
                        .foregroundStyle(Color.ink)
                    Spacer()
                    if shelf.syncing {
                        ProgressView()
                    } else {
                        Button {
                            Task { await shelf.sync(using: service) }
                        } label: {
                            Text("同步")
                                .font(.serif(12, medium: true))
                                .foregroundStyle(Color.ink)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.20), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!service.authenticated)
                    }
                }
                .padding(15)
                .background(Color.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.ink.opacity(0.06), lineWidth: 0.5)
                }

                if let error = shelf.error {
                    WenkuStatusView(
                        message: error,
                        loading: shelf.syncing,
                        login: !service.authenticated,
                        onLogin: { login = true },
                        onRetry: { Task { await shelf.sync(using: service) } },
                        onChallenge: { verifying = true }
                    )
                }
                if !service.authenticated {
                    LuoyeEmptyState(
                        icon: "cloud",
                        title: "登录后同步文库官网书架",
                        message: "将你在轻小说文库网站收藏的书目同步至此。",
                        actionTitle: "登录文库",
                        action: { login = true }
                    )
                } else if !shelf.syncing && shelf.books.isEmpty && shelf.error == nil {
                    LuoyeEmptyState(
                        icon: "cloud",
                        title: "官网书架尚空",
                        message: "在文库官网收藏的书籍会同步到这里。"
                    )
                } else {
                    WenkuBookGrid(books: shelf.books)
                }
            }
            .luoyeContentMargins(top: 16)
        }
        .background(Color.paper)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .navigationTitle("文库官网书架")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: WenkuBook.self) { WenkuDetailView(book: $0) }
        .task {
            if service.authenticated && shelf.syncedAt == nil {
                await shelf.sync(using: service)
            }
        }
        .refreshable { await shelf.sync(using: service) }
        .sheet(isPresented: $login) { WenkuLoginView() }
        .sheet(isPresented: $verifying) { WenkuVerificationView() }
    }
}
