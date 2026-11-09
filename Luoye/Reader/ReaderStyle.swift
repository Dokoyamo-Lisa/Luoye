import SwiftUI
import UIKit
import CoreText

/// 阅读页的配色：跟随系统、纸白、夜读。
enum ReaderTheme: String, CaseIterable, Identifiable {
    case system, paper, night

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "跟随系统"
        case .paper: "纸白"
        case .night: "夜读"
        }
    }

    /// 实际用浅色还是深色。
    func scheme(system: ColorScheme) -> ColorScheme {
        switch self {
        case .system: system
        case .paper: .light
        case .night: .dark
        }
    }
}

/// 行距三档。
enum ReaderLineHeight: String, CaseIterable, Identifiable {
    case compact, comfortable, airy

    var id: String { rawValue }

    /// 行高是字号的几倍
    var multiplier: CGFloat {
        switch self {
        case .compact: 1.6
        case .comfortable: 1.85
        case .airy: 2.1
        }
    }

    var label: String {
        switch self {
        case .compact: "紧凑"
        case .comfortable: "适中"
        case .airy: "舒展"
        }
    }
}

/// 排版一页所需的全部样式。任何一项变了都要重新分页。
struct ReaderStyle: Equatable {
    var fontSize: CGFloat
    var lineHeight: CGFloat
    var scheme: ColorScheme
    var bodyFontName: String? = nil
    var bodyFontURL: URL? = nil
    /// Imported books may contain a byline; extracted website paragraphs are always body text.
    var recognizesByline = true
    private static let embeddedFonts = NSCache<NSString, UIFont>()

    static let fontSizes: ClosedRange<Double> = 14 ... 28

    var background: UIColor {
        scheme == .dark ? UIColor(red: 0.110, green: 0.102, blue: 0.106, alpha: 1)
            : UIColor(red: 0.984, green: 0.969, blue: 0.961, alpha: 1)
    }

    var text: UIColor {
        scheme == .dark ? UIColor(red: 0.80, green: 0.78, blue: 0.76, alpha: 1)
            : UIColor(red: 0.20, green: 0.176, blue: 0.184, alpha: 1)
    }

    var secondary: UIColor {
        scheme == .dark ? UIColor(red: 0.50, green: 0.48, blue: 0.47, alpha: 1)
            : UIColor(red: 0.58, green: 0.55, blue: 0.55, alpha: 1)
    }

    private var bodyFont: UIFont {
        if let bodyFontURL {
            let key = (bodyFontURL.absoluteString + "|" + String(describing: fontSize)) as NSString
            if let cached = Self.embeddedFonts.object(forKey: key) { return cached }
            if let provider = CGDataProvider(url: bodyFontURL as CFURL), let graphicsFont = CGFont(provider) {
                let embedded = CTFontCreateWithGraphicsFont(graphicsFont, fontSize, nil, nil) as UIFont
                Self.embeddedFonts.setObject(embedded, forKey: key, cost: 1)
                Self.embeddedFonts.countLimit = 32
                return embedded
            }
        }
        return UIFont(name: bodyFontName ?? "NotoSerifSC-Regular", size: fontSize) ?? .systemFont(ofSize: fontSize)
    }

    /// 每行占的高度：「字号 × 行距倍数」，但不小于字体本身的行高。
    var linePitch: CGFloat {
        max(fontSize * lineHeight, bodyFont.lineHeight).rounded(.up)
    }

