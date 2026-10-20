import Foundation
import TeleprompterCore

enum ScriptDevelopmentMode: String, CaseIterable, Identifiable {
    case draft = "Draft from idea"
    case revise = "Improve draft"
    case cues = "Add delivery cues"

    var id: String { rawValue }
}

enum ScriptDevelopmentError: LocalizedError {
    case modelUnavailable
    case emptyIdea
    case emptyScript
    case scriptTooLong
    case emptyResponse
    case changedSpokenWords
    case generationFailed

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: "Choose an available AI model in AI model settings."
        case .emptyIdea: "Describe the script you want to make first."
        case .emptyScript: "Add some script text before asking for a revision."
        case .scriptTooLong: "This script is too long for one AI pass. Shorten it to about 1,500 words and try again."
        case .emptyResponse: "The model returned an empty draft. Try a more specific request."
        case .changedSpokenWords: "The model changed spoken words while adding cues, so that version was discarded. Try again."
        case .generationFailed: "The selected model could not generate a draft right now. Try again later."
        }
    }
}

@MainActor enum ScriptDevelopmentService {
    static func generate(mode: ScriptDevelopmentMode, brief: String, source: String?, session: ScriptModelSession? = nil) async throws -> String {
        let trimmedBrief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if mode == .draft && trimmedBrief.isEmpty { throw ScriptDevelopmentError.emptyIdea }
        if mode != .draft && original.isEmpty { throw ScriptDevelopmentError.emptyScript }
        if original.count > 9_000 { throw ScriptDevelopmentError.scriptTooLong }
        let session = try session ?? LanguageModelSettings.shared.makeSession()

        let instructions = """
            You are a creative but disciplined script development partner for a presenter reading near a camera.
            Write clear, speakable lines with natural pacing and short paragraphs. Use bracketed stage directions sparingly.
            Return only the script body as plain text, with no preface, Markdown styling, fences, or explanation.
            """
        let request: String
        switch mode {
        case .draft:
            request = """
                Write a first draft of about 250 to 450 spoken words from this idea. Start with a strong hook, develop the story or explanation, then end with a clear payoff. Keep facts grounded in the brief; do not invent specific historical or scientific claims.

                Idea and direction:
                \(trimmedBrief)
                """
        case .revise:
            request = """
                Revise this script for a more engaging, easy-to-read performance. Preserve its core facts, meaning, and overall sequence. Shorten long sentences. Give the opening a stronger hook and make transitions clearer. Do not add unsupported claims.
                Additional direction: \(trimmedBrief.isEmpty ? "Keep the same audience and tone." : trimmedBrief)

                Script:
                \(original)
                """
        case .cues:
            request = """
                Add short bracketed delivery cues, strategic line breaks, and blank lines around pauses to this script. Do not add, remove, reorder, or rewrite any spoken words. Keep the existing words and punctuation exactly as written.
                Additional direction: \(trimmedBrief.isEmpty ? "Use restraint; mark only key moments." : trimmedBrief)

                Script:
                \(original)
                """
        }

        do {
            let output = try await session.generate(instructions, request).trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            guard !output.isEmpty else { throw ScriptDevelopmentError.emptyResponse }
            if mode == .cues && ScriptDocument(original).tokens != ScriptDocument(output).tokens {
                throw ScriptDevelopmentError.changedSpokenWords
            }
            return output
        } catch let error as ScriptDevelopmentError {
            throw error
        } catch let error as ScriptModelError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ScriptDevelopmentError.generationFailed
        }
    }
}
