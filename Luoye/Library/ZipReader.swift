import Compression
import Foundation

/// 读 ZIP 压缩包（EPUB 本身就是 ZIP）。只支持常见的“不压缩”和 deflate 两种方式，不支持加密和 ZIP64。
struct ZipReader {
    struct Entry {
        let path: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    enum ZipError: Error {
        case notAZip
        case unsupported
        case corrupted
    }

    private let data: Data
    let entries: [String: Entry]

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        self.data = data
        self.entries = try Self.readCentralDirectory(data)
    }

    /// 取出压缩包里某个文件的内容。
    func read(_ path: String) throws -> Data? {
        guard let entry = entries[path] else { return nil }
        let base = data.startIndex + entry.localHeaderOffset
        guard base >= data.startIndex, base <= data.endIndex - 30, data.uint32(at: base) == 0x0403_4b50 else { throw ZipError.corrupted }
        let nameLength = Int(data.uint16(at: base + 26))
        let extraLength = Int(data.uint16(at: base + 28))
        let start = base + 30 + nameLength + extraLength
        guard entry.compressedSize >= 0, start <= data.endIndex, entry.compressedSize <= data.endIndex - start else { throw ZipError.corrupted }
        let raw = data[start ..< start + entry.compressedSize]

        switch entry.method {
        case 0:
            return Data(raw)
        case 8:
            return try Self.inflate(raw, expectedSize: entry.uncompressedSize)
        default:
            throw ZipError.unsupported
        }
    }

    private static func readCentralDirectory(_ data: Data) throws -> [String: Entry] {
        // 文件末尾的“目录结束记录”，前面最多可能跟 64 KB 的注释。
        let minimum = 22
        guard data.count >= minimum else { throw ZipError.notAZip }
        let lowest = max(data.startIndex, data.endIndex - minimum - 65_535)
        var end = data.endIndex - minimum
        while end >= lowest, data.uint32(at: end) != 0x0605_4b50 {
            end -= 1
        }
        guard end >= lowest else { throw ZipError.notAZip }

        guard data.uint16(at: end + 4) == 0, data.uint16(at: end + 6) == 0,
              data.uint16(at: end + 8) == data.uint16(at: end + 10),
              end + 22 + Int(data.uint16(at: end + 20)) <= data.endIndex else { throw ZipError.unsupported }
        let count = Int(data.uint16(at: end + 10))
        guard count < 65_535 else { throw ZipError.unsupported }
        var cursor = data.startIndex + Int(data.uint32(at: end + 16))
        var entries: [String: Entry] = [:]
        for _ in 0 ..< count {
            guard cursor + 46 <= data.endIndex, data.uint32(at: cursor) == 0x0201_4b50 else {
                throw ZipError.corrupted
            }
            let nameLength = Int(data.uint16(at: cursor + 28))
            let extraLength = Int(data.uint16(at: cursor + 30))
            let commentLength = Int(data.uint16(at: cursor + 32))
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= data.endIndex else { throw ZipError.corrupted }
            guard data.uint16(at: cursor + 8) & 1 == 0 else { throw ZipError.unsupported }
            let nameData = data[cursor + 46 ..< cursor + 46 + nameLength]
            let path = String(decoding: nameData, as: UTF8.self)
            entries[path] = Entry(
                path: path,
                method: data.uint16(at: cursor + 10),
                compressedSize: Int(data.uint32(at: cursor + 20)),
                uncompressedSize: Int(data.uint32(at: cursor + 24)),
                localHeaderOffset: Int(data.uint32(at: cursor + 42))
            )
            cursor = next
        }
        return entries
    }

    private static func inflate(_ input: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0, expectedSize <= 64 * 1024 * 1024 else { throw ZipError.unsupported }
        if expectedSize == 0 { return Data() }
        guard !input.isEmpty else { throw ZipError.corrupted }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    source.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw ZipError.corrupted }
        return output
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }
}
