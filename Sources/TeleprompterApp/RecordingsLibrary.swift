import AppKit
import AVFoundation
import SwiftUI

struct RecordingItem: Identifiable, Equatable {
    let url: URL
    let date: Date
    var id: String { url.path }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

enum RecordingDiscovery {
    static func scan(folders: [URL]) throws -> [RecordingItem] {
        var found: [String: RecordingItem] = [:]
        var folderError: Error?
        for folder in Set(folders.map(\.standardizedFileURL)) {
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            do {
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
            for url in urls where url.pathExtension.lowercased() == "mp4" {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey])
                guard values.isRegularFile == true else { continue }
                found[url.path] = RecordingItem(url: url, date: values.creationDate ?? values.contentModificationDate ?? .distantPast)
            }
            } catch { folderError = error }
        }
        if found.isEmpty, let folderError { throw folderError }
        return found.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
}

struct RecordingsLibrary: View {
    @ObservedObject var video: CameraRecording
    @State private var items: [RecordingItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selected: RecordingItem?
    @State private var refresh = UUID()
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        StudioPageHeader(title: "Your recordings.", subtitle: "Review your takes, then find the MP4 in Finder.")
                        Spacer()
                        Button("Refresh") { refresh = UUID() }.buttonStyle(StudioButtonStyle())
                        Button("Open save folder") { NSWorkspace.shared.open(video.folder) }.buttonStyle(StudioButtonStyle())
                    }
                    if let error { Text(error).foregroundStyle(StudioPalette.mutedInk) }
                    if loading { ProgressView("Finding recordings…") }
                    else if items.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "video").font(.system(size: 28)).foregroundStyle(StudioPalette.violet)
                            Text("Your next take belongs here.").font(.system(size: 18, weight: .semibold))
                            Text("Use Record, then press Stop to save an MP4. Recordings from your CameraCue Studio save folders appear here.")
                                .font(.system(size: 14)).foregroundStyle(StudioPalette.mutedInk).multilineTextAlignment(.center)
                        }.padding(32).frame(maxWidth: .infinity).background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: StudioLayout.columns(for: geometry.size.width - 48)), spacing: 16) {
                            ForEach(items) { item in
                                VStack(alignment: .leading, spacing: 12) {
                                    Button { selected = item } label: {
                                        VStack(alignment: .leading, spacing: 12) {
                                            RecordingThumbnail(url: item.url)
                                            Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                                            Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundStyle(StudioPalette.mutedInk)
                                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(StudioSurfaceStyle()).accessibilityLabel("Play " + item.title)
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                        .buttonStyle(StudioButtonStyle()).padding(.horizontal, 16).padding(.bottom, 16)
                                }.background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                            }
                        }
                    }
                }.padding(24).foregroundStyle(StudioPalette.ink)
            }.background(StudioPalette.canvas)
        }
        .task(id: refresh) { await reload() }
        .onChange(of: video.savedURL) { _, _ in refresh = UUID() }
        .onChange(of: video.folder) { _, _ in refresh = UUID() }
        .sheet(item: $selected) { item in
            RecordingReview(url: item.url, onDone: { selected = nil }, onChanged: { refresh = UUID() })
        }
    }
    private func reload() async {
        loading = true; error = nil
        let folders = video.recordingFolders
        do {
            let result = try await Task.detached(priority: .utility) { try RecordingDiscovery.scan(folders: folders) }.value
            guard !Task.isCancelled else { return }
            items = result
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Could not read a recording folder. Check that it is connected and accessible, then refresh."
        }
        loading = false
    }
}

private struct RecordingThumbnail: View {
    let url: URL
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            StudioPalette.lavenderWash
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else { Image(systemName: "play.rectangle").font(.system(size: 32)).foregroundStyle(StudioPalette.violet) }
        }.aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 10))
            .task(id: url) {
                image = nil
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 640, height: 360)
                if let result = try? await generator.image(at: .zero), !Task.isCancelled { image = result.image }
            }
    }
}
