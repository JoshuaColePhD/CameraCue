import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TeleprompterCore

struct StudioView: View {
    @EnvironmentObject private var library: ScriptLibrary
    @EnvironmentObject private var model: TeleprompterModel
    @EnvironmentObject private var notch: NotchController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var previewChoice = false
    @AppStorage("studio.lastWorkingScript") private var lastWorkingScript = ""
    @State private var importedSelectionID: UUID?
    @State private var showsImporter = false
    @State private var showsSettings = false
    @State private var showsRecordingSettings = false
    @State private var showsModelSettings = false
    @State private var isStyling = false
    @State private var suggestedPlan: PerformanceStylePlan?
    @State private var developmentRequest: DevelopmentRequest?
    @State private var showingLibrary = true
    @State private var showingRecordings = false
    @State private var dashboardHome = true
    @State private var step: StudioStep = .write
    @State private var search = ""
    @State private var libraryFilter: ScriptLibraryFilter = .all
    @State private var librarySort: ScriptLibrarySort = .recent
    @State private var pendingNavigationStep: StudioStep?
    @State private var isDropTargeted = false
    @State private var importError: String?
    @StateObject private var dashboardFormatting = DashboardFormatting()
    @ObservedObject private var languageModels = LanguageModelSettings.shared
    private var selectedImportProgress: DashboardImportProgress? { library.selectedID.flatMap { dashboardFormatting.progress[$0] } }
    private var autoStylingScriptID: UUID? { selectedImportProgress?.phase == .formatting ? library.selectedID : nil }
    private var styleNoticeScriptID: UUID? { selectedImportProgress?.phase != .formatting ? selectedImportProgress?.scriptID : nil }
    private var styleNotice: String? { selectedImportProgress?.message }
    private var formattingSucceeded: Bool { selectedImportProgress?.phase == .ready }
    @State private var showsDeleteConfirmation = false
    @State private var deleteTarget: ScriptRecord?
    @State private var renameTarget: ScriptRecord?
    @State private var renameTitle = ""

