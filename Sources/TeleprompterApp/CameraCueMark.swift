import AppKit
import SwiftUI

/// Small full-color app icon for the black notch surface.
@MainActor enum CameraCueMark {
    // Mirror the 13-point chevron's visible edge inset within the compact shell:
    // the wider 22-point mark needs its center 4.5 points farther inward.
    static let leadingInset: CGFloat = 9.5
    static let expandedImage = controlImage(width: 32)
    // Keep the broad button hit area while placing the mark near its leading edge.
    static let leadingImage = controlImage(width: 72)
    private static func controlImage(width: Int) -> NSImage {
        let result = NSImage(size: NSSize(width: width, height: 22))
        for scale in [1, 2, 3] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale,
                pixelsHigh: 22 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            rep.size = result.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.imageInterpolation = .high
            let inset = (leadingInset * CGFloat(scale)).rounded() / CGFloat(scale)
            image.draw(in: NSRect(x: inset, y: 0, width: 22, height: 22))
            NSGraphicsContext.restoreGraphicsState()
            result.addRepresentation(rep)
        }
        result.isTemplate = false
        return result
    }
    // SwiftUI must receive the original pixels, not an NSImage whose nominal
    // 22-point notch size can be rasterized before the dashboard scales it up.
    static let artwork: CGImage? = {
        guard let url = Bundle.module.url(forResource: "CameraCueLogo", withExtension: "png"),
              let data = try? Data(contentsOf: url) else { return nil }
        return NSBitmapImageRep(data: data)?.cgImage
    }()
    static var swiftUIImage: Image {
        if let artwork { return Image(decorative: artwork, scale: 1, orientation: .up) }
        return Image(nsImage: image)
    }
    static let image: NSImage = {
        if let url = Bundle.module.url(forResource: "CameraCueLogo", withExtension: "png"),
           let data = try? Data(contentsOf: url),
           let rep = NSBitmapImageRep(data: data) {
            let icon = NSImage(size: NSSize(width: 22, height: 22))
            rep.size = icon.size
            icon.addRepresentation(rep)
            icon.isTemplate = false
            return icon
        }
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            NSColor(CuePalette.lavender).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 22, height: 22), xRadius: 6, yRadius: 6).fill()
            let curve = NSBezierPath()
            curve.move(to: NSPoint(x: 16.5, y: 16.5))
            curve.curve(to: NSPoint(x: 5, y: 11), controlPoint1: NSPoint(x: 10, y: 21), controlPoint2: NSPoint(x: 5, y: 17))
            curve.curve(to: NSPoint(x: 17, y: 5.8), controlPoint1: NSPoint(x: 5, y: 4), controlPoint2: NSPoint(x: 11, y: 2))
            curve.lineWidth = 4
            curve.lineCapStyle = .round
            NSColor(CuePalette.cream).setStroke()
            curve.stroke()
            NSColor(CuePalette.coral).setFill()
            NSBezierPath(ovalIn: NSRect(x: 14, y: 8.5, width: 5, height: 5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()
}

/// Downsample once to the exact backing-pixel size, avoiding both enlargement
/// of a tiny notch raster and GPU aliasing when shrinking the large artwork.
struct CameraCueLogo: View {
    var size: CGFloat
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        Group {
            if let pixels = CameraCueLogoPixels.image(size: size, scale: displayScale) {
                Image(decorative: pixels, scale: displayScale, orientation: .up)
                    .resizable().interpolation(.high)
            } else { CameraCueMark.swiftUIImage.resizable().interpolation(.high) }
        }.frame(width: size, height: size)
    }
}
@MainActor private enum CameraCueLogoPixels {
    static var cache: [Int: CGImage] = [:]
    static func image(size: CGFloat, scale: CGFloat) -> CGImage? {
        let width = max(1, Int((size * scale).rounded()))
        if let cached = cache[width] { return cached }
        guard let source = CameraCueMark.artwork,
              let context = CGContext(data: nil, width: width, height: width,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: width))
        guard let image = context.makeImage() else { return nil }
        cache[width] = image
        return image
    }
}
