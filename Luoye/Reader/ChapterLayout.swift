import UIKit

/// 把一章文字切成一页一页：每页一个固定大小的文字框，排满了就换下一个。
final class ChapterLayout {
    let manager = NSLayoutManager()
    let storage: NSTextStorage
    private(set) var containers: [NSTextContainer] = []

    init(text: NSAttributedString, pageSize: CGSize) {
        storage = NSTextStorage(attributedString: text)
        storage.addLayoutManager(manager)
        while true {
            let container = NSTextContainer(size: pageSize)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            containers.append(container)
            let range = manager.glyphRange(for: container)
            // 排到最后一个字，或者这一页一个字都放不下（防止死循环）就停。
            if NSMaxRange(range) >= manager.numberOfGlyphs || range.length == 0 { break }
        }
    }

    var pageCount: Int { containers.count }

    /// 第几页对应章内哪些字。
    func characterRange(ofPage page: Int) -> NSRange {
        manager.characterRange(forGlyphRange: manager.glyphRange(for: containers[page]), actualGlyphRange: nil)
    }

    /// 包含某个字的那一页。
    func page(containing offset: Int) -> Int {
        for page in 0 ..< pageCount where NSMaxRange(characterRange(ofPage: page)) > offset {
            return page
        }
        return pageCount - 1
    }
}

/// 画出某一章的某一页。
final class PageTextView: UIView {
    private let layout: ChapterLayout
    private let page: Int

    init(layout: ChapterLayout, page: Int) {
        self.layout = layout
        self.page = page
        super.init(frame: .zero)
        isOpaque = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        let glyphs = layout.manager.glyphRange(for: layout.containers[page])
        layout.manager.drawBackground(forGlyphRange: glyphs, at: .zero)
        layout.manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
        drawRuby(in: glyphs)
    }

    /// 注音：读音用小号字写在汉字正上方，落在上一行留出的行距里。
    private func drawRuby(in glyphs: NSRange) {
        let manager = layout.manager
        let container = layout.containers[page]
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        layout.storage.enumerateAttribute(.fanhuaRuby, in: characters) { value, range, _ in
            guard let reading = value as? String, !reading.isEmpty else { return }
            let baseFont = layout.storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
            let color = (layout.storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor) ?? .label
            let size = (baseFont?.pointSize ?? 17) * 0.45
            let font = UIFont(name: "NotoSerifSC-Regular", size: size) ?? .systemFont(ofSize: size)
            let glyphRange = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)

            // 跨行时每一行各写对应的一份读音；同一行就整段居中。
            var rects: [CGRect] = []
            manager.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                            in: container) { rect, _ in rects.append(rect) }
            let parts = Self.split(reading, into: rects.count)
            for (rect, part) in zip(rects, parts) {
                let attributed = NSAttributedString(string: part, attributes: [.font: font, .foregroundColor: color.withAlphaComponent(0.75)])
                let width = attributed.size().width
                // 读音比汉字宽时略微收紧字距，免得盖到旁边的字。
                let origin = CGPoint(x: rect.midX - width / 2, y: rect.minY - font.lineHeight * 0.85)
                attributed.draw(at: origin)
            }
        }
    }

    private static func split(_ text: String, into count: Int) -> [String] {
        guard count > 1 else { return [text] }
        let characters = Array(text)
        let size = Int((Double(characters.count) / Double(count)).rounded(.up))
        return stride(from: 0, to: characters.count, by: max(size, 1)).map { String(characters[$0 ..< min($0 + size, characters.count)]) }
    }

    /// 点中的位置若是注释标号，返回注释全文。
    func note(at point: CGPoint) -> String? {
        let manager = layout.manager
        let container = layout.containers[page]
        let glyphs = manager.glyphRange(for: container)
        guard glyphs.length > 0 else { return nil }
        let index = manager.glyphIndex(for: point, in: container)
        guard NSLocationInRange(index, glyphs) else { return nil }
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: index, length: 1), in: container).insetBy(dx: -12, dy: -12)
        guard rect.contains(point) else { return nil }
        let character = manager.characterIndexForGlyph(at: index)
        return layout.storage.attribute(.fanhuaNote, at: character, effectiveRange: nil) as? String
    }
}
