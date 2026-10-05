import AppKit
import CoreImage
import ImageIO
import Vision

struct CameraBackground: Codable, Equatable, Sendable {
    enum Mode: String, CaseIterable, Codable { case original, blur, color, image }
    var mode: Mode = .original
    var color = "lavender"
    var image = "warm-studio"
    var customPath: String?
    static let presets = ["warm-studio", "quiet-office", "soft-landscape"]
    static let colors: [(String, String, CIColor)] = [
        ("lavender", "Lavender", CIColor(red: 0.76, green: 0.69, blue: 0.94)),
        ("peach", "Peach", CIColor(red: 1, green: 0.83, blue: 0.75)),
        ("mint", "Mint", CIColor(red: 0.72, green: 0.89, blue: 0.82)),
        ("sky", "Sky", CIColor(red: 0.73, green: 0.85, blue: 0.97)),
        ("ivory", "Ivory", CIColor(red: 0.96, green: 0.94, blue: 0.90))
    ]
    var imageURL: URL? {
        if image == "custom", let customPath { return URL(fileURLWithPath: customPath) }
        return Bundle.module.url(forResource: image, withExtension: "png")
    }
    static func importImage(_ source: URL) throws -> URL {
        guard let image = loadImage(source) else { throw RecordingFailure.message("This image cannot be opened.") }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CameraCue/Backgrounds", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("background-\(UUID()).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw RecordingFailure.message("Could not save your background.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RecordingFailure.message("Could not save your background.") }
        return url
    }
    static func name(_ id: String) -> String {
        switch id { case "warm-studio": return "Warm studio"; case "quiet-office": return "Quiet office"; case "soft-landscape": return "Soft landscape"; default: return "Your image" }
    }
    /// Decode at a bounded size off the UI thread; reject malformed/unsupported images.
    static func loadImage(_ url: URL, maximumPixelSize: Int = 2560) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

/// Confined to the frame queue. Vision and compositing never run on the UI thread.
final class CameraBackgroundProcessor {
    let context = CIContext(options: [.cacheIntermediates: false])
    private let segmentation = VNGeneratePersonSegmentationRequest()
    private var setting = CameraBackground()
    private var backdrop: CIImage?
    private var lastMask: CIImage?
    private var lastMaskTime = -Double.infinity
    private var maskSize = CGSize.zero
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private let offline: Bool
    init(offline: Bool = false) {
        self.offline = offline
        segmentation.qualityLevel = offline ? .accurate : .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }
    func configure(_ setting: CameraBackground) throws {
        var image: CIImage?
        if setting.mode == .image {
            guard let url = setting.imageURL, let cg = CameraBackground.loadImage(url) else {
                throw RecordingFailure.message("This background image cannot be opened. Choose another image.")
            }
            image = CIImage(cgImage: cg)
        }
        self.setting = setting; backdrop = image; lastMask = nil; lastMaskTime = -.infinity
    }
    static func aspectFill(_ image: CIImage, into bounds: CGRect) -> CIImage {
        let extent = image.extent
        let scale = max(bounds.width / extent.width, bounds.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(by: CGAffineTransform(translationX: bounds.midX - scaled.extent.midX, y: bounds.midY - scaled.extent.midY)).cropped(to: bounds)
    }
    /// Shared by the preview and encoder. An unavailable mask fails closed to the
    /// selected background rather than briefly leaking the unmodified room.
    func composite(_ frame: CIImage, mask: CIImage?) -> CIImage {
        guard setting.mode != .original else { return frame }
        let bounds = frame.extent
        let background: CIImage
        switch setting.mode {
        case .original: return frame
        case .blur: background = frame.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24]).cropped(to: bounds)
        case .color: background = CIImage(color: CameraBackground.colors.first { $0.0 == setting.color }?.2 ?? CameraBackground.colors[0].2).cropped(to: bounds)
        case .image: background = Self.aspectFill(backdrop ?? CIImage(color: .black).cropped(to: bounds), into: bounds)
        }
        guard let mask else { return background }
        let scaledMask = mask.transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY)).transformed(by: CGAffineTransform(scaleX: bounds.width / mask.extent.width, y: bounds.height / mask.extent.height))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.8]).cropped(to: bounds)
        return frame.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: scaledMask]).cropped(to: bounds)
    }
    func process(_ buffer: CVPixelBuffer, time: Double) throws -> CVPixelBuffer {
        guard setting.mode != .original else { return buffer }
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        // Reuse a stateful mask for intervening frames, at most 15 segmentations/s.
        if offline || size != maskSize || time - lastMaskTime >= 1.0 / 15 {
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([segmentation])
            lastMask = segmentation.results?.first.map { CIImage(cvPixelBuffer: $0.pixelBuffer) }
            lastMaskTime = time; maskSize = size
        }
        if pool == nil || poolSize != size {
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: Int(size.width), kCVPixelBufferHeightKey: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true
            ] as CFDictionary, &pool)
            poolSize = size
        }
        var output: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary, &output) == kCVReturnSuccess, let output else {
            throw RecordingFailure.message("Background processing ran out of video buffers.")
        }
        context.render(composite(CIImage(cvPixelBuffer: buffer), mask: lastMask), to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }
}