    /// 把一章排成带样式的文字。所有内容都落在「行高」的网格上：
    /// 标题占两行、居中（有署名时署名紧跟其下）；作者等短署名居中、淡色；正文首行缩进两字、两端对齐，段与段之间不额外留白。
    func attributedText(for chapter: Chapter, images: ((String) -> Data?)? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = bodyFont
        let pitch = linePitch

        func fixedLines(_ rows: CGFloat, alignment: NSTextAlignment, spacingAfter: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            style.minimumLineHeight = pitch * rows
            style.maximumLineHeight = pitch * rows
            style.paragraphSpacing = spacingAfter
            return style
        }

        var paragraphs = chapter.paragraphs
        let byline = recognizesByline ? paragraphs.first.flatMap { Self.isByline($0) ? InlineMark.plain($0) : nil } : nil

        let heading = UIFont(name: "NotoSerifSC-Medium", size: fontSize * 1.3) ?? .boldSystemFont(ofSize: fontSize * 1.3)
        let headingAttributes: [NSAttributedString.Key: Any] = [
            .font: heading, .foregroundColor: text,
            .baselineOffset: (pitch * 2 - heading.lineHeight) / 2,
            .paragraphStyle: fixedLines(2, alignment: .center, spacingAfter: byline == nil ? pitch : 0),
        ]
        if let parts = ChapterTitle.ranges(chapter.title) {
            // 带卷名的章名：卷名一行小字在上，章名作标题。
            // 只把两者之间的第一个空白换成换行，总字数不变，存过的阅读位置和书签不会错开。
            let title = chapter.title
            let small = UIFont(name: "NotoSerifSC-Regular", size: fontSize * 0.8) ?? body
            var separator = String(title[parts.separator])
            separator.replaceSubrange(separator.startIndex ... separator.startIndex, with: "\n")
            result.append(NSAttributedString(string: String(title[parts.volume]) + separator, attributes: [
                .font: small, .foregroundColor: secondary, .kern: fontSize * 0.15,
                .paragraphStyle: fixedLines(1, alignment: .center, spacingAfter: 0),
            ]))
            result.append(NSAttributedString(string: String(title[parts.name]) + "\n", attributes: headingAttributes))
        } else {
            // 标题占两行高，字放在这两行的正中间（默认会贴着底部）；没有署名时下面空一行再接正文。
            result.append(NSAttributedString(string: chapter.title + "\n", attributes: headingAttributes))
        }

        if let first = byline {
            paragraphs.removeFirst()
            let small = UIFont(name: "NotoSerifSC-Regular", size: fontSize * 0.85) ?? body
            result.append(NSAttributedString(string: first + "\n", attributes: [
                .font: small, .foregroundColor: secondary, .kern: fontSize * 0.2,
                .paragraphStyle: fixedLines(1, alignment: .center, spacingAfter: pitch),
            ]))
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .justified
        paragraphStyle.firstLineHeadIndent = fontSize * 2
        paragraphStyle.lineSpacing = pitch - body.lineHeight
        let bodyAttributes: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: text, .paragraphStyle: paragraphStyle]

        let imageStyle = NSMutableParagraphStyle()
        imageStyle.alignment = .center
        imageStyle.paragraphSpacing = pitch * 0.5
        imageStyle.paragraphSpacingBefore = pitch * 0.5

        for (index, paragraph) in paragraphs.enumerated() {
            let newline = index < paragraphs.count - 1 ? "\n" : ""
            if paragraph.first == InlineMark.image {
                // 插图单独一段、居中；取不到图就跳过这一段。
                guard let data = images?(String(paragraph.dropFirst())), let image = Self.cachedImage(data) else { continue }
                let piece = NSMutableAttributedString(attachment: FittedImageAttachment(image: image))
                piece.append(NSAttributedString(string: newline))
                piece.addAttributes([.paragraphStyle: imageStyle, .font: body], range: NSRange(location: 0, length: piece.length))
                result.append(piece)
            } else {
                result.append(inlineText(paragraph + newline, attributes: bodyAttributes))
            }
        }
        return result
    }

    /// 段落里的注音、注释记号换成带样式的文字。
    private func inlineText(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        guard text.contains(where: { $0 == InlineMark.rubyStart || $0 == InlineMark.noteStart }) else {
            return NSAttributedString(string: text, attributes: attributes)
        }
        let result = NSMutableAttributedString()
        var plain = "", first = "", second = ""
        enum State { case text, ruby, rubyReading, note, noteText }
        var state = State.text

        func flushPlain() {
            if !plain.isEmpty { result.append(NSAttributedString(string: plain, attributes: attributes)) }
            plain = ""
        }
        for character in text {
            switch (state, character) {
            case (.text, InlineMark.rubyStart): flushPlain(); state = .ruby; first = ""; second = ""
            case (.text, InlineMark.noteStart): flushPlain(); state = .note; first = ""; second = ""
            case (.ruby, InlineMark.separator): state = .rubyReading
            case (.note, InlineMark.separator): state = .noteText
            case (.rubyReading, InlineMark.end), (.ruby, InlineMark.end):
                var ruby = attributes
                ruby[.fanhuaRuby] = second
                result.append(NSAttributedString(string: first, attributes: ruby))
                state = .text
            case (.noteText, InlineMark.end), (.note, InlineMark.end):
                // 注释标号：小一号、上标、藕粉色，点它弹出注释
                var note = attributes
                note[.font] = UIFont(name: "NotoSerifSC-Medium", size: fontSize * 0.62) ?? bodyFont
                note[.baselineOffset] = fontSize * 0.38
                note[.foregroundColor] = Self.accent
                note[.fanhuaNote] = second
                result.append(NSAttributedString(string: "\u{2009}" + first + "\u{2009}", attributes: note))
                state = .text
            case (.text, _): plain.append(character)
            case (.ruby, _), (.note, _): first.append(character)
            case (.rubyReading, _), (.noteText, _): second.append(character)
            }
        }
        flushPlain()
        return result
    }

    static let accent = UIColor(named: "AccentColor") ?? .systemPink

    private static let imageCache = NSCache<NSData, UIImage>()

