import Foundation

/// 读 Kindle 的 MOBI / AZW / AZW3 / PRC（无 DRM）。
/// 支持不压缩和 PalmDOC 压缩；少见的 HUFF/CDIC 压缩和加密（DRM）文件会给出明确的错误。
struct MobiReader {
    enum MobiError: Error {
        case notMobi
        case drm
        case unsupportedCompression
    }

    let title: String
    let author: String
    /// 正文 HTML：MOBI 按分页符切开，AZW3 按内部文件切开
    let documents: [String]
    /// 封面的取图键，见 image(_:)
    let coverKey: String?

    private let data: Data
    private let records: [Range<Int>]
    private let firstImageRecord: Int?

    init(data: Data) throws {
        self.data = data
        guard data.count > 86, let type = String(data: data[60 ..< 68], encoding: .ascii),
              type == "BOOKMOBI" || type == "TEXtREAd"
        else { throw MobiError.notMobi }

        let count = Int(data.uint16BE(at: 76))
        let offsets = (0 ..< count).map { Int(data.uint32BE(at: 78 + $0 * 8)) } + [data.count]
        records = (0 ..< count).map { offsets[$0] ..< max(offsets[$0], offsets[$0 + 1]) }
        guard let header = records.first, header.count >= 16 else { throw MobiError.notMobi }

        let base = header.lowerBound
        let compression = data.uint16BE(at: base)
        let textLength = Int(data.uint32BE(at: base + 4))
        let textRecordCount = Int(data.uint16BE(at: base + 8))
        guard data.uint16BE(at: base + 12) == 0 else { throw MobiError.drm }

        var title = String(decoding: data[0 ..< 32].prefix { $0 != 0 }, as: UTF8.self)
        var authors: [String] = []
        var coverOffset: Int?
        var extraFlags: UInt16 = 0
        var encoding = String.Encoding.windowsCP1252
        var kf8 = false
        var firstImage: Int?

        if header.count >= 132, String(data: data[base + 16 ..< base + 20], encoding: .ascii) == "MOBI" {
            let headerLength = Int(data.uint32BE(at: base + 20))
            if data.uint32BE(at: base + 28) == 65001 { encoding = .utf8 }
            kf8 = data.uint32BE(at: base + 36) >= 8
            let imageIndex = Int(data.uint32BE(at: base + 108))
            if imageIndex > 0, imageIndex < count { firstImage = imageIndex }
            if headerLength >= 0xE4, header.count >= 0xF4 { extraFlags = data.uint16BE(at: base + 0xF2) }

            let nameOffset = Int(data.uint32BE(at: base + 84)), nameLength = Int(data.uint32BE(at: base + 88))
            if nameLength > 0, base + nameOffset + nameLength <= header.upperBound,
               let name = String(data: data[base + nameOffset ..< base + nameOffset + nameLength], encoding: encoding) {
                title = name
            }

            // EXTH：作者、书名、封面等附加信息
            let exth = base + 16 + headerLength
            if data.uint32BE(at: base + 128) & 0x40 != 0, exth + 12 <= header.upperBound,
               String(data: data[exth ..< exth + 4], encoding: .ascii) == "EXTH" {
                var cursor = exth + 12
                for _ in 0 ..< Int(data.uint32BE(at: exth + 8)) {
                    guard cursor + 8 <= header.upperBound else { break }
                    let kind = data.uint32BE(at: cursor), length = Int(data.uint32BE(at: cursor + 4))
                    guard length >= 8, cursor + length <= header.upperBound else { break }
                    let value = data[cursor + 8 ..< cursor + length]
                    switch kind {
                    case 100: if let name = String(data: value, encoding: encoding)?.trimmed { authors.append(name) }
                    case 503: if let name = String(data: value, encoding: encoding)?.trimmed { title = name }
                    case 201 where value.count >= 4: coverOffset = Int(value.uint32BE(at: value.startIndex))
                    default: break
                    }
                    cursor += length
                }
            }
        }

        // 正文记录：逐条去掉尾部附加数据，再解压
        var bytes: [UInt8] = []
        bytes.reserveCapacity(textLength)
        for index in 1 ... max(1, min(textRecordCount, count - 1)) where index < count {
            let record = Self.trimTrailingEntries(data[records[index]], flags: extraFlags)
            switch compression {
            case 1: bytes += record
            case 2: bytes += Self.palmDocDecompress(record)
            default: throw MobiError.unsupportedCompression
            }
        }
        if bytes.count > textLength { bytes.removeSubrange(textLength...) }

        var html = String(data: Data(bytes), encoding: encoding) ?? String(decoding: bytes, as: UTF8.self)
        // 图片引用统一成取图键：MOBI 用 recindex，AZW3 用 kindle:embed
        html = HTMLText.replace("<img\\b([^>]*?)recindex=\"0*(\\d+)\"", in: html, with: "<img $1 src=\"mobi:$2\"")
        html = HTMLText.replace("kindle:embed:([0-9A-V]+)(\\?[^\"]*)?", in: html, with: "kf8:$1")

        self.title = title
        self.author = authors.joined(separator: "、")
        self.firstImageRecord = firstImage
        self.coverKey = coverOffset.map { "mobi:\($0 + 1)" }
        self.documents = Self.split(html, kf8: kf8)
    }

