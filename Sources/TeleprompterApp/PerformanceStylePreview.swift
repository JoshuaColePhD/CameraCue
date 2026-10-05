import SwiftUI
import TeleprompterCore

struct PerformanceStylePreview: View {
    @State var plan: PerformanceStylePlan
    @ObservedObject var model: TeleprompterModel
    @ObservedObject var notch: NotchController
    let onApply: (PerformanceStylePlan) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedLine = 0
    @State private var phrase = ""
    @State private var notice = "Select a reading phrase to shape its delivery."
    @State private var undoPlan: PerformanceStylePlan?
    private var document: ScriptDocument { ScriptDocument(plan.formattedBody) }
    private var preset: Binding<ReadingStylePreset> {
        Binding(get: { plan.preset ?? .natural }, set: { plan = plan.styled($0, intensity: plan.intensity ?? 0.65) })
    }
    private var intensity: Binding<Double> {
        Binding(get: { plan.intensity ?? 0.65 }, set: { plan = plan.styled(plan.preset ?? .natural, intensity: $0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                CueIcon(.sparkle, size: 24, badge: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Shape your delivery").font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text("Original wording stays intact. Choose the feeling, then fine-tune a phrase.").foregroundStyle(StudioPalette.mutedInk)
                }
                Spacer()
                Text(plan.usedAI ? "AI suggestions" : "Local suggestions").font(.caption).foregroundStyle(StudioPalette.violet)
            }
            HStack(spacing: 24) {
                Picker("Style", selection: preset) { ForEach(ReadingStylePreset.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 355)
                Text("Intensity").font(.caption)
                Slider(value: intensity, in: 0...1).frame(width: 160).disabled(plan.preset == .minimal)
                Text("\(Int(intensity.wrappedValue * 100))%").monospacedDigit().frame(width: 38)
            }
            ScrollView {
              HStack(alignment: .top, spacing: 22) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(document.lines.filter { !$0.spokenText.isEmpty }) { line in
                                Button { select(line) } label: {
                                    Text(line.spokenText).font(.system(size: 14, design: .rounded))
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                        .background(selectedLine == line.id ? StudioPalette.lavenderWash : StudioPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain).id(line.id)
                            }
                        }
                    }.frame(width: 270, height: 360)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("ACTUAL NOTCH SIZE").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(StudioPalette.violet)
                    NotchPreview(document: document, performance: plan, headerLayout: notch.layout, activeLineID: selectedLine,
                                 textWidth: model.textWidth, fontSize: model.fontSize, focused: model.focusedReading, showAnnotations: model.showAnnotations, timerText: model.presentationTime(at: .now))
                    TextField("Exact phrase", text: $phrase).textFieldStyle(.roundedBorder).accessibilityLabel("Phrase to format")
                    HStack(spacing: 7) {
                        Button { edit(.emphasize) } label: { StudioLabel("Emphasize", .sparkle) }
                        Button { edit(.pause) } label: { StudioLabel("Pause here", .pause) }
                        Button { edit(.keepTogether) } label: { StudioLabel("Keep together", .reader) }
                    }.buttonStyle(StudioButtonStyle())
                    HStack {
                        Button("Include next phrase") {
                            if let next = document.lines.first(where: { $0.id > selectedLine && !$0.spokenText.isEmpty }) { phrase += " " + next.spokenText }
                        }
                        Spacer()
                        Button("Undo edit") { if let undoPlan { plan = undoPlan; self.undoPlan = nil } }.disabled(undoPlan == nil)
                    }.buttonStyle(.borderless).font(.caption)
                    Text(notice).font(.caption).foregroundStyle(StudioPalette.mutedInk)
                }.frame(width: notch.layout.size.width)
              }
            }.frame(height: min(max(360, notch.layout.size.height + 184),
                                max(360, (notch.display?.visibleBounds.height ?? 800) - 240)))
            Divider()
            HStack {
                Text("\(document.tokens.count) spoken words · Original preserved").font(.caption).foregroundStyle(StudioPalette.mutedInk)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(StudioButtonStyle())
                Button { onApply(plan.styled(plan.preset ?? .natural, intensity: plan.intensity ?? 0.65)) } label: { StudioLabel("Use this style", .check) }.buttonStyle(StudioButtonStyle(primary: true))
            }
        }.padding(24).background(StudioPalette.canvas).foregroundStyle(StudioPalette.ink).tint(StudioPalette.violet).preferredColorScheme(.light)
            .onAppear { if let first = document.lines.first(where: { !$0.spokenText.isEmpty }) { select(first) } }
    }
    private func select(_ line: ScriptLine) { selectedLine = line.id; phrase = line.spokenText }
    private func edit(_ treatment: PhraseTreatment) {
        guard let edited = plan.editing(lineID: selectedLine, phrase: phrase, treatment: treatment) else {
            notice = "Use an exact phrase starting on this line. Keep-together phrases can be up to 72 characters; accents stay on one line."
            return
        }
        undoPlan = plan; plan = edited
        notice = treatment == .keepTogether ? "Phrase kept together. Check its fit in the preview." : "Delivery updated. Spoken words are unchanged."
    }
}

