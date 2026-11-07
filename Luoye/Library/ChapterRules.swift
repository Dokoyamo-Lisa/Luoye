import Foundation

/// TXT 怎样认出章节标题。默认自动识别常见写法；也可以在设置里填一条自己的正则表达式。
enum ChapterRules {
    static let customPatternKey = "txt.customChapterPattern"

    /// 设置里填的规则；空的或写错了就是 nil，回到自动识别。
    static var customPattern: NSRegularExpression? {
        guard let pattern = UserDefaults.standard.string(forKey: customPatternKey)?.trimmed else { return nil }
        return try? NSRegularExpression(pattern: "^(?:\(pattern))$")
    }

    private static let number = "[0-9０-９零〇一二三四五六七八九十百千万萬两兩]+"

    /// 自动识别的几种写法，任何一种整行匹配就算标题。
    static let builtIn: [NSRegularExpression] = [
        // 第十二章、第3回、第一卷、正文 第一章 某某
        "(?:正文\\s*)?第\(number)[章回节節卷集部篇幕话話折][\\s:：·、.\\-—]*.{0,30}",
        // 卷一 某某
        "卷\(number)(?:[\\s:：·、.\\-—].{0,30})?",
        // 序章、楔子、尾声、番外 某某……
        "(?:序[章言幕曲]?|楔子|引子|引言|前言|尾声|尾聲|后记|後記|终章|終章|最终话|番外|外传|外傳|附录|附錄|作者的话|完本感言)(?:[\\s:：·、.\\-—].{0,30})?",
        // Chapter 12 / CHAPTER XII / Ch. 3
        "(?:Chapter|CHAPTER|Ch\\.?)\\s*(?:[0-9]+|[IVXLCDM]+)\\b.{0,40}",
        // 【第一章 某某】、【楔子】
        "【[^】]{1,30}】",
    ].map { try! NSRegularExpression(pattern: "^(?:\($0))$") }

    /// 这一行是不是标题。句末带句号、问号的通常是正文，不算。
    static func isHeading(_ line: String, custom: NSRegularExpression?) -> Bool {
        guard line.count <= 40 else { return false }
        let range = NSRange(line.startIndex..., in: line)
        if let custom { return custom.firstMatch(in: line, range: range) != nil }
        if let last = line.last, "。！？，；…".contains(last) { return false }
        return builtIn.contains { $0.firstMatch(in: line, range: range) != nil }
    }
}
