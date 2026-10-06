import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ScriptLibraryHome: View {
    let entries: [ScriptDashboardEntry]
    let selectedID: UUID?
    @Binding var search: String
    @Binding var filter: ScriptLibraryFilter
    @Binding var sort: ScriptLibrarySort
    let canRehearse: Bool
    let storageNotice: String?
    let isHome: Bool
    let importProgress: [UUID: DashboardImportProgress]
    let latestImportID: UUID?
    let importingTitle: String?
    let onRetryFormatting: (ScriptRecord) -> Void
    let canDelete: Bool
    let onViewAll: () -> Void
    let onNew: () -> Void
    let onImport: () -> Void
    let onDevelop: () -> Void
    let onOpen: (ScriptRecord, StudioStep) -> Void
    let onRename: (ScriptRecord) -> Void
    let onDuplicate: (ScriptRecord) -> Void
    let onFavorite: (ScriptRecord) -> Void
    let onDelete: (ScriptRecord) -> Void
    let onDrop: ([NSItemProvider]) -> Bool
    @State private var importTargeted = false
    @AppStorage("studio.library.list") private var listLayout = false

    private var results: [ScriptDashboardEntry] {
        if focusedHome { return ScriptDashboardQuery.recentHomeScripts(entries, selectedID: selectedID) }
        return ScriptDashboardQuery.results(entries, search: search, filter: filter, sort: sort)
    }
    private var focusedHome: Bool { isHome && !isSearching && filter == .all }
    private var readyCount: Int { entries.filter(\.isReady).count }
    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let storageNotice {
                    StudioLabel(storageNotice, .warning)
                        .font(.system(size: 12))
                        .foregroundStyle(StudioPalette.ink)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(StudioPalette.peach.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                }
                importBanner
                if isHome, !isSearching, filter == .all {
                    if let entry = ScriptDashboardQuery.continuation(entries, selectedID: selectedID) {
                        continuation(entry)
                    }

                    if readyCount == 0 { firstScript }
                }
                if !focusedHome { libraryToolbar }
                if results.isEmpty {
                    if !focusedHome { emptyResults }
                } else {
                    if focusedHome { Text("Recent scripts").font(.system(size: 18, weight: .semibold)).foregroundStyle(StudioPalette.ink) }
                    if focusedHome || listLayout {
                        LazyVStack(spacing: 8) { ForEach(results) { scriptCard($0) } }
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: StudioLayout.columns(for: min(1100, geometry.size.width - 48))), spacing: 16) {
                            ForEach(results) { documentCard($0) }
                        }
                    }
                }
                if focusedHome {
                    Button("View all scripts", action: onViewAll).buttonStyle(StudioButtonStyle())

                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(StudioPalette.canvas)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(importTargeted ? StudioPalette.violet : .clear, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).padding(8).allowsHitTesting(false))
        .onDrop(of: [UTType.fileURL.identifier, UTType.plainText.identifier], isTargeted: $importTargeted, perform: onDrop)
        }
    }

    private var firstScript: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(StudioPalette.violet)
            Text("What would you like to say?").font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(StudioPalette.ink)
            Text("Start with your words. We’ll help you prepare them for the camera.")
                .font(.system(size: 14)).foregroundStyle(StudioPalette.mutedInk)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { firstScriptActions }
                VStack(alignment: .leading, spacing: 12) { firstScriptActions }
            }
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [StudioPalette.lavender.opacity(0.45), StudioPalette.peach.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 16))
    }
    @ViewBuilder private var firstScriptActions: some View {
        Button("Write a script", action: onNew).buttonStyle(StudioButtonStyle(primary: true))
        Button("Import text", action: onImport).buttonStyle(StudioButtonStyle())
        Button("Draft with AI", action: onDevelop).buttonStyle(StudioButtonStyle())
    }

    @ViewBuilder private var importBanner: some View {
        if let importingTitle {
            HStack(spacing: 12) { ProgressView().controlSize(.small); Text("Importing · \(importingTitle)") }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(StudioPalette.sky.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
        } else if let latestImportID, let progress = importProgress[latestImportID], let entry = entries.first(where: { $0.id == latestImportID }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if progress.phase == .formatting { ProgressView().controlSize(.small) }
                    Text("Imported → " + (progress.phase == .formatting ? "Formatting…" : progress.phase == .ready ? "Ready to read" : "Needs attention")).font(.headline)
                }
                Text(entry.title).font(.callout.bold())
                Text(progress.message).font(.caption).foregroundStyle(StudioPalette.mutedInk)
                ViewThatFits(in: .horizontal) {
                    HStack { importActions(entry, progress: progress) }
                    VStack(alignment: .leading) { importActions(entry, progress: progress) }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(StudioPalette.lavenderWash, in: RoundedRectangle(cornerRadius: 16))
        }
    }
    @ViewBuilder private func importActions(_ entry: ScriptDashboardEntry, progress: DashboardImportProgress) -> some View {
        Button("Open script") { onOpen(entry.script, .write) }.buttonStyle(StudioButtonStyle())
        if progress.phase == .ready && entry.isReady {
            Button("Prepare to record") { onOpen(entry.script, .present) }.buttonStyle(StudioButtonStyle()).disabled(!canRehearse)
                .help(canRehearse ? "Open Present without starting capture" : "Finish the current take first")
        } else if progress.phase == .attention {
            Button("Retry formatting") { onRetryFormatting(entry.script) }.buttonStyle(StudioButtonStyle()).disabled(!entry.isReady)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(filter == .favorites ? "Favorites." : isHome ? "Your studio." : "Your scripts.")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .tracking(-0.6)
                    .foregroundStyle(StudioPalette.ink)
                Text("Write, rehearse, record.")
                    .font(.system(size: 13))
                    .foregroundStyle(StudioPalette.mutedInk)
            }
            Spacer(minLength: 12)
            Menu {
                Button("Blank script", action: onNew)
                Button("Import text…", action: onImport)
                Button("Draft with AI…", action: onDevelop)
            } label: { StudioLabel("New script", .plus).font(.system(size: 14, weight: .semibold)).foregroundStyle(StudioPalette.ink).padding(.horizontal, 14).padding(.vertical, 10).background(StudioPalette.lavender, in: RoundedRectangle(cornerRadius: 10)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 9).background(StudioPalette.lavender, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("New script: blank, import text, or draft with AI")
                .help("Choose how to create your next script")
        }
    }

    private func continuation(_ entry: ScriptDashboardEntry) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) { continuationText(entry).frame(width: 400, alignment: .leading); Spacer(minLength: 8); continuationActions(entry).fixedSize() }.frame(minWidth: 740)
            VStack(alignment: .leading, spacing: 16) { continuationText(entry); continuationActions(entry) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [StudioPalette.lavender.opacity(0.52), StudioPalette.sky.opacity(0.38)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(StudioPalette.lavender.opacity(0.8)))
    }
    private func continuationText(_ entry: ScriptDashboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continue working").font(.system(size: 12, weight: .medium)).foregroundStyle(StudioPalette.mutedInk)
            Text(entry.title).font(.system(size: 18, weight: .semibold)).lineLimit(1)
            Text(entry.isReady ? entry.text.excerpt : "A blank page, ready for your first line.")
                .font(.system(size: 14)).foregroundStyle(StudioPalette.mutedInk).lineLimit(1)
            Text(entry.text.durationLabel + " · " + (entry.isReady ? "Ready to read" : "Empty draft"))
                .font(.system(size: 12)).foregroundStyle(StudioPalette.mutedInk)
        }.foregroundStyle(StudioPalette.ink)
    }
    private func continuationActions(_ entry: ScriptDashboardEntry) -> some View {
        HStack(spacing: 8) {
            if entry.isReady {
                Button("Prepare to record") { onOpen(entry.script, .present) }.buttonStyle(StudioButtonStyle(primary: true)).disabled(!canRehearse).help("Open Present without capture. Finish your current take first if unavailable.")
                Button("Edit") { onOpen(entry.script, .write) }.buttonStyle(StudioButtonStyle())
            } else {
                Button("Write script") { onOpen(entry.script, .write) }.buttonStyle(StudioButtonStyle(primary: true))
            }
        }
    }

    private var libraryToolbar: some View {
        VStack(spacing: 13) {
            HStack(spacing: 8) {
                Text(focusedHome ? "Recent scripts" : "Script library").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(StudioPalette.ink)
                Text("\(results.count)").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioPalette.mutedInk)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(StudioPalette.lavenderWash, in: Capsule())
                Spacer()
                Picker("Library layout", selection: $listLayout) {
                    Image(systemName: "square.grid.2x2").tag(false).accessibilityLabel("Document grid")
                    Image(systemName: "list.bullet").tag(true).accessibilityLabel("Compact list")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 80)
                Menu {
                    ForEach(ScriptLibrarySort.allCases, id: \.self) { candidate in
                        Toggle(candidate.rawValue, isOn: Binding(
                            get: { sort == candidate },
                            set: { if $0 { sort = candidate } }
                        ))
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(sort.rawValue).font(.system(size: 12))
                        CueIcon(.expand, size: 12)
                    }.foregroundStyle(StudioPalette.mutedInk)
                }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Sort scripts")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { searchControl.frame(minWidth: 220); filterControl }
                VStack(alignment: .leading, spacing: 10) { searchControl; filterControl }
            }
        }
    }
    private var searchControl: some View {
                HStack(spacing: 8) {
                    CueIcon(.search, size: 14).foregroundStyle(StudioPalette.mutedInk)
                    TextField("Search titles or script text", text: $search)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .accessibilityLabel("Search scripts by title or contents")
                        .onSubmit { if let entry = results.first { onOpen(entry.script, .write) } }
                        .onExitCommand { search = "" }
                    if !search.isEmpty {
                        Button { search = "" } label: { CueIcon(.close, size: 12) }
                            .buttonStyle(.plain).accessibilityLabel("Clear search").help("Clear search")
                    }
                }
                .padding(.horizontal, 11).padding(.vertical, 10)
                .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(StudioPalette.outline.opacity(0.7)))
    }
    private var filterControl: some View {
                HStack(spacing: 3) {
                    ForEach(ScriptLibraryFilter.allCases, id: \.self) { candidate in
                        Button { filter = candidate } label: {
                            Text(candidate.rawValue).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(StudioPalette.ink)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(filter == candidate ? StudioPalette.lavenderWash : .clear,
                                            in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(candidate == .drafts ? "Show empty drafts" : "Show \(candidate.rawValue.lowercased()) scripts")
                        .accessibilityValue(filter == candidate ? "Selected" : "")
                    }
                }
                .padding(3).fixedSize(horizontal: true, vertical: false)
                .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioPalette.outline.opacity(0.45)))
    }

    private func documentAccent(_ entry: ScriptDashboardEntry) -> Color {
        let accents = [StudioPalette.sky, StudioPalette.peach, StudioPalette.mint]
        let index = entry.id.uuidString.utf8.reduce(0) { ($0 + Int($1)) % accents.count }
        return accents[index]
    }

    private func scriptCard(_ entry: ScriptDashboardEntry) -> some View {
        HStack(spacing: 0) {
            Button { onOpen(entry.script, .write) } label: {
                HStack(spacing: 12) {
                    Image(systemName: entry.isReady ? "doc.text" : "doc")
                        .font(.system(size: 18)).foregroundStyle(StudioPalette.violet)
                        .frame(width: 36, height: 36)
                        .background(entry.isReady ? documentAccent(entry).opacity(0.8) : StudioPalette.lavenderWash, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(importProgress[entry.id]?.phase == .formatting ? "Formatting…" : entry.isReady ? entry.text.durationLabel : "Empty draft")
                            .font(.system(size: 12)).foregroundStyle(StudioPalette.mutedInk)
                    }
                    Spacer(minLength: 8)
                    Text(entry.script.modifiedAt.formatted(.relative(presentation: .named)))
                        .font(.system(size: 12)).foregroundStyle(StudioPalette.mutedInk).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(StudioPalette.violet)
                }
                .foregroundStyle(StudioPalette.ink).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 12)
                .contentShape(Rectangle())
            }.buttonStyle(CueDashboardRowStyle()).accessibilityLabel("Open \(entry.title)")
            Menu {
                Button("Rename…") { onRename(entry.script) }
                Button("Duplicate") { onDuplicate(entry.script) }
                Button(entry.script.isFavorite ? "Remove from Favorites" : "Add to Favorites") { onFavorite(entry.script) }
                Divider()
                Button("Delete…", role: .destructive) { onDelete(entry.script) }.disabled(!canDelete)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StudioPalette.violet).frame(width: 44, height: 60).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Actions for \(entry.title)")
        }
        .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(StudioPalette.outline.opacity(0.65)))
    }

    private func documentCard(_ entry: ScriptDashboardEntry) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Button { onOpen(entry.script, .write) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        Text(entry.title).font(.system(size: 18, weight: .semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.right").font(.system(size: 12))
                    }.frame(height: 44, alignment: .top)
                    Text(entry.isReady ? entry.text.previewExcerpt : "Your next idea starts here. Add your first line.")
                        .font(.system(size: 14)).lineSpacing(4).foregroundStyle(StudioPalette.mutedInk)
                        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64, alignment: .topLeading).clipped()
                    StudioStatusLabel(title: importProgress[entry.id]?.phase == .formatting ? "Formatting…" : entry.isReady ? "Ready to read · " + entry.text.durationLabel : "Empty draft", success: entry.isReady)
                    HStack {
                        Text(entry.script.modifiedAt.formatted(.relative(presentation: .named)))
                            .font(.system(size: 12)).foregroundStyle(StudioPalette.mutedInk)
                        Spacer(minLength: 44)
                    }.frame(height: 28)
                }.foregroundStyle(StudioPalette.ink).padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(StudioSurfaceStyle()).accessibilityLabel("Open " + entry.title)
                .help("Open this script in the editor")
                Menu {
                    Button("Rename…") { onRename(entry.script) }
                    Button("Duplicate") { onDuplicate(entry.script) }
                    Button(entry.script.isFavorite ? "Remove from Favorites" : "Add to Favorites") { onFavorite(entry.script) }
                    Button("Delete…", role: .destructive) { onDelete(entry.script) }.disabled(!canDelete)
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Actions for " + entry.title)
                .padding(16)
        }.background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(StudioPalette.outline)).clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var emptyResults: some View {
        VStack(spacing: 11) {
            CueIcon(isSearching ? .search : .reader, size: 26, badge: true)
            Text(isSearching ? "No scripts match your search." : filter == .ready ? "No scripts ready to read yet." : filter == .drafts ? "No empty drafts here." : filter == .favorites ? "Keep your favorite scripts close." : "Your first script starts here.")
                .font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(StudioPalette.ink)
            Text(isSearching ? "Try a title or a few words from the script." : filter == .favorites ? "Choose Add to Favorites from a script’s action menu." : "Write a script or import a text file to get started.")
                .font(.system(size: 13)).foregroundStyle(StudioPalette.mutedInk)
            if isSearching || filter != .all {
                Button("Show all scripts") { search = ""; filter = .all }
                    .buttonStyle(StudioButtonStyle())
            } else {
                Button("New script", action: onNew).buttonStyle(StudioButtonStyle(primary: true))
            }
        }
        .padding(30).frame(maxWidth: .infinity)
        .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(StudioPalette.outline.opacity(0.55)))
    }
}
