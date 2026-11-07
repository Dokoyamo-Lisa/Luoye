import CoreText
import SwiftData
import SwiftUI

@main
struct LuoyeApp: App {
    @AppStorage("app.appearance") private var appearance = AppAppearance.system

    init() {
        AppFonts.register()
        let tabBar = UITabBarAppearance()
        tabBar.configureWithTransparentBackground()
        tabBar.backgroundColor = .clear
        tabBar.shadowColor = .clear
        UITabBar.appearance().standardAppearance = tabBar
        UITabBar.appearance().scrollEdgeAppearance = tabBar
    }

    var body: some Scene {
        WindowGroup {
            FanhuaRootView()
                .tint(Color("AccentColor"))
                .modifier(WindowColorScheme())
                .eyeCareFilter()
                .onChange(of: appearance, initial: true) { appearance.apply() }
        }
        .modelContainer(for: [Book.self, Bookmark.self])
    }
}

/// App 自带的字体：思源宋体（Noto Serif SC，SIL OFL 1.1）。
enum AppFonts {
    static func register() {
        for name in ["NotoSerifSC-Regular", "NotoSerifSC-Medium"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "otf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        // 导航栏标题也用宋体和墨色，和正文一致。
        let navigationBar = UINavigationBar.appearance()
        let ink = UIColor(resource: .ink)
        if let large = UIFont(name: "NotoSerifSC-Medium", size: 30) {
            navigationBar.largeTitleTextAttributes = [.font: large, .foregroundColor: ink]
        }
        if let inline = UIFont(name: "NotoSerifSC-Medium", size: 17) {
            navigationBar.titleTextAttributes = [.font: inline, .foregroundColor: ink]
        }
    }
}

extension Font {
    /// 思源宋体，跟随系统字号缩放。
    static func serif(_ size: CGFloat, medium: Bool = false) -> Font {
        .custom(medium ? "NotoSerifSC-Medium" : "NotoSerifSC-Regular", size: size)
    }
}
