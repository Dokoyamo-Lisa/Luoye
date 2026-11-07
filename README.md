# 落叶 Luoye

落叶是一款使用 SwiftUI 开发的 iOS 阅读器，支持本地电子书、漫画和在线书源。

> **漫画后端来源**
>
> 落叶的在线漫画源脚本后端由 [Venera（venera-app/venera）](https://github.com/venera-app/venera) 整合而来。落叶随包提供 Venera 的 JavaScript API，通过原生 Swift / JavaScriptCore 桥接运行漫画源脚本。默认漫画源目录来自 [venera-app/venera-configs](https://github.com/venera-app/venera-configs)，对应脚本在运行时下载。

## 功能

- 导入 EPUB、TXT、MOBI、AZW3、FB2 和 Markdown，支持目录、书签、翻页、滚动和自动阅读。
- 阅读本地 CBZ、ZIP、PDF 和图片文件夹，或使用 MangaDex 和兼容 Venera 的在线漫画源。
- 管理漫画收藏、离线下载和阅读进度。应用也提供轻小说文库、Z-Library 和番茄小说入口。

## 从源码运行

需要支持 iOS 26.0 或更新版本的 Xcode。仓库中的 `Luoye.xcodeproj` 已包含共享的 `Luoye` scheme，Xcode 会通过 Swift Package Manager 解析 SwiftSoup 依赖。

1. 克隆本仓库，打开 `Luoye.xcodeproj`。
2. 选择 `Luoye` scheme 和 iOS 26.0 或更新版本的模拟器，运行项目。
3. 真机调试时，在 `Signing & Capabilities` 中选择自己的开发团队，并按需设置可用的 Bundle Identifier。

## 开源许可

落叶整合版以 [GNU GPL v3.0](LICENSE) 发布。继承自繁花的代码保留[原版权与许可声明](licenses/Fanhua-MIT.txt)。以下组件保留各自的许可与署名。

- Venera JavaScript API 取自上游的 [`assets/init.js`](https://github.com/venera-app/venera/blob/a0eba914f4c2a84ac1bc925adec2baabe920b9be/assets/init.js)，随落叶以 [`VeneraAPI.js`](Luoye/Manga/Scripting/VeneraAPI.js) 提供。落叶为 iOS 编写了桥接和漫画源适配层，整合版于 2026-11-07 发布。[Venera GPL-3.0 许可证](Luoye/Manga/Scripting/Venera-LICENSE.txt)
- 番茄小说的下载器客户端对接 [Tomato-Novel-Downloader](https://github.com/zhongbai2333/Tomato-Novel-Downloader) 的 Web UI 接口。[上游许可](Luoye/Online/Tomato/TomatoDownloader-LICENSE.txt)
- [Noto Serif CJK](https://github.com/notofonts/noto-cjk) 简体中文字体采用 [SIL Open Font License 1.1](Luoye/Fonts/OFL-NotoSerifSC.txt)。
- [SwiftSoup](https://github.com/scinfu/SwiftSoup) 通过 Swift Package Manager 引入。[上游许可](https://github.com/scinfu/SwiftSoup/blob/2.14.3/LICENSE)
