import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Loads and saves 8-bit RGBA frames for the command-line tool.
public enum FrameIO {
    public struct Image {
        public let width: Int
        public let height: Int
        public var rgba: [UInt8]
    }

    public static func load(_ url: URL) throws -> Image {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw LSFGError.image("cannot read \(url.path)")
        }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw LSFGError.image("cannot decode \(url.path)") }
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        return Image(width: w, height: h, rgba: pixels)
    }

    public static func save(_ image: Image, to url: URL) throws {
        let data = Data(image.rgba) as CFData
        guard let provider = CGDataProvider(data: data),
              let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw LSFGError.image("cannot write \(url.path)")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw LSFGError.image("cannot write \(url.path)") }
    }

    public static func upload(_ image: Image, to texture: MTLTexture) {
        image.rgba.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: image.width * 4)
        }
    }

    public static func download(_ texture: MTLTexture) -> Image {
        var img = Image(width: texture.width, height: texture.height,
                        rgba: [UInt8](repeating: 0, count: texture.width * texture.height * 4))
        img.rgba.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return img
    }
}

extension FrameIO {
    /// Nearest-neighbour resize, good enough for benchmark inputs.
    public static func resized(_ img: Image, width: Int, height: Int) -> Image {
        if img.width == width && img.height == height { return img }
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let sy = y * img.height / height
            for x in 0..<width {
                let sx = x * img.width / width
                let s = (sy * img.width + sx) * 4, d = (y * width + x) * 4
                out[d] = img.rgba[s]; out[d + 1] = img.rgba[s + 1]; out[d + 2] = img.rgba[s + 2]
            }
        }
        return Image(width: width, height: height, rgba: out)
    }
}