    /// 按取图键取出图片数据：「mobi:3」是第 3 张图，「kf8:0003」是 AZW3 的第 3 个资源。
    func image(_ key: String) -> Data? {
        guard let first = firstImageRecord else { return nil }
        var index: Int?
        if key.hasPrefix("mobi:") { index = Int(key.dropFirst(5)) }
        if key.hasPrefix("kf8:") { index = Int(key.dropFirst(4), radix: 32) }
        guard let index, index > 0, first + index - 1 < records.count else { return nil }
        let record = data[records[first + index - 1]]
        let isImage = record.starts(with: [0xFF, 0xD8]) || record.starts(with: [0x89, 0x50, 0x4E, 0x47])
            || record.starts(with: [0x47, 0x49, 0x46])
        return isImage ? Data(record) : nil
    }

    /// MOBI 用 <mbp:pagebreak/> 分页；AZW3 里每个内部文件以 <html 开头。
    private static func split(_ html: String, kf8: Bool) -> [String] {
        let separator = kf8 ? "(?=<html\\b)" : "<mbp:pagebreak[^>]*>"
        let regex = try! NSRegularExpression(pattern: separator, options: .caseInsensitive)
        var parts: [String] = []
        var start = html.startIndex
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            parts.append(String(html[start ..< range.lowerBound]))
            start = range.upperBound
        }
        parts.append(String(html[start...]))
        return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: 解码细节

    /// 每条正文记录末尾可能附带索引数据，按头部的标志位去掉。
    static func trimTrailingEntries(_ record: Data, flags: UInt16) -> Data {
        let bytes = [UInt8](record)
        var size = bytes.count
        var bits = flags >> 1
        while bits != 0 {
            if bits & 1 == 1 {
                // 从末尾往前读一个变长整数，就是这段附加数据的长度
                var shift = 0, value = 0, position = size
                while position > 0 {
                    let byte = bytes[position - 1]
                    value |= Int(byte & 0x7F) << shift
                    shift += 7
                    position -= 1
                    if byte & 0x80 != 0 || shift >= 28 { break }
                }
                size -= min(value, size)
            }
            bits >>= 1
        }
        if flags & 1 == 1, size > 0 {
            size -= min(Int(bytes[size - 1] & 0x3) + 1, size)
        }
        return Data(bytes[0 ..< size])
    }

    /// PalmDOC 压缩：一种简单的 LZ77。
    static func palmDocDecompress(_ record: Data) -> [UInt8] {
        let input = [UInt8](record)
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 2)
        var i = 0
        while i < input.count {
            let byte = input[i]
            i += 1
            switch byte {
            case 1 ... 8:
                let end = min(i + Int(byte), input.count)
                output += input[i ..< end]
                i = end
            case 0, 9 ..< 0x80:
                output.append(byte)
            case 0xC0...:
                output.append(0x20)
                output.append(byte ^ 0x80)
            default:
                guard i < input.count else { break }
                let pair = (Int(byte) << 8 | Int(input[i])) & 0x3FFF
                i += 1
                let distance = pair >> 3, length = (pair & 7) + 3
                guard distance > 0, distance <= output.count else { continue }
                for _ in 0 ..< length { output.append(output[output.count - distance]) }
            }
        }
        return output
    }
}

extension Data {
    func uint16BE(at offset: Int) -> UInt16 {
        guard offset + 2 <= endIndex else { return 0 }
        return UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func uint32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= endIndex else { return 0 }
        return UInt32(uint16BE(at: offset)) << 16 | UInt32(uint16BE(at: offset + 2))
    }
}
