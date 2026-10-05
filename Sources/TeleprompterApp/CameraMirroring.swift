import AVFoundation

protocol CameraMirroringConnection: AnyObject {
    var isVideoMirroringSupported: Bool { get }
    var automaticallyAdjustsVideoMirroring: Bool { get set }
    var isVideoMirrored: Bool { get set }
}

extension AVCaptureConnection: CameraMirroringConnection {}

enum CameraMirroring {
    static func apply(to connection: any CameraMirroringConnection, mirrored: Bool) {
        guard connection.isVideoMirroringSupported else { return }
        // AVFoundation raises NSInvalidArgumentException if videoMirrored is
        // assigned while automaticallyAdjustsVideoMirroring is still enabled.
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirrored != mirrored { connection.isVideoMirrored = mirrored }
    }
}
