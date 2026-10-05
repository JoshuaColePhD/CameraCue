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
    @State private var draftsExpanded = false
    @AppStorage("studio.library.list") private var listLayout = false

    private var results: [ScriptDashboardEntry] {
        let matching = ScriptDashboardQuery.homeResults(entries, search: search, filter: filter, sort: sort, isHome: isHome)
        if focusedHome, let featured = ScriptDashboardQuery.continuation(entries, selectedID: selectedID) {
            return matching.filter { $0.id != featured.id }
        }
        return matching
    }
    private var simpleHome: Bool { focusedHome && readyCount < 4 }
    private var focusedHome: Bool { isHome && !isSearching && filter == .all }
    private var drafts: [ScriptDashboardEntry] { ScriptDashboardQuery.results(entries, search: "", filter: .drafts, sort: sort) }
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

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { creationCards }.frame(minWidth: 680)
                        VStack(spacing: 12) { creationCards }
                    }
                }
                if !simpleHome { libraryToolbar }
                if results.isEmpty {
                    if !focusedHome || entries.isEmpty { emptyResults } else if readyCount == 0 { Text("Write or import a script to prepare your next recording.").font(.system(size: 14)).foregroundStyle(StudioPalette.mutedInk) }
                } else {
                    if simpleHome { Text("More recent scripts").font(.system(size: 18, weight: .semibold)) }
                    if listLayout {
                        LazyVStack(spacing: 8) { ForEach(results) { scriptCard($0) } }
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: StudioLayout.columns(for: min(1100, geometry.size.width - 48))), spacing: 16) {
                            ForEach(results) { documentCard($0) }
                        }
                    }
                }
                if focusedHome {
                    Button("View all scripts", action: onViewAll).buttonStyle(StudioButtonStyle())
                    if !drafts.isEmpty {
                        DisclosureGroup("Empty drafts (\(drafts.count))", isExpanded: $draftsExpanded) {
                            LazyVStack(spacing: 8) { ForEach(drafts) { scriptCard($0) } }.padding(.top, 8)
                        }.font(.system(size: 14, weight: .medium)).tint(StudioPalette.violet)
                    }
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(StudioPalette.canvas)
        }
    }

    @ViewBuilder private var creationCards: some View {
        actionCard("Write", detail: "Start with a blank page", symbol: .write, accent: StudioPalette.lavender, action: onNew)
        actionCard("Import text", detail: importTargeted ? "Release to import and format" : "Drop a .txt or .md file, or text", symbol: .import, accent: StudioPalette.sky, action: onImport)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(importTargeted ? StudioPalette.violet : .clear, style: StrokeStyle(lineWidth: 2, dash: [5, 4])))
            .onDrop(of: [UTType.fileURL.identifier, UTType.plainText.identifier], isTargeted: $importTargeted, perform: onDrop)
        actionCard("Draft with AI", detail: "Turn an idea into a draft to review", symbol: .sparkle, accent: StudioPalette.peach, action: onDevelop)
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
            Button(action: onNew) { StudioLabel("New script", .plus) }
                .buttonStyle(StudioButtonStyle())
                .help("Start a blank script (⌘N)")
        }
    }

    private func continuation(_ entry: ScriptDashboardEntry) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) { continuationText(entry).frame(width: 400, alignment: .leading); Spacer(minLength: 8); continuationActions(entry).fixedSize() }.frame(minWidth: 740)
            VStack(alignment: .leading, spacing: 16) { continuationText(entry); continuationActions(entry) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(StudioPalette.outline))
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
                Button("Rehearse") { onOpen(entry.script, .rehearse) }.buttonStyle(StudioButtonStyle()).disabled(!canRehearse)
            } else {
                Button("Write script") { onOpen(entry.script, .write) }.buttonStyle(StudioButtonStyle(primary: true))
            }
        }
    }

    private func actionCard(_ title: String, detail: String,
                            symbol: CueSymbol, accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                    Image(systemName: symbol == .write ? "square.and.pencil" : symbol == .import ? "square.and.arrow.down" : "sparkles").font(.system(size: 18)).foregroundStyle(StudioPalette.violet)
                    .padding(8).background(accent.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(detail).font(.system(size: 11)).foregroundStyle(StudioPalette.mutedInk)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(StudioPalette.violet)
            }
            .foregroundStyle(StudioPalette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).frame(minHeight: 72)

        }
        .buttonStyle(StudioSurfaceStyle())
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

    private func scriptCard(_ entry: ScriptDashboardEntry) -> some View {
        HStack(spacing: 0) {
            Button { onOpen(entry.script, .write) } label: {
                HStack(spacing: 14) {
                    CueIcon(entry.isReady ? .reader : .write, size: 20, badge: entry.isReady)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(entry.title).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1)
                            if entry.script.isFavorite {
                                Image(systemName: "star.fill").font(.system(size: 10))
                                    .foregroundStyle(StudioPalette.violet).accessibilityLabel("Favorite")
                            }
                            Text(importProgress[entry.id]?.phase == .formatting ? "Formatting…" : entry.isReady ? "Ready to read" : "Empty draft")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background((entry.isReady ? StudioPalette.mint : StudioPalette.lavenderWash).opacity(0.45), in: Capsule())
                        }
                        Text(entry.text.excerpt.isEmpty ? "Add spoken words to start practicing." : entry.text.excerpt)
                            .font(.system(size: 12)).foregroundStyle(StudioPalette.mutedInk).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(entry.isReady ? "\(entry.text.wordCount) words · \(entry.text.durationLabel)" : "No spoken text")
                            .font(.system(size: 11, weight: .medium))
                        Text("Edited \(entry.script.modifiedAt.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 10))
                    }.foregroundStyle(StudioPalette.mutedInk)
                    CueIcon(.next, size: 12).foregroundStyle(StudioPalette.violet)
                }
                .foregroundStyle(StudioPalette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 12)
                .frame(minHeight: 72).contentShape(Rectangle())
            }
            .buttonStyle(CueDashboardRowStyle()).accessibilityLabel("Open \(entry.title)")
            .help("Open this script in the editor")
            Menu {
                Button("Rename…") { onRename(entry.script) }
                Button("Duplicate") { onDuplicate(entry.script) }
                Button(entry.script.isFavorite ? "Remove from Favorites" : "Add to Favorites") { onFavorite(entry.script) }
                Divider()
                Button("Delete…", role: .destructive) { onDelete(entry.script) }.disabled(!canDelete)
            } label: {
                Label("Script actions", systemImage: "ellipsis")
                    .labelStyle(.iconOnly).font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StudioPalette.violet).frame(width: 44, height: 72).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Actions for \(entry.title)").help("Rename, duplicate, favorite, or delete this script")
        }
        .background(entry.isReady ? StudioPalette.surface : StudioPalette.canvas, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(StudioPalette.outline.opacity(0.6)))
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
