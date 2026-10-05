import AppKit
import SwiftUI
import TeleprompterCore

struct ScriptEditingWorkspace: View {
    @ObservedObject var library: ScriptLibrary
    @StateObject private var selection = ScriptSelection()
    @State private var showCue = false
    @State private var cue = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if selection.tokens != nil {
                    Button("Emphasize") { selection.format(.emphasize) }.buttonStyle(StudioButtonStyle())
                    Button("Pause") { selection.format(.pause) }.buttonStyle(StudioButtonStyle())
                    Button("Delivery cue") { cue = ""; showCue = true }.buttonStyle(StudioButtonStyle())
                        .popover(isPresented: $showCue) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("How should this sound?").font(.headline)
                                TextField("For example: whisper or smile", text: $cue).textFieldStyle(.roundedBorder)
                                    .onSubmit { addCue() }
                                Text("A reading note, never spoken text.").font(.caption).foregroundStyle(StudioPalette.mutedInk)
                                Button("Add cue", action: addCue).buttonStyle(StudioButtonStyle(primary: true))
                                    .disabled(cue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cue.count > 80)
                            }.padding(18).frame(width: 280)
                        }
                    Text("\(selection.tokens?.count ?? 0) words selected").font(.caption).foregroundStyle(StudioPalette.mutedInk)
                } else {
                    Image(systemName: "info.circle").foregroundStyle(StudioPalette.mutedInk)
                        .help("Select spoken words to emphasize, add a pause, or give a delivery cue. Delivery notes in brackets are not spoken.")
                        .accessibilityLabel("Formatting help")
                }
                Spacer(minLength: 0)
            }.frame(height: 34)
            NativeScriptEditor(library: library, selection: selection)
                .overlay(alignment: .topLeading) {
                    if library.selected?.body.isEmpty == true {
                        Text("Start writing your script…").font(.system(size: 16)).foregroundStyle(StudioPalette.mutedInk)
                            .padding(.horizontal, 26).padding(.top, 18).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(StudioPalette.outline))
        }
    }
    private func addCue() {
        guard !cue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, cue.count <= 80 else { return }
        selection.format(.deliveryCue, cue: cue); showCue = false
    }
}

@MainActor final class ScriptSelection: ObservableObject {
    @Published private(set) var tokens: Range<Int>?
    weak var textView: NSTextView?
    weak var library: ScriptLibrary?
    private var scriptID: UUID?
    func update(_ view: NSTextView, library: ScriptLibrary) {
        self.library = library; textView = view; scriptID = library.selectedID
        let selected = ScriptTokenMap(view.string).tokens(intersecting: view.selectedRange())
        if tokens != selected { tokens = selected }
    }
    func format(_ treatment: PhraseTreatment, cue: String? = nil) {
        guard let library, let record = library.selected, record.id == scriptID, let tokens else { return }
        let current = record.performance ?? PerformanceLayout.localPlan(for: record.body)
        guard let next = current.editing(tokens: tokens, treatment: treatment, cue: cue) else { return }
        replace(next, id: record.id, body: record.body, action: treatment == .emphasize ? "Emphasize" : treatment == .pause ? "Pause" : "Delivery Cue")
    }
    func replace(_ plan: PerformanceStylePlan?, id: UUID, body: String, action: String) {
        guard let library, let record = library.scripts.first(where: { $0.id == id }), record.body == body else { return }
        let previous = record.performance
        textView?.breakUndoCoalescing()
        textView?.undoManager?.registerUndo(withTarget: self) { target in
            target.replace(previous, id: id, body: body, action: action)
        }
        textView?.undoManager?.setActionName(action)
        library.restorePerformance(plan, id: id, expectedBody: body)
    }
}

struct NativeScriptEditor: NSViewRepresentable {
    @ObservedObject var library: ScriptLibrary
    @ObservedObject var selection: ScriptSelection
    func makeCoordinator() -> Coordinator { Coordinator(library: library, selection: selection) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let text = NSTextView(frame: .zero)
        text.isRichText = false; text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 16, height: 16)
        text.backgroundColor = NSColor(StudioPalette.surface)
        text.insertionPointColor = NSColor(StudioPalette.violet)
        text.setAccessibilityLabel("Script editor")
        text.setAccessibilityHelp("Select spoken words to add emphasis, a pause, or a delivery cue. Standard undo and redo are available.")
        text.delegate = context.coordinator
        scroll.documentView = text
        context.coordinator.render(text)
        selection.textView = text; selection.library = library
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.render(text)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let library: ScriptLibrary
        let selection: ScriptSelection
        private var scriptID: UUID?
        private var lastPlanID: UUID?
        private var lastBody: String?
        private var updating = false
        init(library: ScriptLibrary, selection: ScriptSelection) { self.library = library; self.selection = selection }
        func render(_ text: NSTextView) {
            guard let record = library.selected else { return }
            let switched = scriptID != record.id
            guard switched || lastBody != record.body || lastPlanID != record.performance?.id else { return }
            updating = true
            if switched { text.undoManager?.removeAllActions(); text.string = record.body; text.setSelectedRange(NSRange(location: 0, length: 0)) }
            else if text.string != record.body {
                let saved = text.selectedRange(); text.string = record.body
                text.setSelectedRange(NSRange(location: min(saved.location, text.string.utf16.count), length: 0))
            }
            scriptID = record.id; lastBody = record.body; lastPlanID = record.performance?.id
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
            let font = NSFont.systemFont(ofSize: 16)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(StudioPalette.ink), .paragraphStyle: paragraph]
            text.typingAttributes = attributes
            text.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: text.string.utf16.count))
            if let plan = record.performance {
                for match in PerformanceRanges.ranges(in: text.string, tokenOffset: 0, moments: plan.moments.filter { $0.tokenAnchor != nil }) {
                    if match.moment.scale != .regular {
                        text.textStorage?.addAttributes([.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor(StudioPalette.violet)], range: match.range)
                    }
                    if match.moment.pauseAfter { text.textStorage?.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range) }
                    if let cue = match.moment.deliveryCue { text.textStorage?.addAttribute(.toolTip, value: cue, range: match.range) }
                }
            }
            updating = false
            DispatchQueue.main.async { [weak self, weak text] in if let self, let text { self.selection.update(text, library: self.library) } }
        }
        func textDidChange(_ notification: Notification) {
            guard !updating, let text = notification.object as? NSTextView else { return }
            library.update(body: text.string)
            selection.update(text, library: library)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let text = notification.object as? NSTextView else { return }
            selection.update(text, library: library)
        }
    }
}
