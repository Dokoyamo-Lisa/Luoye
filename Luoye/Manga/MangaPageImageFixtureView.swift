import SwiftUI

/// Only presented by an explicit debug launch flag; owns no user library records.
struct MangaImageVerificationHost: ViewModifier {
    #if DEBUG
    @State private var presented = false
    func body(content: Content) -> some View {
        content.sheet(isPresented: $presented) { MangaPageImageFixtureView() }
            .task { if ProcessInfo.processInfo.arguments.contains("--show-manga-image-fixture") { presented = true } }
    }
    #else
    func body(content: Content) -> some View { content }
    #endif
}
#if DEBUG
private struct MangaPageImageFixtureView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var directory: URL?
    @State private var selected = "a"
    @State private var repaired = false
    @State private var failure: String?
    private let revision = UUID()
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack {
                    Button("有效页 A") { selected = "a" }
                    Button("损坏页") { selected = "bad" }
                    Button("有效页 B") { selected = "b" }
                }.font(.serif(13)).padding(.top, 12)
                Button(repaired ? "文件已修复，请点图片重试" : "修复损坏文件") {
                    guard let directory else { return }
                    do { try image("B", color: .blue).write(to: directory.appending(path: "bad/page.png"), options: .atomic); repaired = true }
                    catch { failure = error.localizedDescription }
                }.font(.serif(12))
                if let failure { Text(failure).font(.serif(12)) }
                if let directory {
                    ScrollView {
                        MangaImagePage(resource: .local(directory.appending(path: selected), "folder", 0, revision: revision), fitWidth: true) {}
                    }
                } else { ProgressView() }
            }.background(Color.paper).navigationTitle("漫画图片切换验证").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .task {
            do {
                let root = FileManager.default.temporaryDirectory.appending(path: "manga-image-ui-fixture-" + UUID().uuidString)
                for name in ["a", "bad", "b"] { try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true) }
                try image("A", color: .systemRed).write(to: root.appending(path: "a/page.png"))
                try image("B", color: .systemBlue).write(to: root.appending(path: "b/page.png"))
                try Data("HTTP 200 invalid image fixture".utf8).write(to: root.appending(path: "bad/page.png"))
                directory = root
            } catch { failure = error.localizedDescription }
        }
        .onDisappear { if let directory { try? FileManager.default.removeItem(at: directory) } }
    }
    private func image(_ text: String, color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600), format: format).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
            (text as NSString).draw(at: CGPoint(x: 145, y: 230), withAttributes: [.font: UIFont.systemFont(ofSize: 140, weight: .bold), .foregroundColor: UIColor.white])
        }.pngData()!
    }
}
#endif
