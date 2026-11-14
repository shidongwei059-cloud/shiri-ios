import Foundation

/// A recording always has one durable draft ID. Only a complete, unambiguous interpretation can be confirmed outside the app.
public enum VoiceCaptureDraft {
    public static func prepare(_ text: String, id: UUID, startedAt: Date, calendar: Calendar, defaultTime: DayTime? = nil) throws -> CardDraft {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ShiriError.validation("没有听清内容，请重新录音") }
        var drafts = try ChineseCardParser(calendar: calendar).interpret(clean, now: startedAt, defaultTime: defaultTime)
        guard var draft = drafts.first else { throw ShiriError.validation("没有识别到内容，请重新录音") }
        draft.id = id; draft.card.id = id
        draft.originalText = clean; draft.interpretedText = clean
        drafts.removeFirst()
        draft.additionalDrafts = drafts.isEmpty ? nil : drafts
        return draft
    }

    public static func canConfirm(_ draft: CardDraft) -> Bool {
        draft.questions.isEmpty && (draft.additionalDrafts?.isEmpty ?? true)
            && draft.interpretedText == draft.originalText && (try? draft.card.validated()) != nil
    }
}
