import Foundation
import TeleprompterCore

struct DashboardImportProgress: Equatable {
    enum Phase { case formatting, ready, attention }
    let scriptID: UUID
    var phase: Phase
    var message: String
}

/// Per-script progress survives navigation. Applying a response never changes
/// selection, and edits made while the model works invalidate that response.
@MainActor final class DashboardFormatting: ObservableObject {
    @Published private(set) var progress: [UUID: DashboardImportProgress] = [:]
    @Published private(set) var latestID: UUID?
    @Published var importingTitle: String?
    private var generations: [UUID: UUID] = [:]
    private let suggest: (String) async -> PerformanceStyleService.Result
    init(suggest: @escaping (String) async -> PerformanceStyleService.Result = { await PerformanceStyleService.suggestWithStatus(for: $0, allowsExternalModel: false) }) {
        self.suggest = suggest
    }
    func start(_ script: ScriptRecord, library: ScriptLibrary) {
        importingTitle = nil
        latestID = script.id
        let generation = UUID()
        generations[script.id] = generation
        guard ScriptTextSummary(body: script.body).wordCount > 0 else {
            progress[script.id] = .init(scriptID: script.id, phase: .attention, message: "Add spoken words, then retry formatting.")
            return
        }
        progress[script.id] = .init(scriptID: script.id, phase: .formatting, message: "Formatting your script. Your original words stay unchanged.")
        Task {
            let result = await suggest(script.body)
            guard generations[script.id] == generation else { return }
            let current = library.scripts.first { $0.id == script.id }
            guard let current else { progress[script.id] = nil; return }
            let unchanged = current.body == script.body && current.performance?.id == script.performance?.id
            let applied = unchanged && library.apply(result.plan, to: script.id)
            progress[script.id] = .init(scriptID: script.id, phase: applied && !result.needsRetry ? .ready : .attention,
                message: applied ? result.status : "Formatting could not apply. Your script is kept; retry when you're ready.")
        }
    }
}