    private var selectedTextSummary: ScriptTextSummary {
        library.dashboardEntries().first { $0.id == library.selectedID }?.text ?? ScriptTextSummary(body: "")
    }
    private var editableWordCount: Int { selectedTextSummary.wordCount }
    private var title: Binding<String> { Binding(get: { library.selected?.title ?? "" }, set: { library.update(title: $0) }) }
    private var bodyText: Binding<String> { Binding(get: { library.selected?.body ?? "" }, set: { library.update(body: $0) }) }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            studioSidebar
        } detail: {
            studioDetail
        }
        .font(.system(size: 14))
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .accessibilityLabel(columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
                .help(columnVisibility == .detailOnly ? "Show sidebar" : "Hide sidebar")
            }
        }
        .toolbarBackground(StudioPalette.canvas, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .overlay(alignment: .top) {
            Rectangle().fill(StudioPalette.outline.opacity(0.65)).frame(height: 1).allowsHitTesting(false)
        }
        .background(StudioWindowReader { window in notch.attachStudioWindow(window) })
        .onAppear {
            if notch.shouldOpenDashboard {
                showDashboard(home: true)
                notch.shouldOpenDashboard = false
            } else if notch.shouldOpenScriptEditor {
                step = .write; showingRecordings = false; showingLibrary = false; notch.shouldOpenScriptEditor = false
            }
            notch.onReturnToScript = {
                step = .write; showingRecordings = false; showingLibrary = false
                openWindow(id: "studio")
            }
            notch.onViewRecording = {
                step = .present; showingRecordings = false; showingLibrary = false
                openWindow(id: "studio")
            }
            notch.onOpenDashboard = {
                showDashboard(home: true)
                notch.shouldOpenDashboard = false
                openWindow(id: "studio")
            }
        }
                        .sheet(isPresented: $showsRecordingSettings) {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Text("Camera & recording").font(.title3.bold())
                                    Spacer()
                                    Button("Done") { showsRecordingSettings = false }
                                        .buttonStyle(StudioButtonStyle()).keyboardShortcut(.cancelAction)
                                }
                                ScrollView {
                                    CameraRecordingView(video: model.video, locked: model.takeInProgress || model.isStarting)
                                }.frame(maxHeight: 470)
                                Button { step = .present; showsRecordingSettings = false } label: {
                                    StudioLabel("Go to Present", systemImage: "video")
                                }.buttonStyle(StudioButtonStyle(primary: true))
                                Text("Record in Present or the expanded notch. Stop saves your MP4.")
                                    .font(.caption).foregroundStyle(StudioPalette.mutedInk)
                            }.padding(24).frame(width: 440).background(StudioPalette.canvas)
                                .foregroundStyle(StudioPalette.ink)
                                .onDisappear { model.video.closePreview() }
                        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .plainText]) { result in
            if case let .success(url) = result { importScript(url) }
        }
        .onDrop(of: [UTType.fileURL.identifier, UTType.plainText.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(StudioPalette.violet, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                    .padding(12)
                    .background(StudioPalette.lavender.opacity(0.18))
                    .allowsHitTesting(false)
            }
        }
        .alert("Could not import script", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("Rename script", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Script name", text: $renameTitle)
            Button("Save") {
                if let script = renameTarget { library.rename(id: script.id, title: renameTitle) }
                renameTarget = nil
            }.disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog("Delete \(deleteTarget?.title ?? "this script")?", isPresented: $showsDeleteConfirmation) {
            Button("Delete Script", role: .destructive) {
                if let script = deleteTarget { library.delete(id: script.id) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This removes the script from CameraCue Studio and cannot be undone.")
        }
        .sheet(item: $suggestedPlan) { plan in
            PerformanceStylePreview(plan: plan, model: model, notch: notch) { edited in
                library.apply(edited)
                suggestedPlan = nil
            }
        }
        .sheet(item: $developmentRequest) { request in
            ScriptDevelopmentView(source: request.source) { title, body in
                processImported(library.createDraft(title: title, body: body))
            }
        }
        .sheet(isPresented: $showsModelSettings) { LanguageModelSettingsView() }
        .onAppear {
            if let script = library.selected { model.load(script) }
            notch.showCompact(model: model, library: library)
        }
        .onChange(of: library.selectedID) { _, _ in
            if let script = library.selected { model.load(script) }
            if importedSelectionID == library.selectedID {
                importedSelectionID = nil
                return
            }
            showingRecordings = false
            showingLibrary = false
            step = pendingNavigationStep ?? .write
            pendingNavigationStep = nil
        }
        .onChange(of: libraryFilter) { _, filter in
            if filter != .all { dashboardHome = false }
        }
        .onChange(of: library.selected?.body) { _, _ in
            if let script = library.selected {
                model.load(script)
                if !showingLibrary && editableWordCount > 0 { lastWorkingScript = script.id.uuidString }
            }
        }
        .onChange(of: library.selected?.performance?.id) { _, _ in if let script = library.selected { model.load(script) } }
        .tint(StudioPalette.violet)
    }

    private var studioSidebar: some View {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            CameraCueLogo(size: 28)
                            Text("CameraCue Studio")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                        }
                        .foregroundStyle(StudioPalette.ink)
                        Text("Your studio")
                            .font(.system(size: 12))
                            .foregroundStyle(StudioPalette.mutedInk)
                    }
                    Spacer()

                }
                .padding(18)
                VStack(spacing: 4) {
                    sidebarDestination("Home", systemImage: "house", selected: !showingRecordings && showingLibrary && dashboardHome && libraryFilter == .all) {
                        showDashboard(home: true)
                    }
                    sidebarDestination("Scripts", systemImage: "square.grid.2x2", selected: !showingRecordings && showingLibrary && !dashboardHome && libraryFilter != .favorites) {
                        showDashboard(home: false)
                    }
                    sidebarDestination("Recordings", systemImage: "video", selected: showingRecordings) {
                        showingRecordings = true
                    }.disabled(model.displayIsLocked).help(model.displayIsLocked ? "Finish the current take before reviewing recordings" : "Browse saved MP4 recordings")
                }.padding(.horizontal, 14)
                Spacer(minLength: 24)
                Button { showsModelSettings = true } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "cpu")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI model…")
                            Text(languageModels.selected.provider.name).font(.system(size: 10)).foregroundStyle(StudioPalette.mutedInk).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(StudioButtonStyle()).padding(.horizontal, 14)
                .accessibilityLabel("AI model settings")
                .help("Use Apple Intelligence or connect your own model")
                HStack {
                    Menu {
                        Button("Detached Reading Window") { openWindow(id: "prompter") }
                        if library.selected?.performance != nil {
                            Button("Remove Performance Style") { library.clearPerformanceStyle() }
                        }
                        Divider()
                        Button("Duplicate Script") { library.duplicate() }
                        Button("Delete Script", role: .destructive) { deleteTarget = library.selected; showsDeleteConfirmation = true }
                            .disabled(library.scripts.count < 2)
                    } label: { Label("More", systemImage: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).accessibilityLabel("More Studio actions").help("Reading window and script actions")
                    Spacer()
                }
                .foregroundStyle(StudioPalette.violet)
                .padding(16)
            }
            .navigationSplitViewColumnWidth(min: 218, ideal: 234, max: 280)
            .toolbar(removing: .sidebarToggle)
            .background(StudioPalette.sidebar)
    }

    @ViewBuilder private var studioDetail: some View {
            if showingRecordings {
                RecordingsLibrary(video: model.video)
            } else if showingLibrary {
                ScriptLibraryHome(entries: library.dashboardEntries(), selectedID: UUID(uuidString: lastWorkingScript),
                                  search: $search, filter: $libraryFilter, sort: $librarySort,
                                  canRehearse: !model.displayIsLocked,
                                  storageNotice: library.storageError ?? library.recoveryNotice,
                                  isHome: dashboardHome,
                                  importProgress: dashboardFormatting.progress,
                                  latestImportID: dashboardFormatting.latestID,
                                  importingTitle: dashboardFormatting.importingTitle,
                                  onRetryFormatting: { dashboardFormatting.start($0, library: library) },
                                  canDelete: library.scripts.count > 1,
                                  onViewAll: { showDashboard(home: false) }, onNew: createScript, onImport: { showsImporter = true }, onDevelop: {
                    openDevelopment(fromCurrentScript: false)
                }, onOpen: { script, destination in
                    openScript(script, at: destination)
                }, onRename: { script in
                    renameTitle = script.title; renameTarget = script
                }, onDuplicate: { script in
                    if let copy = library.duplicate(id: script.id) { openScript(copy, at: .write) }
                }, onFavorite: { library.toggleFavorite(id: $0.id) }, onDelete: { script in
                    deleteTarget = script; showsDeleteConfirmation = true
                }, onDrop: handleDrop)
            } else {
            GeometryReader { detailGeometry in
            VStack(spacing: 0) {
                StudioWorkflowBar(step: $step, width: detailGeometry.size.width,
                                  onScripts: { showingLibrary = true },
                                  onCameraSettings: { showsRecordingSettings.toggle() })
                if step != .write {
                    PresentationWorkspace(model: model, notch: notch, library: library, step: $step)
                } else {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Script title", text: title)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .textFieldStyle(.plain).foregroundStyle(StudioPalette.ink).lineLimit(1)
                        .accessibilityLabel("Script title")
                    Text("\(library.storageError == nil ? "Saved" : "Not saved") · \(editableWordCount) words · \(selectedTextSummary.durationLabel)")
                        .font(.system(size: 12)).foregroundStyle(StudioPalette.mutedInk)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { writingTools; Spacer(minLength: 8); prepareAction }
                        VStack(alignment: .leading, spacing: 8) { HStack(spacing: 8) { writingTools }; prepareAction }
                    }
                }.padding(.horizontal, 24).padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading).background(StudioPalette.surface)
                Divider()
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 14) {
                        if library.selected?.body.isEmpty == true {
                            HStack(spacing: 8) {
                                Button("Import text") { showsImporter = true }.buttonStyle(StudioButtonStyle())
                                Button("Draft with AI") { openDevelopment(fromCurrentScript: false) }.buttonStyle(StudioButtonStyle())
                            }
                        }
                        ScriptEditingWorkspace(library: library).id(library.selectedID)
                        if model.hasPendingScriptChanges {
                            Text("Changes saved for your next take. Restart from Beginning to use them.")
                                .font(.caption).foregroundStyle(StudioPalette.violet)
                        }
                        if let storageError = library.storageError {
                            StudioLabel(storageError, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        } else if let recoveryNotice = library.recoveryNotice {
                            StudioLabel(recoveryNotice, systemImage: "externaldrive.badge.exclamationmark")
                                .font(.caption).foregroundStyle(.orange)
                        } else if autoStylingScriptID == library.selectedID {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text("Preparing readable spacing for the imported script…")
                            }
                            .font(.caption).foregroundStyle(StudioPalette.violet)
                        } else if styleNoticeScriptID == library.selectedID, let styleNotice {
                            StudioLabel((formattingSucceeded ? "Formatting complete · " : "Formatting needs attention · ") + styleNotice,
                                     formattingSucceeded ? .check : .warning)
                                .font(.caption).foregroundStyle(StudioPalette.ink)
                        } else {
                            Text(isStyling ? "Finding dramatic beats and readable spacing…" : "")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .background(StudioPalette.canvas)
                    if previewChoice {
                    Divider()
                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            Text("READING PREVIEW")
                                .font(.system(size: 11, weight: .bold)).tracking(1.5)
                                .foregroundStyle(StudioPalette.violet)
                            Spacer()
                            if library.selected?.performance != nil {
                                Text(library.selected?.performance?.usedAI == true ? "AI STYLED" : "LOCAL STYLE")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(StudioPalette.violet)
                            }
                        }
                        ScriptReadingPreview(script: library.selected)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text("Next: rehearse at actual notch size, then check your setup before presenting.")
                            .font(.caption).foregroundStyle(StudioPalette.mutedInk)
                    }
                    .padding(24)
                    .frame(width: 280)
                    .background(StudioPalette.surface)
                    }
                }
            }
            .background(StudioPalette.canvas)
                }
            }

            }
            }
    }

    private var writingTools: some View {
        Group {
            Button { openDevelopment(fromCurrentScript: true) } label: { StudioLabel("Develop with AI", systemImage: "sparkles") }
                .buttonStyle(StudioButtonStyle()).fixedSize()
            Button { Task { await suggestStyle() } } label: {
                if isStyling { ProgressView().controlSize(.small) }
                else { StudioLabel("Format for reading", systemImage: "textformat") }
            }.buttonStyle(StudioButtonStyle()).fixedSize()
                .disabled(isStyling || autoStylingScriptID == library.selectedID || editableWordCount == 0)
            Button { previewChoice.toggle() } label: { StudioLabel("Preview", systemImage: "sidebar.right") }
                .buttonStyle(StudioButtonStyle(selected: previewChoice)).fixedSize().accessibilityValue(previewChoice ? "Visible" : "Hidden")
            Menu {
                Button("Reading settings…") { showsSettings = true }
                Button("Camera & recording…") { showsRecordingSettings = true }
                Button("AI model…") { showsModelSettings = true }
            } label: { Text("More") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More writing tools")
                .popover(isPresented: $showsSettings) { SettingsPopover().environmentObject(model) }
        }
    }
    private var prepareAction: some View {
        Button { step = .present } label: { StudioLabel("Prepare to record", systemImage: "video") }
            .buttonStyle(StudioButtonStyle(primary: true)).fixedSize()
            .disabled(editableWordCount == 0 || model.displayIsLocked)
            .help(model.displayIsLocked ? "Finish your current take first" : "Open Present without starting capture")
    }

    private func sidebarDestination(_ title: String, systemImage: String, selected: Bool,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: systemImage).font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 13).padding(.vertical, 10)
            .foregroundStyle(StudioPalette.ink)
            .background(selected ? StudioPalette.lavender.opacity(0.70) : .clear, in: RoundedRectangle(cornerRadius: 11))
            .contentShape(Rectangle())
        }.buttonStyle(CueSidebarButtonStyle()).accessibilityValue(selected ? "Selected" : "")
    }

    private func showDashboard(home: Bool, filter: ScriptLibraryFilter = .all) {
        showingRecordings = false
        showingLibrary = true; dashboardHome = home; libraryFilter = filter; search = ""
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        dashboardFormatting.importingTitle = provider.suggestedName ?? "Dropped text"
        showDashboard(home: true)
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                Task { @MainActor in
                    if let url { importScript(url) }
                    else { dashboardFormatting.importingTitle = nil; importError = error?.localizedDescription ?? "That file could not be opened." }
                }
            }
        } else {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                let text = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                Task { @MainActor in
                    if let text, text.utf8.count > 2_000_000 {
                        dashboardFormatting.importingTitle = nil
                        importError = ScriptImportError.fileTooLarge.localizedDescription
                    } else if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        processImported(library.importText(text))
                    } else {
                        dashboardFormatting.importingTitle = nil
                        importError = error?.localizedDescription ?? "The dropped text was empty or could not be read."
                    }
                }
            }
        }
        return true
    }

    @MainActor private func suggestStyle() async {
        guard let script = library.selected else { return }
        if let saved = script.performance, saved.isValid(for: script.body) {
            suggestedPlan = saved
            return
        }
        isStyling = true
        let plan = await PerformanceStyleService.suggest(for: script.body)
        isStyling = false
        guard library.selected?.id == script.id, library.selected?.body == script.body else { return }
        suggestedPlan = plan
    }

    private func createScript() {
        library.create()
        showingRecordings = false
        showingLibrary = false
        step = .write
    }

    private func openScript(_ script: ScriptRecord, at destination: StudioStep) {
        guard destination == .write || !model.displayIsLocked else { return }
        if library.dashboardEntries().first(where: { $0.id == script.id })?.isReady == true { lastWorkingScript = script.id.uuidString }
        pendingNavigationStep = library.selectedID != script.id ? destination : nil
        library.select(script.id)
        showingRecordings = false
        showingLibrary = false
        step = destination
    }

    private func openDevelopment(fromCurrentScript: Bool) {
        developmentRequest = DevelopmentRequest(source: fromCurrentScript ? library.selected : nil)
    }

    private func importScript(_ url: URL) {
        dashboardFormatting.importingTitle = url.deletingPathExtension().lastPathComponent
        showDashboard(home: true)
        do {
            processImported(try library.importFile(url))
        } catch {
            dashboardFormatting.importingTitle = nil
            importError = error.localizedDescription
        }
    }

    private func processImported(_ script: ScriptRecord) {
        importedSelectionID = script.id
        showDashboard(home: true)
        dashboardFormatting.start(script, library: library)
    }

}

