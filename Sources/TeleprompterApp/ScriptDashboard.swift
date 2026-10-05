import Foundation
import TeleprompterCore

/// Derived text information is cached by the library, so searching never needs
/// to tokenize every script again. Nothing here changes the saved source.
struct ScriptTextSummary: Equatable {
    let wordCount: Int
    let previewExcerpt: String
    let excerpt: String
    let readingSeconds: Int
    let excerptLines: [String]

    init(body: String) {
        let document = ScriptDocument(body)
        previewExcerpt = String(document.lines.lazy.filter { !$0.spokenText.isEmpty }.prefix(8).map(\.spokenText).joined(separator: "\n").prefix(600))
        wordCount = document.tokens.count
        readingSeconds = Int(ceil(Double(wordCount) * 60 / 135))
        excerptLines = Array(document.lines.lazy.filter { !$0.spokenText.isEmpty }.prefix(3).map(\.spokenText))
        let spoken = excerptLines.joined(separator: " ")
        excerpt = String(spoken.prefix(180)) + (spoken.count > 180 ? "…" : "")
    }

    var durationLabel: String {
        guard wordCount > 0 else { return "Blank draft" }
        return "~\(readingSeconds / 60):\(String(format: "%02d", readingSeconds % 60)) read"
    }
}

struct ScriptDashboardEntry: Identifiable {
    let script: ScriptRecord
    let text: ScriptTextSummary
    var id: UUID { script.id }
    var isReady: Bool { text.wordCount > 0 }
    var title: String {
        let title = script.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled Script" : title
    }
    var isStyled: Bool { script.performance?.isValid(for: script.body) == true }
}

enum ScriptLibraryFilter: String, CaseIterable {
    case all = "All", ready = "Ready to read", drafts = "Empty drafts", favorites = "Favorites"
}

enum ScriptLibrarySort: String, CaseIterable {
    case recent = "Recently edited", name = "Name", duration = "Shortest first"
}

enum ScriptDashboardQuery {
    static func results(_ entries: [ScriptDashboardEntry], search: String,
                        filter: ScriptLibraryFilter = .all, sort: ScriptLibrarySort = .recent) -> [ScriptDashboardEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            let matches = query.isEmpty || entry.title.localizedStandardContains(query)
                || entry.script.body.localizedStandardContains(query)
            let included: Bool
            switch filter {
            case .all: included = true
            case .ready: included = entry.isReady
            case .drafts: included = !entry.isReady
            case .favorites: included = entry.script.isFavorite
            }
            return matches && included
        }.sorted { a, b in
            switch sort {
            case .name:
                let comparison = a.title.localizedStandardCompare(b.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .duration:
                // Blank drafts have no reading duration, so keep them last.
                if a.isReady != b.isReady { return a.isReady }
                if a.text.readingSeconds != b.text.readingSeconds { return a.text.readingSeconds < b.text.readingSeconds }
            case .recent: break
            }
            if a.script.modifiedAt != b.script.modifiedAt { return a.script.modifiedAt > b.script.modifiedAt }
            return a.id.uuidString < b.id.uuidString
        }
    }

    static func sidebarResults(_ entries: [ScriptDashboardEntry], search: String) -> [ScriptDashboardEntry] {
        let matching = results(entries, search: search)
        let ready = matching.filter(\.isReady)
        return ready.isEmpty ? matching : ready
    }

    static func homeResults(_ entries: [ScriptDashboardEntry], search: String, filter: ScriptLibraryFilter, sort: ScriptLibrarySort, isHome: Bool) -> [ScriptDashboardEntry] {
        let focused = isHome && search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filter == .all
        let matching = results(entries, search: search, filter: focused ? .ready : filter, sort: sort)
        return focused ? Array(matching.prefix(6)) : matching
    }

    static func continuation(_ entries: [ScriptDashboardEntry], selectedID: UUID?) -> ScriptDashboardEntry? {
        let recent = results(entries, search: "", filter: .ready)
        return recent.first { $0.id == selectedID } ?? recent.first
    }
}
