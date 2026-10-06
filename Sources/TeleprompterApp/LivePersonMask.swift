import Foundation
import CoreVideo
import Vision

/// One retained camera frame at a time; no growing segmentation backlog.
/// All Vision request use is confined to `queue`; mailbox fields use `lock`.
final class LivePersonMask: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CameraCue.person-mask", qos: .userInitiated)
    private let lock = NSLock()
    private let compute: @Sendable (CVPixelBuffer) throws -> CVPixelBuffer?
    private var generation = 0
    private var busy = false
    private var result: PixelReference?

    init(compute: (@Sendable (CVPixelBuffer) throws -> CVPixelBuffer?)? = nil) {
        if let compute { self.compute = compute }
        else {
            let vision = PersonMaskVision()
            self.compute = { try vision.mask($0) }
        }
    }
    func reset() {
        lock.lock(); generation += 1; result = nil; lock.unlock()
    }
    var isComputing: Bool { lock.lock(); defer { lock.unlock() }; return busy }
    var latest: CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }; return result?.buffer
    }
    /// Startup seeds the first mask before displaying the preview. Later masks
    /// run asynchronously, retaining the same balanced segmentation quality.
    func first(_ buffer: CVPixelBuffer) throws -> CVPixelBuffer? {
        let frame = PixelReference(buffer)
        lock.lock(); let current = generation; lock.unlock()
        let computed = try queue.sync { try compute(frame.buffer).map(PixelReference.init) }
        lock.lock()
        if current == generation { result = computed }
        lock.unlock()
        return computed?.buffer
    }
    @discardableResult func submit(_ buffer: CVPixelBuffer) -> Bool {
        lock.lock()
        guard !busy else { lock.unlock(); return false }
        busy = true; let current = generation
        lock.unlock()
        let frame = PixelReference(buffer)
        queue.async { [self] in
            // A failed refresh keeps the last good mask; it never leaks the room.
            let computed = try? compute(frame.buffer).map(PixelReference.init)
            lock.lock()
            if current == generation, let computed { result = computed }
            busy = false
            lock.unlock()
        }
        return true
    }
}

/// CVPixelBuffer ownership prevents reuse while the single mask job reads it.
/// This box is immutable; neither camera pixels nor completed masks are mutated.
private final class PixelReference: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}
private final class PersonMaskVision: @unchecked Sendable {
    private let request = VNGeneratePersonSegmentationRequest()
    init() {
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }
    // Called only on the LivePersonMask serial queue.
    func mask(_ buffer: CVPixelBuffer) throws -> CVPixelBuffer? {
        try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
        return request.results?.first?.pixelBuffer
    }
}
