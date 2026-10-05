import Foundation

/// Optional local sidecar; older recordings remain usable without one.
struct RecordingBackgroundMetadata: Codable {
    var version = 1
    var background: CameraBackground
    var originalRelativePath: String?
    var originalIsCameraSource: Bool
    static func sidecar(for url: URL) -> URL { url.appendingPathExtension("cameracue.json") }
    static func read(for url: URL) -> Self? {
        guard let data = try? Data(contentsOf: sidecar(for: url)), data.count < 64_000,
              let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1 else { return nil }
        return value
    }
    func write(for url: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.sidecar(for: url), options: .atomic)
    }
    func originalURL(for url: URL) -> URL? {
        guard let relative = originalRelativePath, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
        let folder = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let original = folder.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard original.path.hasPrefix(folder.path + "/"), ["mp4", "mov", "m4v"].contains(original.pathExtension.lowercased()),
              (try? original.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return original
    }
}

struct RecordingBackgroundSource: Sendable {
    let url: URL
    let isCameraOriginal: Bool
    let hasSeparateOriginal: Bool
    static func resolve(_ url: URL) -> Self {
        if let metadata = RecordingBackgroundMetadata.read(for: url) {
            if let original = metadata.originalURL(for: url) {
                return Self(url: original, isCameraOriginal: metadata.originalIsCameraSource, hasSeparateOriginal: original != url)
            }
            if metadata.background.mode == .original {
                return Self(url: url, isCameraOriginal: metadata.originalIsCameraSource, hasSeparateOriginal: false)
            }
        }
        return Self(url: url, isCameraOriginal: false, hasSeparateOriginal: false)
    }
    func metadata(background: CameraBackground, destination: URL) -> RecordingBackgroundMetadata {
        let folder = destination.deletingLastPathComponent().standardizedFileURL
        let path = url.standardizedFileURL.path
        let prefix = folder.path + "/"
        let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
        return RecordingBackgroundMetadata(background: background, originalRelativePath: relative, originalIsCameraSource: isCameraOriginal)
    }
}
