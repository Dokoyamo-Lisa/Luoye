import SwiftUI

struct ReaderMotionVerificationHost: ViewModifier {
    #if DEBUG
    @State private var presented = false
    func body(content: Content) -> some View {
        content.sheet(isPresented: $presented) { ReaderMotionFixtureView() }
            .task { if ProcessInfo.processInfo.arguments.contains("--show-reader-motion-fixture") { presented = true } }
    }
    #else
    func body(content: Content) -> some View { content }
    #endif
}
#if DEBUG
private struct ReaderMotionFixtureView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var manga = ProcessInfo.processInfo.arguments.contains("--motion-manga")
    @State private var fontSize = 19.0
    @State private var position = ReadingPosition(chapter: 5, offset: 0)
    @State private var page = 0
    @State private var menuTaps = 0
    private let images = [Self.image("A", .systemPink), Self.image("B", .systemBlue)]
    private let content = BookContent(chapters: (0..<9).map { Chapter(id: $0, title: "第\($0 + 1)章 稳定接续", paragraphs: ["这是第\($0 + 1)章的自写测试正文。", "滚动接入前后章节时，当前文字应该保持原位。"] ) }, image: { _ in nil })
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("阅读器", selection: $manga) { Text("小说滚动").tag(false); Text("漫画缩放").tag(true) }.pickerStyle(.segmented).padding(.horizontal, 20)
                if manga {
                    Text("第 \(page + 1) / 2 页 · 菜单触发 \(menuTaps) 次").font(.serif(12))
                    TabView(selection: $page) {
                        ForEach(0..<2) { index in MangaZoomableImage(image: images[index]) { menuTaps += 1 }.tag(index) }
                    }.tabViewStyle(.page(indexDisplayMode: .never))
                } else {
                    HStack {
                        Button("第六章") { position = ReadingPosition(chapter: 5, offset: 0) }
                        Spacer()
                        Button("字号减小") { fontSize = max(14, fontSize - 1) }
                        Text("\(Int(fontSize))").monospacedDigit()
                        Button("字号增大") { fontSize = min(28, fontSize + 1) }
                    }.font(.serif(13)).padding(.horizontal, 20)
                    GeometryReader { viewport in
                        ScrollReader(content: content, style: ReaderStyle(fontSize: fontSize, lineHeight: 1.85, scheme: .light, recognizesByline: false), size: viewport.size,
                                     insets: UIEdgeInsets(top: 30, left: 28, bottom: 30, right: 28), position: $position, speed: 0, onTap: {}, onReachEnd: {})
                    }
                }
            }.background(Color.paper).navigationTitle("阅读动效验证").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.preferredColorScheme(.light)

    }
    private static func image(_ text: String, _ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 900), format: format).image { context in
            color.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
            for x in stride(from: 0, to: 600, by: 100) { for y in stride(from: 0, to: 900, by: 100) {
                UIColor.white.withAlphaComponent((x / 100 + y / 100).isMultiple(of: 2) ? 0.15 : 0.03).setFill()
                context.cgContext.fill(CGRect(x: x, y: y, width: 100, height: 100))
            } }
            (text as NSString).draw(at: CGPoint(x: 205, y: 320), withAttributes: [.font: UIFont.systemFont(ofSize: 200, weight: .bold), .foregroundColor: UIColor.white])
        }
    }
}
#endif