private struct DevelopmentRequest: Identifiable {
    let id = UUID()
    let source: ScriptRecord?
}

private struct SettingsPopover: View {
    @EnvironmentObject var model: TeleprompterModel
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            StudioLabel("Reading comfort", .settings).font(.headline)
            Toggle("Focused phrases", isOn: $model.focusedReading)
            Text("Text size · \(Int(model.fontSize)) pt")
            Slider(value: $model.fontSize, in: 20...32).accessibilityLabel("Reading text size")
            Text("Phrase width · \(Int(model.textWidth)) pt")
            Slider(value: $model.textWidth, in: 230...350).accessibilityLabel("Phrase width")
            Toggle("Delivery cues", isOn: $model.showAnnotations)
            Picker("Voice Follow engine", selection: Binding(get: { model.speech.engineChoice }, set: { model.speech.selectEngine($0) })) {
                ForEach(SpeechFollower.EngineChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.disabled(model.isRunning || model.isStarting)
            if let trained = LearnedTrackingModel.available {
                Toggle("Extra jump protection (experimental)", isOn: $model.learnedTrackingEnabled).disabled(model.takeInProgress)
                Text("For scripts up to \(trained.maximumScriptTokens ?? 0) spoken words. Longer scripts keep standard Voice Follow.")
                    .font(.caption).foregroundStyle(StudioPalette.mutedInk).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Personalized pacing", isOn: $model.personalPacingEnabled)
            if let rate = model.paceProfile.usualWordsPerMinute {
                Text("Your usual pace: \(Int(rate)) words/min · \(model.paceProfile.samples.count) takes").font(.caption).foregroundStyle(StudioPalette.mutedInk)
                if let pause = model.paceProfile.usualPauseSeconds {
                    Text("Typical pause · \(pause.formatted(.number.precision(.fractionLength(1)))) seconds").font(.caption).foregroundStyle(StudioPalette.mutedInk)
                }
                Button("Reset pace calibration") { model.resetPersonalPace() }.buttonStyle(StudioButtonStyle())
            } else { Text("Practice a few longer passages to learn your pace on this Mac.").font(.caption).foregroundStyle(StudioPalette.mutedInk) }
            Toggle("Save speech feedback with new takes", isOn: $model.saveSpeechFeedback)
            Text("Use Rehearse to preview these settings at actual notch size.").font(.caption).foregroundStyle(StudioPalette.mutedInk)
        }.padding(20)
        }.frame(width: 330).frame(maxHeight: 560).background(StudioPalette.canvas).tint(StudioPalette.violet)
    }
}
