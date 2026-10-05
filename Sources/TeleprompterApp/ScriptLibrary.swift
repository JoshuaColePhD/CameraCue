import Foundation
import TeleprompterCore

enum ScriptImportError: LocalizedError {
    case unsupportedFormat
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Choose a .txt or .md text file."
        case .fileTooLarge: "This file is too large for a script. Choose a file under 2 MB."
        }
    }
}

struct ScriptRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var body: String
    var modifiedAt: Date
    var performance: PerformanceStylePlan? = nil
    // Optional so libraries saved before favorites remain decodable.
    var favorite: Bool? = nil
    var isFavorite: Bool { favorite == true }
}

@MainActor final class ScriptLibrary: ObservableObject {
    @Published private(set) var scripts: [ScriptRecord] = []
    @Published var selectedID: UUID?
    @Published private(set) var storageError: String?
    @Published private(set) var recoveryNotice: String?
    private let fileURL: URL
    private var saveBlocked = false
    private var textSummaries: [UUID: (body: String, summary: ScriptTextSummary)] = [:]

    init(storageDirectory: URL? = nil) {
        let folder = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraCue", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            storageError = "Scripts cannot be saved: \(error.localizedDescription)"
        }
        fileURL = folder.appendingPathComponent("scripts.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let saved = try JSONDecoder().decode([ScriptRecord].self, from: Data(contentsOf: fileURL))
                scripts = saved
            } catch {
                let backup = folder.appendingPathComponent("scripts-recovery-\(Int(Date().timeIntervalSince1970)).json")
                do {
                    try FileManager.default.copyItem(at: fileURL, to: backup)
                    recoveryNotice = "Your saved scripts could not be opened. A recovery copy was kept in Application Support/CameraCue."
                } catch {
                    saveBlocked = true
                    storageError = "Saved scripts could not be opened or backed up. CameraCue will not overwrite them."
                }
            }
        }
        if scripts.isEmpty {
            let sample = Bundle.module.url(forResource: "StarterScript", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            scripts = [ScriptRecord(id: UUID(), title: "Welcome to CameraCue", body: sample, modifiedAt: .now)]
            if !saveBlocked { save() }
        }
        selectedID = scripts.first?.id
    }

    var selected: ScriptRecord? { scripts.first { $0.id == selectedID } }

    func dashboardEntries() -> [ScriptDashboardEntry] {
        let ids = Set(scripts.map(\.id))
        textSummaries = textSummaries.filter { ids.contains($0.key) }
        return scripts.map { script in
            let summary: ScriptTextSummary
            if let cached = textSummaries[script.id], cached.body == script.body {
                summary = cached.summary
            } else {
                summary = ScriptTextSummary(body: script.body)
                textSummaries[script.id] = (script.body, summary)
            }
            return ScriptDashboardEntry(script: script, text: summary)
        }
    }

    func select(_ id: UUID) { selectedID = id }
    func create() {
        let item = ScriptRecord(id: UUID(), title: "Untitled Script", body: "", modifiedAt: .now)
        scripts.insert(item, at: 0); selectedID = item.id; save()
    }
    @discardableResult func createDraft(title: String, body: String) -> ScriptRecord {
        let item = ScriptRecord(id: UUID(), title: title, body: body, modifiedAt: .now)
        scripts.insert(item, at: 0); selectedID = item.id; save()
        return item
    }
    func update(title: String? = nil, body: String? = nil) {
        guard let index = scripts.firstIndex(where: { $0.id == selectedID }) else { return }
        if let title { scripts[index].title = title }
        if let body {
            if scripts[index].body != body { scripts[index].performance = nil }
            scripts[index].body = body
        }
        scripts[index].modifiedAt = .now
        save()
    }
    func duplicate() {
        guard let selectedID else { return }
        _ = duplicate(id: selectedID)
    }
    @discardableResult func duplicate(id: UUID) -> ScriptRecord? {
        guard let source = scripts.first(where: { $0.id == id }) else { return nil }
        let copy = ScriptRecord(id: UUID(), title: source.title + " Copy", body: source.body, modifiedAt: .now, performance: source.performance)
        scripts.insert(copy, at: 0); selectedID = copy.id; save()
        return copy
    }
    func delete() {
        guard let selectedID else { return }
        delete(id: selectedID)
    }
    func delete(id: UUID) {
        guard scripts.count > 1, scripts.contains(where: { $0.id == id }) else { return }
        scripts.removeAll { $0.id == id }
        if selectedID == id { selectedID = scripts.first?.id }
        save()
    }
    func rename(id: UUID, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].title = title
        scripts[index].modifiedAt = .now
        save()
    }
    func toggleFavorite(id: UUID) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].favorite = !scripts[index].isFavorite
        save()
    }
    @discardableResult func importFile(_ url: URL) throws -> ScriptRecord {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard ["txt", "md"].contains(url.pathExtension.lowercased()) else { throw ScriptImportError.unsupportedFormat }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2_000_000 else { throw ScriptImportError.fileTooLarge }
        let body = try String(contentsOf: url, encoding: .utf8)
        let item = ScriptRecord(id: UUID(), title: url.deletingPathExtension().lastPathComponent, body: body, modifiedAt: .now)
        scripts.insert(item, at: 0); selectedID = item.id; save()
        return item
    }
    @discardableResult func importText(_ body: String) -> ScriptRecord {
        let item = ScriptRecord(id: UUID(), title: "Imported Text", body: body, modifiedAt: .now)
        scripts.insert(item, at: 0); selectedID = item.id; save()
        return item
    }
    func apply(_ plan: PerformanceStylePlan) {
        guard let selectedID else { return }
        _ = apply(plan, to: selectedID)
    }
    @discardableResult func apply(_ plan: PerformanceStylePlan, to id: UUID) -> Bool {
        guard let index = scripts.firstIndex(where: { $0.id == id }),
              plan.isValid(for: scripts[index].body) else { return false }
        scripts[index].performance = plan
        scripts[index].modifiedAt = .now
        save()
        return true
    }
    func clearPerformanceStyle() {
        guard let index = scripts.firstIndex(where: { $0.id == selectedID }) else { return }
        scripts[index].performance = nil
        save()
    }
    func restorePerformance(_ plan: PerformanceStylePlan?, id: UUID, expectedBody: String) {
        guard let index = scripts.firstIndex(where: { $0.id == id }), scripts[index].body == expectedBody,
              plan == nil || plan?.isValid(for: expectedBody) == true else { return }
        scripts[index].performance = plan
        scripts[index].modifiedAt = .now
        save()
    }
    private func save() {
        guard !saveBlocked else { return }
        do {
            let data = try JSONEncoder().encode(scripts)
            try data.write(to: fileURL, options: .atomic)
            storageError = nil
        } catch {
            storageError = "Scripts could not be saved: \(error.localizedDescription)"
        }
    }
}