    private static func cachedImage(_ data: Data) -> UIImage? {
        if let image = imageCache.object(forKey: data as NSData) { return image }
        guard let image = UIImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: data as NSData)
        return image
    }

    /// 标题下面紧跟的短行，如「陶渊明」「作者：某某」：不超过 12 个字、没有句读。
    private static func isByline(_ line: String) -> Bool {
        line.first != InlineMark.image && line.count <= 12 && !line.contains(where: { "，。！？；、…“”".contains($0) })
    }
}

/// 阅读位置：第几章，章内第几个字。按字记而不是按页，换字号后还能回到同一处。
struct ReadingPosition: Equatable {
    var chapter: Int
    var offset: Int
}

extension NSAttributedString.Key {
    /// 这段字上方要标的读音
    static let fanhuaRuby = NSAttributedString.Key("FanhuaRuby")
    /// 注释标号对应的注释全文
    static let fanhuaNote = NSAttributedString.Key("FanhuaNote")
}

/// 插图：按版面宽度等比缩小，高度不超过一页的九成；小图保持原大。
final class FittedImageAttachment: NSTextAttachment {
    init(image: UIImage) {
        super.init(data: nil, ofType: nil)
        self.image = image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func fitted(width: CGFloat, height: CGFloat) -> CGRect {
        guard let size = image?.size, size.width > 0, size.height > 0, width > 0 else { return .zero }
        let scale = min(1, width / size.width, max(height, 1) * 0.9 / size.height)
        return CGRect(x: 0, y: 0, width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        fitted(width: lineFrag.width, height: textContainer?.size.height ?? 600)
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                   position: CGPoint) -> CGRect {
        fitted(width: proposedLineFragment.width, height: min(textContainer?.size.height ?? 600, 700))
    }
}

/// 翻页方式：左右一页页翻，或上下连续滚动。
enum ReaderPageMode: String, CaseIterable, Identifiable {
    case paged, scroll

    var id: String { rawValue }

    var label: String {
        switch self {
        case .paged: "左右翻页"
        case .scroll: "上下滚动"
        }
    }
}

/// 整个 App 的外观：跟随系统、浅色、深色。在「我的 → 通用」里设置。
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// 直接设在每个窗口上。SwiftUI 的 preferredColorScheme 设过深色后再改回「不指定」，有时恢复不了。
    @MainActor func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve) {
                    window.overrideUserInterfaceStyle = interfaceStyle
                }
            }
        }
    }
}

extension EnvironmentValues {
    /// App 窗口实际的深浅色（跟随系统，或「我的」里选定的外观）。
    /// 阅读页会强制自己的配色，它里面读到的 colorScheme 已被改写；要知道「系统是什么颜色」得读这个。
    @Entry var systemColorScheme: ColorScheme = .light
}

/// 在窗口这一层读出深浅色，传给下面所有页面（包括全屏弹出的阅读页）。
struct WindowColorScheme: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.environment(\.systemColorScheme, scheme)
    }
}

/// 章名里常带着卷名，如「第一卷 来一份翻转苹果塔 国王饼的秘密」。
/// 拆成卷名和章名：正文里卷名作小字、章名作标题，目录按卷分组，页脚只写章名。
enum ChapterTitle {
    private static let number = "[0-9０-９零〇一二三四五六七八九十百千万萬两兩]+"
    /// 「第一卷」「卷三」这样的卷号
    private static let volumeMark = try! NSRegularExpression(pattern: "^(?:第\(number)[卷部集]|卷\(number))$")
    /// 第二段若已是「第三章」「序章」之类，卷名就只到卷号为止
    private static let chapterMark = try! NSRegularExpression(
        pattern: "^(?:第\(number)[章回节節话話篇幕折]|序[章言幕曲]?|楔子|引子|前言|尾声|尾聲|后记|後記|终章|終章|番外|外传|外傳|插曲|间章|間章)")

    /// 卷名、分隔空白、章名在原文里的位置；不是「卷名 + 章名」的写法返回 nil。
    static func ranges(_ title: String) -> (volume: Range<String.Index>, separator: Range<String.Index>, name: Range<String.Index>)? {
        let tokens = title.ranges(of: /\S+/)
        guard tokens.count >= 2, matches(volumeMark, String(title[tokens[0]])) else { return nil }
        // 「第一卷 来一份翻转苹果塔 国王饼的秘密」：卷号后面跟着卷名，再后面才是章名。
        let volumeTokens = tokens.count >= 3 && !matches(chapterMark, String(title[tokens[1]])) ? 2 : 1
        let volumeEnd = tokens[volumeTokens - 1].upperBound
        let nameStart = tokens[volumeTokens].lowerBound
        return (title.startIndex ..< volumeEnd, volumeEnd ..< nameStart, nameStart ..< title.endIndex)
    }

    static func parts(_ title: String) -> (volume: String?, name: String) {
        guard let ranges = ranges(title) else { return (nil, title) }
        return (String(title[ranges.volume]), String(title[ranges.name]))
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
