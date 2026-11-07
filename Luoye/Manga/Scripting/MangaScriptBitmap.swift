import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct MangaScriptBitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]
    init(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 30000, height <= 60000, width * height <= 40_000_000 else {
            throw MangaScriptRuntime.RuntimeError.message("漫画图片尺寸超出处理范围")
        }
        self.width = width; self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }
    init(data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MangaScriptRuntime.RuntimeError.message("漫画图片无法解码")
        }
        try self.init(width: image.width, height: image.height)
        let width = width, height = height
        let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { throw MangaScriptRuntime.RuntimeError.message("漫画图片解码失败") }
    }
    func cropped(x: Int, y: Int, width: Int, height: Int) throws -> Self? {
        guard x >= 0, y >= 0, width > 0, height > 0, x + width <= self.width, y + height <= self.height else { return nil }
        var result = try Self(width: width, height: height)
        for row in 0..<height {
            let start = ((y + row) * self.width + x) * 4
            result.pixels.replaceSubrange((row * width * 4)..<((row + 1) * width * 4), with: pixels[start..<(start + width * 4)])
        }
        return result
    }
    func rotated() throws -> Self {
        var result = try Self(width: height, height: width)
        for y in 0..<height {
            for x in 0..<width {
                let source = (y * width + x) * 4
                let target = (x * height + height - 1 - y) * 4
                result.pixels[target..<(target + 4)] = pixels[source..<(source + 4)]
            }
        }
        return result
    }
    mutating func fill(_ image: Self, x: Int, y: Int, srcX: Int = 0, srcY: Int = 0, width: Int? = nil, height: Int? = nil) {
        let width = width ?? image.width, height = height ?? image.height
        guard width > 0, height > 0 else { return }
        for row in 0..<height {
            let sourceY = srcY + row, targetY = y + row
            guard sourceY >= 0, sourceY < image.height, targetY >= 0, targetY < self.height else { continue }
            let left = max(0, -x, -srcX), right = min(width, self.width - x, image.width - srcX)
            guard left < right else { continue }
            let source = (sourceY * image.width + srcX + left) * 4
            let target = (targetY * self.width + x + left) * 4
            let count = (right - left) * 4
            pixels.replaceSubrange(target..<(target + count), with: image.pixels[source..<(source + count)])
        }
    }
    func png() throws -> Data {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw MangaScriptRuntime.RuntimeError.message("图片编码失败") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw MangaScriptRuntime.RuntimeError.message("图片编码失败") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MangaScriptRuntime.RuntimeError.message("图片编码失败") }
        return data as Data
    }
}