struct NotchPreview: View {
    let document: ScriptDocument
    let performance: PerformanceStylePlan?
    var headerLayout = NotchLayout()
    var activeLineID = 0
    var textWidth: Double = 320
    var fontSize: Double = 29
    var focused = true
    var showAnnotations = true
    var timerText = "05:00"
    private func previewControl(_ symbol: CueSymbol, title: String, rect: CGRect, color: Color, background: Bool = true) -> some View {
        HStack(spacing: 4) {
            CueGlyphPreview(symbol: symbol).stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)).frame(width: 13, height: 13)
            if !title.isEmpty { Text(title).font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit() }
        }.foregroundStyle(color)
            .frame(width: rect.width, height: rect.height)
            .background(color.opacity(background ? 0.055 : 0), in: Capsule())
            .position(x: rect.midX, y: rect.midY)
    }
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                CameraCueLogo(size: min(22, headerLayout.controlHeight))
                    .padding(.leading, CameraCueMark.leadingInset)
                    .frame(width: headerLayout.brandControl(expanded: true).width, height: headerLayout.brandControl(expanded: true).height, alignment: .leading)
                    .position(x: headerLayout.brandControl(expanded: true).midX, y: headerLayout.brandControl(expanded: true).midY)
                previewControl(.collapse, title: "", rect: headerLayout.chevronControl(expanded: true), color: .white, background: false)
                Text(timerText).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(CuePalette.butter.opacity(0.9))
                    .frame(width: headerLayout.timerControl.width, height: headerLayout.timerControl.height, alignment: .trailing)
                    .position(x: headerLayout.timerControl.midX, y: headerLayout.timerControl.midY)
                Text("Record").font(.system(size: 11, weight: .semibold)).foregroundStyle(CuePalette.coral)
                    .frame(width: headerLayout.recordControl(expanded: true).width, height: headerLayout.recordControl(expanded: true).height)
                    .position(x: headerLayout.recordControl(expanded: true).midX, y: headerLayout.recordControl(expanded: true).midY)
            }.frame(width: headerLayout.size.width, height: headerLayout.header)
            ReadingStage(document: document, performance: performance, activeLineID: activeLineID,
                         textWidth: textWidth, fontSize: fontSize, showAnnotations: showAnnotations, focused: focused)
            Text("Reading preview").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).frame(height: 27)
            Capsule().fill(CuePalette.lavender.opacity(0.32)).frame(width: 36, height: 3)
                .frame(height: NotchLayout.resizeStripHeight)
        }.frame(width: headerLayout.size.width, height: headerLayout.size.height).background(.black).clipShape(NotchShape(expansion: 1))
            .accessibilityElement(children: .contain).accessibilityLabel("Notch preview at actual size")
    }
}

private struct CueGlyphPreview: Shape {
    let symbol: CueSymbol
    func path(in rect: CGRect) -> Path { Path(symbol.path()).applying(CGAffineTransform(scaleX: rect.width/24, y: rect.height/24)) }
}
