import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns an iOS app icon (a full-bleed square) into a macOS-style .icns: the artwork inset
/// on a transparent canvas with rounded corners and a soft shadow, like other Mac apps.
enum MacIcon {
    /// The largest icon PNG an iOS bundle declares in its Info.plist, if any can be read.
    static func sourcePNG(in bundle: URL, info: [String: Any]) -> URL? {
        var names: [String] = info["CFBundleIconFiles"] as? [String] ?? []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            let primary = (info[key] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
            names += primary?["CFBundleIconFiles"] as? [String] ?? []
            if let name = primary?["CFBundleIconName"] as? String { names.append(name) }
        }
        guard !names.isEmpty else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: bundle.path)) ?? []
        return files
            .filter { file in file.hasSuffix(".png") && names.contains { file.hasPrefix($0) } }
            .map { bundle.appendingPathComponent($0) }
            .compactMap { url in pixelWidth(url).map { (url, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// Writes `AppIcon.icns` built from `png` to `destination`.
    static func makeICNS(from png: URL, to destination: URL, scratch: URL) throws {
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
              let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
        let iconset = scratch.appendingPathComponent("AppIcon.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try write(render(artwork, size: points * scale), to: iconset.appendingPathComponent(name))
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Apple's Mac icon grid: 824 of 1024 points of artwork, corner radius about 22.5%.
    static func render(_ artwork: CGImage, size: Int) -> CGImage {
        let canvas = CGFloat(size)
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        let side = canvas * 824 / 1024
        let frame = CGRect(x: (canvas - side) / 2, y: (canvas - side) / 2 + canvas * 0.01, width: side, height: side)
        let shape = CGPath(roundedRect: frame, cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil)
        if size >= 64 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -canvas * 0.01), blur: canvas * 0.02,
                              color: CGColor(gray: 0, alpha: 0.3))
            context.addPath(shape)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }
        context.addPath(shape)
        context.clip()
        context.draw(artwork, in: frame)
        return context.makeImage()!
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func pixelWidth(_ url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return properties[kCGImagePropertyPixelWidth] as? Int
    }
}
