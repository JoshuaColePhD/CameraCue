import SwiftUI
import AppKit

struct CameraBackgroundPicker: View {
    @ObservedObject var video: CameraRecording
    var locked: Bool
    var body: some View {
        BackgroundOptions(setting: video.background, disabled: locked || video.isBusy || video.changingBackground,
                          busy: video.changingBackground, message: video.backgroundMessage,
                          detail: video.state == .preparing ? "Wait for camera setup or cancel it before changing the background." : locked || video.isBusy ? "Finish your take to change the background." : "Applied to the preview and saved video. Processed on your Mac.",
                          change: { setting in Task { await video.changeBackground(setting) } }, upload: video.chooseBackgroundImage)
    }
}

struct BackgroundOptions: View {
    var setting: CameraBackground
    var disabled = false
    var busy = false
    var message: String?
    var detail: String
    var originalLabel = "Original"
    var change: (CameraBackground) -> Void
    var upload: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Background").font(.system(size: 14, weight: .semibold))
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            Picker("Background effect", selection: Binding(get: { setting.mode }, set: { mode in
                var setting = setting; setting.mode = mode
                change(setting)
            })) {
                Text(originalLabel).tag(CameraBackground.Mode.original)
                Text("Blur").tag(CameraBackground.Mode.blur)
                Text("Color").tag(CameraBackground.Mode.color)
                Text("Image").tag(CameraBackground.Mode.image)
            }.pickerStyle(.segmented).disabled(disabled)
            if setting.mode == .color {
                HStack(spacing: 10) {
                    ForEach(CameraBackground.colors, id: \.0) { id, title, ci in
                        Button {
                            var setting = setting; setting.color = id
                            change(setting)
                        } label: {
                            Circle().fill(Color(red: ci.red, green: ci.green, blue: ci.blue))
                                .frame(width: 28, height: 28)
                                .overlay(Circle().stroke(setting.color == id ? StudioPalette.violet : StudioPalette.outline, lineWidth: setting.color == id ? 3 : 1))
                        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(setting.color == id ? .isSelected : []).help(title)
                    }
                }.disabled(disabled)
            }
            if setting.mode == .image {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 65)), count: 3), spacing: 8) {
                    ForEach(CameraBackground.presets, id: \.self) { id in
                        Button {
                            var setting = setting; setting.image = id
                            change(setting)
                        } label: {
                            VStack(spacing: 4) {
                                CameraBackgroundThumbnail(id: id)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(setting.image == id ? StudioPalette.violet : StudioPalette.outline, lineWidth: setting.image == id ? 2 : 1))
                                Text(CameraBackground.name(id)).font(.system(size: 11)).foregroundStyle(StudioPalette.ink)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Use \(CameraBackground.name(id)) background").accessibilityAddTraits(setting.image == id ? .isSelected : [])
                    }
                }.disabled(disabled)
                HStack {
                    Button { upload() } label: { StudioLabel("Upload image", systemImage: "photo.badge.plus") }.buttonStyle(StudioButtonStyle()).disabled(disabled)
                    if setting.image == "custom" { Text("Your image selected").font(.caption).foregroundStyle(StudioPalette.mutedInk) }
                }
            }
            if let message = message { Text(message).font(.caption).foregroundStyle(StudioPalette.coral).fixedSize(horizontal: false, vertical: true) }
            Text(detail)
                .font(.system(size: 12)).foregroundStyle(StudioPalette.mutedInk).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(StudioPalette.ink)
    }
}

private struct CameraBackgroundThumbnail: View {
    let id: String
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable() }
            else { Rectangle().fill(StudioPalette.canvas).overlay(Image(systemName: "photo").foregroundStyle(StudioPalette.mutedInk)) }
        }.aspectRatio(16 / 9, contentMode: .fit).task(id: id) {
            var setting = CameraBackground(); setting.image = id
            guard let url = setting.imageURL else { return }
            let decoded = await Task.detached(priority: .utility) { CameraBackground.loadImage(url, maximumPixelSize: 480) }.value
            guard !Task.isCancelled else { return }; image = decoded
        }
    }
}
