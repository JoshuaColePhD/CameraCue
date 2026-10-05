import SwiftUI
import TeleprompterCore

struct ScriptDevelopmentView: View {
    let source: ScriptRecord?
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: ScriptDevelopmentMode
    @State private var brief = ""
    @State private var title: String
    @State private var output = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?

    init(source: ScriptRecord?, onSave: @escaping (String, String) -> Void) {
        self.source = source
        self.onSave = onSave
        _mode = State(initialValue: source == nil ? .draft : .revise)
        _title = State(initialValue: source.map { "\($0.title) Revision" } ?? "New Script")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 15) {
                CueIcon(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(StudioPalette.violet)
                    .frame(width: 45, height: 45)
                    .background(StudioPalette.lavender, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Develop with AI")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("Turn an idea into a draft, improve a script, or add performance cues. Review the result before saving.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                    Text("ON-DEVICE")
                    .font(.system(size: 10, weight: .bold)).tracking(1.2)
                    .foregroundStyle(StudioPalette.violet)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(StudioPalette.cream, in: Capsule())
            }
            .padding(24)
            .background(StudioPalette.surface)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 17) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("WHAT WOULD YOU LIKE TO DO?").font(.system(size: 10, weight: .bold)).tracking(1.3).foregroundStyle(.secondary)
                        Picker("Action", selection: $mode) {
                            Text(ScriptDevelopmentMode.draft.rawValue).tag(ScriptDevelopmentMode.draft)
                            if source != nil {
                                Text(ScriptDevelopmentMode.revise.rawValue).tag(ScriptDevelopmentMode.revise)
                                Text(ScriptDevelopmentMode.cues.rawValue).tag(ScriptDevelopmentMode.cues)
                            }
                        }
                        .labelsHidden()
                        .disabled(isGenerating)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(mode == .draft ? "DESCRIBE YOUR IDEA" : "ADDITIONAL DIRECTION")
                            .font(.system(size: 10, weight: .bold)).tracking(1.3).foregroundStyle(.secondary)
                        ZStack(alignment: .topLeading) {
                            if brief.isEmpty {
                                Text(mode == .draft
                                     ? "What is the topic? Who is watching? What tone and ending do you want?"
                                     : "Optional: describe the audience, tone, or parts that need work.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 9).padding(.vertical, 12)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $brief)
                                .font(.system(size: 14))
                                .scrollContentBackground(.hidden)
                                .padding(5)
                                .disabled(isGenerating)
                        }
                        .frame(minHeight: 160)
                        .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioPalette.outline))
                    }
                    if let source, mode != .draft {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("WORKING FROM").font(.system(size: 10, weight: .bold)).tracking(1.3).foregroundStyle(.secondary)
                            Text(source.title).font(.system(size: 14, weight: .medium))
                            Text("\(ScriptDocument(source.body).tokens.count) words · Your original stays untouched")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(StudioPalette.lavenderWash, in: RoundedRectangle(cornerRadius: 11))
                    }
                    Button { Task { await generate() } } label: {
                        if isGenerating {
                            HStack { ProgressView().controlSize(.small); Text("Generating…") }
                                .frame(maxWidth: .infinity)
                        } else {
                            StudioLabel(output.isEmpty ? "Generate Draft" : "Generate Again", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(StudioButtonStyle(primary: output.isEmpty))
                    .disabled(isGenerating || (mode == .draft && brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    if let errorMessage {
                        StudioLabel(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(StudioPalette.coral)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(24)
                .frame(width: 330)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("DRAFT PREVIEW")
                            .font(.system(size: 10, weight: .bold)).tracking(1.3).foregroundStyle(.secondary)
                        Spacer()
                        if !output.isEmpty {
                            Text("\(ScriptDocument(output).tokens.count) words")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    if output.isEmpty {
                        VStack(spacing: 12) {
                            CueIcon(systemName: "text.book.closed")
                                .font(.system(size: 32)).foregroundStyle(StudioPalette.violet)
                            Text("Your draft will appear here")
                                .font(.system(size: 17, weight: .medium, design: .rounded))
                            Text("Describe the idea and generate a version to review before it enters your library.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 280)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(StudioPalette.cream.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
                    } else {
                        ScrollView {
                            Text(output)
                                .font(.system(size: 14))
                                .lineSpacing(5)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(19)
                        }
                        .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioPalette.outline))
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            Divider()
            HStack(spacing: 12) {
                StudioLabel("Review AI drafts for accuracy before presenting", systemImage: "checkmark.shield")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if !output.isEmpty {
                    TextField("New script title", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 205)
                }
                Button("Cancel") { dismiss() }.buttonStyle(StudioButtonStyle())
                Button("Save as New Script") {
                    onSave(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Script" : title, output)
                    dismiss()
                }
                .buttonStyle(StudioButtonStyle(primary: !output.isEmpty))
                .disabled(output.isEmpty || isGenerating)
            }
            .padding(.horizontal, 22).padding(.vertical, 15)
            .background(StudioPalette.surface)
        }
        .frame(minWidth: 880, minHeight: 620)
        .background(StudioPalette.canvas)
        .tint(StudioPalette.violet)
        .preferredColorScheme(.light)
        .onChange(of: mode) { _, _ in output = ""; errorMessage = nil }
    }

    @MainActor private func generate() async {
        isGenerating = true
        errorMessage = nil
        output = ""
        do {
            output = try await ScriptDevelopmentService.generate(mode: mode, brief: brief, source: source?.body)
        } catch {
            errorMessage = error.localizedDescription
        }
        isGenerating = false
    }
}
